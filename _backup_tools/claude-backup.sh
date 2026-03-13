#!/usr/bin/env bash
set -uo pipefail
# Note: -e is intentionally omitted — each step handles errors independently
# so Git failure doesn't block NAS, and vice versa.

# ── Load Configuration ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=backup.conf
source "$SCRIPT_DIR/backup.conf"

# Allow env var overrides
BACKUP_SOURCE="${BACKUP_SOURCE:-$HOME/.claude}"
BACKUP_REPO="${BACKUP_REPO:-$HOME/Projects/claude_backup}"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/claude-backup}"
NAS_BACKUP_ENABLED="${NAS_BACKUP_ENABLED:-true}"
INCLUDE_CONVERSATION_CACHE="${INCLUDE_CONVERSATION_CACHE:-true}"
MAX_FILE_SIZE_MB="${MAX_FILE_SIZE_MB:-90}"

# ── Setup ─────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date '+%Y-%m-%d_%H%M%S')"
LOGFILE="$LOG_DIR/backup_${TIMESTAMP}.log"
EXIT_CODE=0

# ── Lockfile (prevent concurrent runs) ────────────────────────────────
LOCKFILE="$LOG_DIR/.claude-backup.lock"
if [[ -f "$LOCKFILE" ]]; then
    LOCK_PID=$(cat "$LOCKFILE" 2>/dev/null || echo "")
    if [[ -n "$LOCK_PID" ]] && kill -0 "$LOCK_PID" 2>/dev/null; then
        echo "Another backup is already running (PID $LOCK_PID). Exiting." | tee -a "$LOGFILE"
        exit 1
    fi
    # Stale lockfile — previous run crashed
    rm -f "$LOCKFILE"
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGFILE"; }
err() { log "ERROR: $*"; }

# ── Banner ────────────────────────────────────────────────────────────
{
    echo "═══════════════════════════════════════════════════════════"
    echo "  Claude Code Backup — $TIMESTAMP"
    echo "═══════════════════════════════════════════════════════════"
    echo "  Source:              $BACKUP_SOURCE"
    echo "  Repository:          $BACKUP_REPO"
    echo "  NAS Backup:          $NAS_BACKUP_ENABLED"
    echo "  Conversation Cache:  $INCLUDE_CONVERSATION_CACHE"
    echo "═══════════════════════════════════════════════════════════"
} | tee -a "$LOGFILE"

# ── Build rsync excludes ──────────────────────────────────────────────
RSYNC_EXCLUDES=(
    --exclude='.DS_Store'
    --exclude='*.lock'
    --exclude='cache/'
    --exclude='plugins/cache/'
    --exclude='plugins/marketplaces/'
    --exclude='session-env/'
    --exclude='telemetry/'
    --exclude='paste-cache/'
    --exclude='backups/'
    --exclude='statsig/'
    --exclude='ide/'
    --exclude='downloads/'
    --exclude='_backup_tools/'
    --exclude='.git/'
    --exclude='.gitignore'
    --exclude='notes.md'
    --exclude='CLAUDE.md'
    --exclude='README.md'
)

if [[ "$INCLUDE_CONVERSATION_CACHE" != "true" ]]; then
    log "Excluding conversation cache directories"
    RSYNC_EXCLUDES+=(
        --exclude='projects/'
        --exclude='file-history/'
        --exclude='debug/'
        --exclude='shell-snapshots/'
    )
fi

# ── Step 1: rsync to local repo ──────────────────────────────────────
log "Syncing $BACKUP_SOURCE → $BACKUP_REPO"
if rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$BACKUP_SOURCE/" "$BACKUP_REPO/" 2>>"$LOGFILE"; then
    SYNC_STATUS="OK"
    log "Local sync complete"
else
    SYNC_STATUS="FAILED"
    err "Local rsync failed"
    EXIT_CODE=1
fi

# ── Step 2: Git commit + push ────────────────────────────────────────
GIT_STATUS="SKIPPED"
cd "$BACKUP_REPO"

# Pre-commit check: flag files >90MB (GitHub limit protection)
LARGE_FILES=$(find . -not -path './.git/*' -type f -size +"${MAX_FILE_SIZE_MB}M" 2>/dev/null || true)
if [[ -n "$LARGE_FILES" ]]; then
    err "Files exceed ${MAX_FILE_SIZE_MB}MB limit — will not commit:"
    echo "$LARGE_FILES" | tee -a "$LOGFILE"
    GIT_STATUS="BLOCKED_LARGE_FILES"
    EXIT_CODE=1
else
    git add -A 2>>"$LOGFILE"
    CHANGED_FILES=$(git diff --cached --numstat | wc -l | tr -d ' ')

    if [[ "$CHANGED_FILES" -gt 0 ]]; then
        COMMIT_MSG="backup: ${TIMESTAMP} — ${CHANGED_FILES} file(s) changed"
        if git commit -m "$COMMIT_MSG" >>"$LOGFILE" 2>&1; then
            log "Committed: $COMMIT_MSG"
            if git push "${GIT_REMOTE:-origin}" "${GIT_BRANCH:-main}" >>"$LOGFILE" 2>&1; then
                GIT_STATUS="OK"
                log "Pushed to ${GIT_REMOTE:-origin}/${GIT_BRANCH:-main}"
            else
                GIT_STATUS="PUSH_FAILED"
                err "Git push failed"
                EXIT_CODE=1
            fi
        else
            GIT_STATUS="COMMIT_FAILED"
            err "Git commit failed"
            EXIT_CODE=1
        fi
    else
        GIT_STATUS="NO_CHANGES"
        log "No changes to commit"
    fi
fi

# ── Step 3: NAS backup ───────────────────────────────────────────────
NAS_STATUS="DISABLED"
if [[ "$NAS_BACKUP_ENABLED" == "true" ]]; then
    log "Starting NAS backup"
    NAS_STATUS="FAILED"
    NAS_PASS=""

    # Retrieve password from Keychain
    if NAS_PASS=$(security find-generic-password \
        -s "${NAS_KEYCHAIN_SERVICE}" \
        -a "${NAS_KEYCHAIN_ACCOUNT}" \
        -w 2>/dev/null); then
        log "NAS credentials retrieved from Keychain"
    else
        err "Could not retrieve NAS password from Keychain"
        EXIT_CODE=1
    fi

    if [[ -n "$NAS_PASS" ]]; then
        # Mount SMB share using temp credentials file (avoids password in ps output)
        mkdir -p "${NAS_MOUNT_POINT}"
        # URL-encode password (special chars like ! @ # break the SMB URL parser)
        URL_PASS=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$NAS_PASS")
        CRED_URL="//${NAS_KEYCHAIN_ACCOUNT}:${URL_PASS}@${NAS_SHARE#//}"
        unset NAS_PASS URL_PASS  # clear password from memory immediately

        CRED_FILE=$(mktemp)
        chmod 600 "$CRED_FILE"
        printf '%s' "$CRED_URL" > "$CRED_FILE"
        unset CRED_URL

        if mount_smbfs "$(cat "$CRED_FILE")" "${NAS_MOUNT_POINT}" 2>>"$LOGFILE"; then
            rm -f "$CRED_FILE"
            log "NAS mounted at ${NAS_MOUNT_POINT}"

            # rsync to NAS (share mount + subdirectory)
            NAS_DEST="${NAS_MOUNT_POINT}/${NAS_SUBDIR:-}/$(date '+%Y-%m-%d')"
            mkdir -p "$NAS_DEST"
            if rsync -a --delete \
                --exclude='.git/' \
                "$BACKUP_REPO/" "$NAS_DEST/" 2>>"$LOGFILE"; then
                NAS_STATUS="OK"
                log "NAS sync complete → $NAS_DEST"
            else
                err "NAS rsync failed"
                EXIT_CODE=1
            fi

            # Prune NAS backups older than 30 days
            NAS_PRUNE_DIR="${NAS_MOUNT_POINT}/${NAS_SUBDIR:-}"
            find "$NAS_PRUNE_DIR" -maxdepth 1 -type d -name "20*" -mtime +30 -exec rm -rf {} + 2>/dev/null || true

            # Unmount
            umount "${NAS_MOUNT_POINT}" 2>>"$LOGFILE" || true
        else
            rm -f "$CRED_FILE"
            err "Could not mount NAS share"
            EXIT_CODE=1
        fi
    else
        unset NAS_PASS
    fi
fi

# ── Summary Block (structured for parsing by notify script) ──────────
REPO_SIZE=$(du -sh "$BACKUP_REPO" 2>/dev/null | cut -f1 || echo "unknown")
{
    echo ""
    echo "──── SUMMARY ────"
    echo "TIMESTAMP=$TIMESTAMP"
    echo "SYNC_STATUS=$SYNC_STATUS"
    echo "GIT_STATUS=$GIT_STATUS"
    echo "CHANGED_FILES=${CHANGED_FILES:-0}"
    echo "NAS_STATUS=$NAS_STATUS"
    echo "NAS_ENABLED=$NAS_BACKUP_ENABLED"
    echo "CONV_CACHE=$INCLUDE_CONVERSATION_CACHE"
    echo "REPO_SIZE=$REPO_SIZE"
    echo "EXIT_CODE=$EXIT_CODE"
    echo "──── END ────"
} | tee -a "$LOGFILE"

# ── Prune old logs (keep last 30 days) ───────────────────────────────
find "$LOG_DIR" -name "backup_*.log" -mtime +30 -delete 2>/dev/null || true

exit "$EXIT_CODE"

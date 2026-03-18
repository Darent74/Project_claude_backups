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
NAS_MOUNT_BASE="${NAS_MOUNT_BASE:-$HOME/mounts/claude-backup}"
NAS_CONNECT_TIMEOUT="${NAS_CONNECT_TIMEOUT:-10}"
NAS_MOUNT_TIMEOUT="${NAS_MOUNT_TIMEOUT:-30}"
NAS_RETENTION="${NAS_RETENTION:-7}"

# ── Setup ─────────────────────────────────────────────────────────────
mkdir -p "$LOG_DIR"
TIMESTAMP="$(date '+%Y-%m-%d_%H%M%S')"
LOGFILE="$LOG_DIR/backup_${TIMESTAMP}.log"
EXIT_CODE=0
BACKUP_START=$SECONDS

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

# Clean up lockfile and any stale NAS mount on exit
cleanup() {
    rm -f "$LOCKFILE"
    # Unmount NAS if still mounted at our mount point
    if mount | grep -q "$NAS_MOUNT_BASE" 2>/dev/null; then
        umount "$NAS_MOUNT_BASE" 2>/dev/null || true
    fi
}
trap cleanup EXIT

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

    # Extract NAS host from share path (e.g. //192.168.1.100/share → 192.168.1.100)
    NAS_HOST=$(echo "$NAS_SHARE" | sed 's|^//||; s|/.*||')

    # ── Pre-flight: connectivity check ────────────────────────────────
    if ! nc -z -w "$NAS_CONNECT_TIMEOUT" "$NAS_HOST" 445 2>/dev/null; then
        err "NAS unreachable at $NAS_HOST:445 (timeout ${NAS_CONNECT_TIMEOUT}s) — skipping NAS backup"
        EXIT_CODE=1
    else
        log "NAS reachable at $NAS_HOST:445"

        # ── Retrieve credentials from Keychain ────────────────────────
        NAS_PASS=""
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
            # URL-encode password (special chars like ! @ # break the SMB URL parser)
            URL_PASS=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$NAS_PASS")
            SMB_URL="//${NAS_KEYCHAIN_ACCOUNT}:${URL_PASS}@${NAS_SHARE#//}"
            unset NAS_PASS URL_PASS  # clear password from memory immediately

            # ── Ensure mount point exists (user-owned, no sudo needed) ─
            mkdir -p "$NAS_MOUNT_BASE"

            # ── Clean up stale mount if present ────────────────────────
            if mount | grep -q "$NAS_MOUNT_BASE" 2>/dev/null; then
                log "Stale mount found at $NAS_MOUNT_BASE — unmounting"
                umount "$NAS_MOUNT_BASE" 2>/dev/null || true
                sleep 1
            fi

            # ── Mount with timeout (no Finder fallback) ───────────────
            CRED_FILE=$(mktemp)
            chmod 600 "$CRED_FILE"
            printf '%s' "$SMB_URL" > "$CRED_FILE"
            unset SMB_URL  # clear credentials from memory

            # stderr → /dev/null: mount_smbfs leaks credentials in error messages
            if timeout "$NAS_MOUNT_TIMEOUT" mount_smbfs "$(cat "$CRED_FILE")" "$NAS_MOUNT_BASE" 2>/dev/null; then
                rm -f "$CRED_FILE"
                log "NAS mounted at $NAS_MOUNT_BASE via mount_smbfs"

                # ── Write access test ─────────────────────────────────
                if touch "$NAS_MOUNT_BASE/.write_test" 2>/dev/null; then
                    rm -f "$NAS_MOUNT_BASE/.write_test" 2>/dev/null
                    log "Write access confirmed"

                    # ── rsync to NAS ──────────────────────────────────
                    NAS_DEST="$NAS_MOUNT_BASE/${NAS_SUBDIR:-}/$(date '+%Y-%m-%d')"
                    if mkdir -p "$NAS_DEST" 2>>"$LOGFILE"; then
                        log "Created NAS destination: $NAS_DEST"
                    else
                        err "Failed to create NAS destination directory: $NAS_DEST"
                        EXIT_CODE=1
                    fi

                    if [[ -d "$NAS_DEST" ]]; then
                        # Prefer Homebrew GNU rsync — Apple's openrsync is sandboxed
                        # and gets "Operation not permitted" on network volumes under launchd
                        RSYNC_BIN="/opt/homebrew/bin/rsync"
                        if [[ ! -x "$RSYNC_BIN" ]]; then
                            RSYNC_BIN="rsync"  # fall back to system rsync
                        fi

                        if "$RSYNC_BIN" -a --no-owner --no-group --no-perms --inplace --delete \
                            --exclude='.git/' \
                            "$BACKUP_REPO/" "$NAS_DEST/" 2>>"$LOGFILE"; then
                            NAS_STATUS="OK"
                            log "NAS sync complete → $NAS_DEST (via $RSYNC_BIN)"
                        else
                            # rsync failed — fall back to cp for resilience
                            log "rsync failed on NAS, falling back to cp"
                            if cp -a "$BACKUP_REPO/" "$NAS_DEST/" 2>>"$LOGFILE" && \
                               rm -rf "$NAS_DEST/.git" 2>/dev/null; then
                                NAS_STATUS="OK"
                                log "NAS sync complete → $NAS_DEST (via cp fallback)"
                            else
                                err "NAS sync failed (both rsync and cp)"
                                EXIT_CODE=1
                            fi
                        fi
                    fi

                    # ── Mark successful backup + prune to retention limit ─
                    if [[ "$NAS_STATUS" == "OK" ]]; then
                        # Stamp this backup as complete (only successful backups get this marker)
                        date '+%Y-%m-%d %H:%M:%S' > "$NAS_DEST/.backup_complete" 2>/dev/null || true

                        # Prune: keep NAS_RETENTION successful backups, delete oldest
                        NAS_PRUNE_DIR="$NAS_MOUNT_BASE/${NAS_SUBDIR:-}"
                        # List dated dirs that have the .backup_complete marker, newest first
                        GOOD_BACKUPS=()
                        while IFS= read -r dir; do
                            if [[ -f "$dir/.backup_complete" ]]; then
                                GOOD_BACKUPS+=("$dir")
                            fi
                        done < <(ls -dt "$NAS_PRUNE_DIR"/20* 2>/dev/null)

                        GOOD_COUNT=${#GOOD_BACKUPS[@]}
                        log "NAS retention: $GOOD_COUNT successful backups found (keeping $NAS_RETENTION)"

                        if [[ "$GOOD_COUNT" -gt "$NAS_RETENTION" ]]; then
                            # Delete oldest beyond retention limit
                            for ((i=NAS_RETENTION; i<GOOD_COUNT; i++)); do
                                PRUNE_TARGET="${GOOD_BACKUPS[$i]}"
                                if rm -rf "$PRUNE_TARGET" 2>>"$LOGFILE"; then
                                    log "Pruned old NAS backup: $(basename "$PRUNE_TARGET")"
                                else
                                    err "Failed to prune: $PRUNE_TARGET"
                                fi
                            done
                        fi

                        # Also clean up any incomplete backups (no .backup_complete marker)
                        # older than the newest successful backup
                        while IFS= read -r dir; do
                            if [[ ! -f "$dir/.backup_complete" ]]; then
                                log "Removing incomplete NAS backup: $(basename "$dir")"
                                rm -rf "$dir" 2>>"$LOGFILE" || true
                            fi
                        done < <(ls -dt "$NAS_PRUNE_DIR"/20* 2>/dev/null)
                    fi
                else
                    err "Write access denied on $NAS_MOUNT_BASE — mount is read-only"
                    EXIT_CODE=1
                fi

                # Unmount (also handled by EXIT trap as safety net)
                log "Unmounting NAS"
                umount "$NAS_MOUNT_BASE" 2>>"$LOGFILE" || true
            else
                rm -f "$CRED_FILE"
                err "mount_smbfs failed or timed out (${NAS_MOUNT_TIMEOUT}s limit)"
                EXIT_CODE=1
            fi
        else
            unset NAS_PASS
        fi
    fi
fi

# ── Duration ──────────────────────────────────────────────────────────
DURATION_SECS=$((SECONDS - BACKUP_START))
DURATION="$((DURATION_SECS / 60))m $((DURATION_SECS % 60))s"

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
    echo "DURATION=$DURATION"
    echo "EXIT_CODE=$EXIT_CODE"
    echo "──── END ────"
} | tee -a "$LOGFILE"

# ── Send notification (inline — no separate LaunchAgent) ─────────────
"$SCRIPT_DIR/claude-backup-notify.sh" "$LOGFILE" 2>>"$LOGFILE" || {
    err "Notification script failed (exit $?) — backup itself completed"
}

# ── Prune old logs (keep last 30 days) ───────────────────────────────
find "$LOG_DIR" -name "backup_*.log" -mtime +30 -delete 2>/dev/null || true

exit "$EXIT_CODE"

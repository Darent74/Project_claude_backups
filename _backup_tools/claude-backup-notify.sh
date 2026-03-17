#!/usr/bin/env bash
set -euo pipefail

# ── Load Configuration ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=backup.conf
source "$SCRIPT_DIR/backup.conf"

LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/claude-backup}"
NOTIFY_EMAIL="${NOTIFY_EMAIL:-darent74@gmail.com}"

# ── Find log to report on ────────────────────────────────────────────
# Prefer $1 argument (passed by backup script after completion).
# Fall back to latest log file (for manual/standalone runs).
LATEST_LOG="${1:-}"
if [[ -z "$LATEST_LOG" || ! -f "$LATEST_LOG" ]]; then
    LATEST_LOG=$(ls -t "$LOG_DIR"/backup_*.log 2>/dev/null | head -1)
fi

if [[ -z "$LATEST_LOG" || ! -f "$LATEST_LOG" ]]; then
    echo "No backup logs found in $LOG_DIR"
    exit 1
fi

# Guard: if the log has no SUMMARY block yet, the backup is still running
if ! grep -q "^──── END ────" "$LATEST_LOG" 2>/dev/null; then
    echo "Log file is incomplete (backup still running?) — skipping notification"
    echo "Log: $LATEST_LOG"
    exit 1
fi

echo "Parsing: $LATEST_LOG"

# ── Parse summary block ──────────────────────────────────────────────
parse_field() {
    grep "^${1}=" "$LATEST_LOG" | tail -1 | cut -d'=' -f2-
}

TIMESTAMP=$(parse_field "TIMESTAMP")
SYNC_STATUS=$(parse_field "SYNC_STATUS")
GIT_STATUS=$(parse_field "GIT_STATUS")
CHANGED_FILES=$(parse_field "CHANGED_FILES")
NAS_STATUS=$(parse_field "NAS_STATUS")
NAS_ENABLED=$(parse_field "NAS_ENABLED")
CONV_CACHE=$(parse_field "CONV_CACHE")
REPO_SIZE=$(parse_field "REPO_SIZE")
DURATION=$(parse_field "DURATION")
BACKUP_EXIT=$(parse_field "EXIT_CODE")

# ── Determine overall status ─────────────────────────────────────────
if [[ "$BACKUP_EXIT" == "0" ]]; then
    STATUS_ICON="[OK]"
    STATUS_WORD="SUCCESS"
elif [[ "$BACKUP_EXIT" == "1" ]]; then
    STATUS_ICON="[!!]"
    STATUS_WORD="PARTIAL FAILURE"
else
    STATUS_ICON="[XX]"
    STATUS_WORD="FAILED"
fi

SUBJECT="$STATUS_ICON Claude Code Backup — $TIMESTAMP"

# ── Extract errors if any ─────────────────────────────────────────────
ERRORS=$(grep "ERROR:" "$LATEST_LOG" 2>/dev/null || echo "(none)")

# ── Compose email body ────────────────────────────────────────────────
BODY=$(cat <<EOF
Claude Code Backup Report
==========================
Timestamp:    $TIMESTAMP
Status:       $STATUS_WORD
Duration:     ${DURATION:-unknown}

Components
----------
Local Sync:   $SYNC_STATUS
Git Push:     $GIT_STATUS
NAS Backup:   $NAS_STATUS

Details
-------
Files Changed:        ${CHANGED_FILES:-0}
Repository Size:      ${REPO_SIZE:-unknown}
NAS Enabled:          $NAS_ENABLED
Conversation Cache:   $CONV_CACHE

Errors
------
$ERRORS

---
Log file: $LATEST_LOG
EOF
)

# ── Send via msmtp ────────────────────────────────────────────────────
if command -v msmtp &>/dev/null; then
    {
        echo "To: $NOTIFY_EMAIL"
        echo "From: $NOTIFY_EMAIL"
        echo "Subject: $SUBJECT"
        echo ""
        echo "$BODY"
    } | msmtp -C "$SCRIPT_DIR/.msmtprc" "$NOTIFY_EMAIL"
    echo "Notification sent to $NOTIFY_EMAIL"
else
    echo "msmtp not found — printing report to stdout:"
    echo ""
    echo "$BODY"
    exit 1
fi

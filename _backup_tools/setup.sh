#!/usr/bin/env bash
set -euo pipefail

# ── Load Configuration ────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
# shellcheck source=backup.conf
source "$SCRIPT_DIR/backup.conf"

LAUNCH_AGENTS_DIR="$HOME/Library/LaunchAgents"
LOG_DIR="${LOG_DIR:-$HOME/Library/Logs/claude-backup}"

echo "═══════════════════════════════════════════════════════════"
echo "  Claude Code Backup — Setup"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Step 1: Check/install msmtp ───────────────────────────────────────
echo "── Step 1: Checking msmtp ──"
if command -v msmtp &>/dev/null; then
    echo "  msmtp already installed: $(which msmtp)"
else
    echo "  Installing msmtp via Homebrew..."
    brew install msmtp
fi
echo ""

# ── Step 2: Initialize git repo ──────────────────────────────────────
echo "── Step 2: Git repository ──"
cd "$REPO_DIR"

if [[ ! -d .git ]]; then
    echo "  Initializing git repo..."
    git init
    git branch -M main
else
    echo "  Git repo already initialized"
fi

# Check if remote exists
if git remote get-url origin &>/dev/null; then
    echo "  Remote 'origin' already set: $(git remote get-url origin)"
else
    echo "  No remote configured."
    echo "  Please create a private repo on GitHub, then run:"
    echo "    git remote add origin https://github.com/YOUR-USERNAME/claude-code-backup.git"
    echo ""
    read -rp "  Enter your GitHub repo URL (or press Enter to skip): " REPO_URL
    if [[ -n "$REPO_URL" ]]; then
        git remote add origin "$REPO_URL"
        echo "  Remote set to: $REPO_URL"
    else
        echo "  Skipped — you can add it later with: git remote add origin <url>"
    fi
fi
echo ""

# ── Step 3: NAS credentials ──────────────────────────────────────────
echo "── Step 3: NAS Credentials ──"
if [[ "$NAS_BACKUP_ENABLED" != "true" ]]; then
    echo "  NAS backup disabled in backup.conf — skipping"
elif security find-generic-password -s "${NAS_KEYCHAIN_SERVICE}" -a "${NAS_KEYCHAIN_ACCOUNT}" &>/dev/null 2>&1; then
    echo "  NAS credentials already in Keychain"
else
    echo "  Enter password for NAS user '${NAS_KEYCHAIN_ACCOUNT}':"
    echo "  (NAS share: ${NAS_SHARE})"
    read -rsp "  Password: " NAS_PASS
    echo ""
    security add-generic-password -U \
        -s "${NAS_KEYCHAIN_SERVICE}" \
        -a "${NAS_KEYCHAIN_ACCOUNT}" \
        -w "$NAS_PASS"
    echo "  NAS password stored in Keychain"
fi
echo ""

# ── Step 4: Gmail App Password ────────────────────────────────────────
echo "── Step 4: Gmail Notification Setup ──"
if security find-generic-password -s "${GMAIL_KEYCHAIN_SERVICE}" -a "${GMAIL_KEYCHAIN_ACCOUNT}" &>/dev/null 2>&1; then
    echo "  Gmail credentials already in Keychain"
else
    echo "  Enter Gmail App Password for '${GMAIL_KEYCHAIN_ACCOUNT}':"
    echo "  (Generate at: https://myaccount.google.com/apppasswords)"
    read -rsp "  App Password: " GMAIL_PASS
    echo ""
    security add-generic-password -U \
        -s "${GMAIL_KEYCHAIN_SERVICE}" \
        -a "${GMAIL_KEYCHAIN_ACCOUNT}" \
        -w "$GMAIL_PASS"
    echo "  Gmail App Password stored in Keychain"
fi

# Configure msmtp — use a dedicated config file to avoid conflicts with existing ~/.msmtprc
MSMTP_RC="$SCRIPT_DIR/.msmtprc"
if [[ -f "$MSMTP_RC" ]] && grep -q "claude-backup-gmail" "$MSMTP_RC"; then
    echo "  msmtp already configured at $MSMTP_RC"
else
    echo "  Configuring msmtp (dedicated config)..."
    cat > "$MSMTP_RC" <<MSMTPEOF
# Claude Code Backup — msmtp configuration
# Used by: claude-backup-notify.sh -C flag
defaults
auth           on
tls            on
tls_starttls   on
logfile        ~/Library/Logs/claude-backup/msmtp.log

account        gmail
host           smtp.gmail.com
port           587
from           ${GMAIL_KEYCHAIN_ACCOUNT}
user           ${GMAIL_KEYCHAIN_ACCOUNT}
passwordeval   security find-generic-password -s ${GMAIL_KEYCHAIN_SERVICE} -a ${GMAIL_KEYCHAIN_ACCOUNT} -w

account default : gmail
MSMTPEOF
    chmod 600 "$MSMTP_RC"
    echo "  msmtp configured at $MSMTP_RC"
fi
echo ""

# ── Step 5: Create log directory ──────────────────────────────────────
echo "── Step 5: Log directory ──"
mkdir -p "$LOG_DIR"
echo "  Log directory: $LOG_DIR"
echo ""

# ── Step 6: Update plist paths and install LaunchAgents ───────────────
echo "── Step 6: LaunchAgents ──"
mkdir -p "$LAUNCH_AGENTS_DIR"

# Update plists with the current user's home directory
for PLIST_FILE in com.claude-backup.plist com.claude-backup-notify.plist; do
    if [[ -f "$SCRIPT_DIR/$PLIST_FILE" ]]; then
        sed -i '' "s|/Users/youruser|$HOME|g" "$SCRIPT_DIR/$PLIST_FILE"
    fi
done

for PLIST in com.claude-backup.plist com.claude-backup-notify.plist; do
    PLIST_SRC="$SCRIPT_DIR/$PLIST"
    PLIST_DEST="$LAUNCH_AGENTS_DIR/$PLIST"
    LABEL="${PLIST%.plist}"

    # Unload if already loaded
    if launchctl list "$LABEL" &>/dev/null 2>&1; then
        echo "  Unloading existing $LABEL..."
        launchctl unload "$PLIST_DEST" 2>/dev/null || true
    fi

    # Symlink (so git updates propagate)
    ln -sf "$PLIST_SRC" "$PLIST_DEST"
    echo "  Symlinked: $PLIST → $PLIST_DEST"

    # Load
    launchctl load "$PLIST_DEST"
    echo "  Loaded: $LABEL"
done
echo ""

# ── Step 7: Run initial test backup ──────────────────────────────────
echo "── Step 7: Initial Backup ──"
echo "  Running first backup..."
echo ""
if bash "$SCRIPT_DIR/claude-backup.sh"; then
    echo ""
    echo "  Initial backup completed successfully!"
else
    echo ""
    echo "  Initial backup completed with warnings (check log for details)"
fi
echo ""

# ── Done ──────────────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  Setup Complete!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Schedule:"
echo "    Backup runs daily at 2:00 AM"
echo "    Email notification at 7:30 AM"
echo ""
echo "  Ad-hoc commands:"
echo "    Full backup:"
echo "      ~/Projects/claude_backup/_backup_tools/claude-backup.sh"
echo ""
echo "    Skip NAS:"
echo "      NAS_BACKUP_ENABLED=false ~/Projects/claude_backup/_backup_tools/claude-backup.sh"
echo ""
echo "    Skip conversation cache:"
echo "      INCLUDE_CONVERSATION_CACHE=false ~/Projects/claude_backup/_backup_tools/claude-backup.sh"
echo ""
echo "    Send notification now:"
echo "      ~/Projects/claude_backup/_backup_tools/claude-backup-notify.sh"
echo ""
echo "  Verify LaunchAgents:"
echo "    launchctl list | grep claude-backup"
echo ""

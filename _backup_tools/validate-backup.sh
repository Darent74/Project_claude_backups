#!/usr/bin/env bash
set -uo pipefail
# Claude Code Backup — Validation & Verification Script
# Runs all pre-flight checks to confirm the backup system is operational.
# Safe to run at any time — mounts are tested then immediately unmounted.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/backup.conf"

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✅ PASS: $*"; ((PASS++)); }
fail() { echo "  ❌ FAIL: $*"; ((FAIL++)); }
warn() { echo "  ⚠️  WARN: $*"; ((WARN++)); }
section() { echo ""; echo "── $* ──────────────────────────────────────"; }

echo "═══════════════════════════════════════════════════════════"
echo "  Claude Code Backup — Validation"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "═══════════════════════════════════════════════════════════"

# ── 1. Configuration ──────────────────────────────────────────────────
section "Configuration"

if [[ -f "$SCRIPT_DIR/backup.conf" ]]; then
    pass "backup.conf exists"
else
    fail "backup.conf not found at $SCRIPT_DIR/backup.conf"
fi

for var in BACKUP_SOURCE BACKUP_REPO NAS_SHARE NAS_MOUNT_BASE NAS_SUBDIR \
           NAS_KEYCHAIN_SERVICE NAS_KEYCHAIN_ACCOUNT NAS_CONNECT_TIMEOUT \
           NAS_MOUNT_TIMEOUT NOTIFY_EMAIL; do
    if [[ -n "${!var:-}" ]]; then
        pass "$var is set (${!var})"
    else
        fail "$var is not set"
    fi
done

# ── 2. Source & Repo ──────────────────────────────────────────────────
section "Source & Repository"

if [[ -d "$BACKUP_SOURCE" ]]; then
    pass "Source directory exists: $BACKUP_SOURCE"
else
    fail "Source directory missing: $BACKUP_SOURCE"
fi

if [[ -d "$BACKUP_REPO/.git" ]]; then
    pass "Backup repo is a git repository: $BACKUP_REPO"
else
    fail "Backup repo is not a git repository: $BACKUP_REPO"
fi

if git -C "$BACKUP_REPO" remote get-url origin &>/dev/null; then
    REMOTE_URL=$(git -C "$BACKUP_REPO" remote get-url origin)
    pass "Git remote 'origin' configured: $REMOTE_URL"
    if git -C "$BACKUP_REPO" ls-remote --exit-code origin &>/dev/null; then
        pass "Git remote is reachable"
    else
        fail "Git remote is not reachable"
    fi
else
    fail "No git remote 'origin' configured"
fi

# ── 3. Mount Directory ────────────────────────────────────────────────
section "NAS Mount Directory"

if [[ -d "$NAS_MOUNT_BASE" ]]; then
    pass "Mount directory exists: $NAS_MOUNT_BASE"
    MOUNT_OWNER=$(stat -f '%Su' "$NAS_MOUNT_BASE" 2>/dev/null)
    if [[ "$MOUNT_OWNER" == "$(whoami)" ]]; then
        pass "Mount directory owned by current user ($MOUNT_OWNER)"
    else
        fail "Mount directory owned by $MOUNT_OWNER, expected $(whoami)"
    fi
else
    fail "Mount directory missing: $NAS_MOUNT_BASE — run: mkdir -p $NAS_MOUNT_BASE"
fi

# ── 4. NAS Connectivity ──────────────────────────────────────────────
section "NAS Connectivity"

NAS_HOST=$(echo "$NAS_SHARE" | sed 's|^//||; s|/.*||')

if ping -c 1 -W 3 "$NAS_HOST" &>/dev/null; then
    pass "NAS host reachable via ping: $NAS_HOST"
else
    warn "NAS host not responding to ping (may have ICMP disabled): $NAS_HOST"
fi

if nc -z -w "$NAS_CONNECT_TIMEOUT" "$NAS_HOST" 445 2>/dev/null; then
    pass "NAS SMB port 445 is open"
else
    fail "NAS SMB port 445 is not reachable (timeout ${NAS_CONNECT_TIMEOUT}s)"
fi

# ── 5. Keychain Entries ──────────────────────────────────────────────
section "Keychain Credentials"

if security find-generic-password -s "$NAS_KEYCHAIN_SERVICE" -a "$NAS_KEYCHAIN_ACCOUNT" -w &>/dev/null; then
    pass "NAS password found in Keychain (service: $NAS_KEYCHAIN_SERVICE)"
else
    fail "NAS password NOT found in Keychain (service: $NAS_KEYCHAIN_SERVICE, account: $NAS_KEYCHAIN_ACCOUNT)"
fi

if security find-generic-password -s "$GMAIL_KEYCHAIN_SERVICE" -a "$GMAIL_KEYCHAIN_ACCOUNT" -w &>/dev/null; then
    pass "Gmail App Password found in Keychain (service: $GMAIL_KEYCHAIN_SERVICE)"
else
    fail "Gmail App Password NOT found in Keychain (service: $GMAIL_KEYCHAIN_SERVICE)"
fi

# ── 6. NAS Mount + Write Test ────────────────────────────────────────
section "NAS Mount & Write Test"

if [[ "$NAS_BACKUP_ENABLED" == "true" ]] && nc -z -w 3 "$NAS_HOST" 445 2>/dev/null; then
    NAS_PASS=$(security find-generic-password -s "$NAS_KEYCHAIN_SERVICE" -a "$NAS_KEYCHAIN_ACCOUNT" -w 2>/dev/null || echo "")
    if [[ -n "$NAS_PASS" ]]; then
        URL_PASS=$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1],safe=''))" "$NAS_PASS")
        SMB_URL="//${NAS_KEYCHAIN_ACCOUNT}:${URL_PASS}@${NAS_SHARE#//}"
        unset NAS_PASS URL_PASS

        # Clean up any stale mount
        if mount | grep -q "$NAS_MOUNT_BASE" 2>/dev/null; then
            umount "$NAS_MOUNT_BASE" 2>/dev/null || true
            sleep 1
        fi

        if timeout "$NAS_MOUNT_TIMEOUT" mount_smbfs "$SMB_URL" "$NAS_MOUNT_BASE" 2>/dev/null; then
            pass "mount_smbfs succeeded to $NAS_MOUNT_BASE"

            if touch "$NAS_MOUNT_BASE/.validate_test" 2>/dev/null; then
                rm -f "$NAS_MOUNT_BASE/.validate_test" 2>/dev/null
                pass "Write access confirmed on NAS mount"
            else
                fail "NAS mount is read-only — write test failed"
            fi

            # Test subdirectory creation
            TEST_DIR="$NAS_MOUNT_BASE/${NAS_SUBDIR}/.validate_dir_test"
            if mkdir -p "$TEST_DIR" 2>/dev/null; then
                rmdir "$TEST_DIR" 2>/dev/null
                pass "Can create subdirectories under $NAS_SUBDIR"
            else
                fail "Cannot create subdirectories under $NAS_SUBDIR — check NAS ACLs"
            fi

            umount "$NAS_MOUNT_BASE" 2>/dev/null || true
            pass "NAS unmounted cleanly"
        else
            fail "mount_smbfs failed (timeout ${NAS_MOUNT_TIMEOUT}s)"
        fi
        unset SMB_URL
    else
        fail "Could not retrieve NAS password for mount test"
    fi
else
    warn "Skipping mount test (NAS disabled or unreachable)"
fi

# ── 7. Required Tools ────────────────────────────────────────────────
section "Required Tools"

for tool in rsync git msmtp python3 nc timeout; do
    if command -v "$tool" &>/dev/null; then
        TOOL_PATH=$(command -v "$tool")
        pass "$tool found: $TOOL_PATH"
    else
        fail "$tool not found in PATH"
    fi
done

# Check for Homebrew GNU rsync specifically
if [[ -x "/opt/homebrew/bin/rsync" ]]; then
    GNU_RSYNC_VER=$(/opt/homebrew/bin/rsync --version 2>/dev/null | head -1)
    pass "Homebrew GNU rsync: $GNU_RSYNC_VER"
else
    warn "Homebrew GNU rsync not found — will fall back to system rsync (may fail on NAS under launchd)"
fi

# ── 8. msmtp Email Test ──────────────────────────────────────────────
section "Email (msmtp)"

if [[ -f "$SCRIPT_DIR/.msmtprc" ]]; then
    pass "msmtp config exists: $SCRIPT_DIR/.msmtprc"
else
    fail "msmtp config missing: $SCRIPT_DIR/.msmtprc"
fi

# ── 9. LaunchAgent State ─────────────────────────────────────────────
section "LaunchAgent State"

if launchctl list 2>/dev/null | grep -q "com.claude-backup$"; then
    pass "com.claude-backup is loaded"
    # Check exit status
    AGENT_EXIT=$(launchctl list 2>/dev/null | grep "com.claude-backup$" | awk '{print $2}')
    if [[ "$AGENT_EXIT" == "0" ]]; then
        pass "Last run exit code: 0 (success)"
    else
        warn "Last run exit code: $AGENT_EXIT (check logs)"
    fi
else
    fail "com.claude-backup is NOT loaded"
fi

if launchctl list 2>/dev/null | grep -q "com.claude-backup-notify"; then
    warn "com.claude-backup-notify is still loaded (should be removed — notification is now inline)"
else
    pass "com.claude-backup-notify is NOT loaded (correct — notification is inline)"
fi

# ── 10. Backup Scripts ───────────────────────────────────────────────
section "Backup Scripts"

for script in claude-backup.sh claude-backup-notify.sh; do
    SPATH="$SCRIPT_DIR/$script"
    if [[ -f "$SPATH" ]]; then
        if [[ -x "$SPATH" ]]; then
            pass "$script exists and is executable"
        else
            fail "$script exists but is NOT executable — run: chmod +x $SPATH"
        fi
    else
        fail "$script not found at $SPATH"
    fi
done

# ── Summary ──────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed, $WARN warnings"
echo "═══════════════════════════════════════════════════════════"

if [[ "$FAIL" -gt 0 ]]; then
    echo "  ❌ VALIDATION FAILED — fix the issues above before relying on automated backups"
    exit 1
elif [[ "$WARN" -gt 0 ]]; then
    echo "  ⚠️  VALIDATION PASSED WITH WARNINGS — review the warnings above"
    exit 0
else
    echo "  ✅ ALL CHECKS PASSED — backup system is fully operational"
    exit 0
fi

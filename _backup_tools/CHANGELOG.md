# Changelog — Claude Code Backup System

All notable changes to this project are documented below.

---

## [2.0.0] — 2026-03-18

### Summary

Major reliability overhaul. The backup system is now **foolproof** — it works without a logged-in user, NAS operations fail fast instead of hanging, email notifications are guaranteed to arrive after backup completion, and NAS retention is based on successful backup count rather than age.

---

### Changed

#### NAS Mounting — Replaced Finder Fallback with Direct `mount_smbfs`

**Before:** When `mount_smbfs` encountered a sandbox restriction under launchd, the script fell back to `osascript -e 'mount volume "smb://..."'` which requires a GUI session (WindowServer). If no user was logged in, this hung indefinitely — on 2026-03-18 it hung for **1 hour 49 minutes** before the Finder session finally appeared.

**After:** The Finder/osascript fallback has been **removed entirely**. The script now:

1. **Pre-checks connectivity** with `nc -z -w $timeout host 445` — if the NAS is offline, the script skips NAS backup immediately instead of hanging.
2. **Mounts with timeout** using `timeout $NAS_MOUNT_TIMEOUT mount_smbfs ...` — if the mount hangs, it's killed after 30 seconds (configurable).
3. **Mounts to a user-owned directory** at `~/mounts/claude-backup` instead of `/tmp/` or `/Volumes/`. This directory is owned by the user, persists across reboots, and is not subject to launchd sandbox restrictions on write access.
4. **Write-tests immediately** after mounting — if the mount is read-only, fails fast with a clear error.

**Impact:** NAS backup now completes in ~40 seconds instead of potentially hanging for hours. Works identically whether the user is logged in or not.

| Config Key | Old Value | New Value |
|------------|-----------|-----------|
| `NAS_MOUNT_POINT` | `/tmp/claude_nas_mount` | *(removed)* |
| `NAS_MOUNT_BASE` | *(new)* | `$HOME/mounts/claude-backup` |
| `NAS_CONNECT_TIMEOUT` | *(new)* | `10` seconds |
| `NAS_MOUNT_TIMEOUT` | *(new)* | `30` seconds |

#### Notification — Inline After Backup Completion

**Before:** A separate LaunchAgent (`com.claude-backup-notify`) ran on a fixed timer (6:45 AM, 15 minutes after the 6:30 AM backup). If the backup took longer than 15 minutes, the notification script found an incomplete log file and crashed silently — no email was sent.

**After:** The notification script is now called **directly by the backup script** as its final step, after all operations (rsync, git, NAS) are complete. The separate notify LaunchAgent has been removed.

Additional safeguards:
- The notification script accepts the log file path as `$1` (no more guessing which log to parse)
- A guard checks for the `──── END ────` marker before parsing — if the log is somehow incomplete, it exits cleanly instead of crashing
- Fallback: if run standalone (no `$1` argument), it falls back to finding the latest complete log

**Removed files:**
- `com.claude-backup-notify.plist` — no longer needed

#### NAS Retention — Keep 7 Successful Backups

**Before:** NAS backups older than 30 days were pruned by file modification time (`find -mtime +30`). This meant the NAS could accumulate unlimited backups within 30 days, and a month of failed backups would still consume space.

**After:** The system now keeps exactly **7 successful backups** on the NAS (configurable via `NAS_RETENTION` in `backup.conf`). Retention is based on a `.backup_complete` marker file that is only written after a successful rsync to NAS.

Behavior:
- After a successful NAS sync, a `.backup_complete` timestamp file is written to the backup directory
- During pruning, only directories with this marker are counted as "good" backups
- When the count exceeds `NAS_RETENTION`, the oldest successful backups are deleted
- Incomplete backups (no marker) are cleaned up automatically

| Config Key | Old Value | New Value |
|------------|-----------|-----------|
| *(30-day prune)* | `find -mtime +30` | *(removed)* |
| `NAS_RETENTION` | *(new)* | `7` |

### Added

#### Duration Tracking

Every backup now records its total duration using the bash `$SECONDS` built-in. Duration appears in:
- The log file summary block (`DURATION=0m 44s`)
- The email notification report

#### EXIT Trap Cleanup

The script now registers a comprehensive EXIT trap that:
- Removes the lockfile (prevents stale locks after crashes)
- Unmounts any NAS mount at `$NAS_MOUNT_BASE` (prevents stale mounts after crashes or `kill`)

#### Validation Script (`validate-backup.sh`)

New comprehensive pre-flight validation script that checks 38 items:

| Category | Checks |
|----------|--------|
| Configuration | All required variables set |
| Source & Repo | Directories exist, git remote reachable |
| Mount Directory | Exists, user-owned |
| NAS Connectivity | Ping, SMB port 445 |
| Keychain | NAS password, Gmail App Password |
| NAS Mount & Write | Live mount + write test + subdirectory creation + unmount |
| Required Tools | rsync, git, msmtp, python3, nc, timeout, GNU rsync |
| Email | msmtp config exists |
| LaunchAgent | Backup agent loaded, notify agent removed, last exit code |
| Scripts | Exist and are executable |

Run with:
```bash
~/Projects/claude_backup/_backup_tools/validate-backup.sh
```

---

### Migration Guide

If upgrading from the previous version:

#### 1. Create the mount directory

```bash
mkdir -p ~/mounts/claude-backup
```

#### 2. Unload and remove the notify LaunchAgent

```bash
launchctl unload ~/Library/LaunchAgents/com.claude-backup-notify.plist
rm ~/Library/LaunchAgents/com.claude-backup-notify.plist
```

#### 3. Update your `backup.conf`

Replace:
```bash
NAS_MOUNT_POINT="/tmp/claude_nas_mount"
```

With:
```bash
NAS_MOUNT_BASE="$HOME/mounts/claude-backup"
NAS_CONNECT_TIMEOUT=10
NAS_MOUNT_TIMEOUT=30
NAS_RETENTION=7
```

#### 4. Update the scripts

Copy the new versions of `claude-backup.sh`, `claude-backup-notify.sh`, and `validate-backup.sh` to your `_backup_tools/` directory.

#### 5. Reload the backup LaunchAgent

```bash
launchctl unload ~/Library/LaunchAgents/com.claude-backup.plist
launchctl load ~/Library/LaunchAgents/com.claude-backup.plist
```

#### 6. Validate

```bash
~/Projects/claude_backup/_backup_tools/validate-backup.sh
```

---

## [1.0.0] — 2026-03-13

### Initial Release

- rsync-based mirroring of `~/.claude` to a git repository
- Git commit + push to GitHub (private repo)
- Optional NAS backup via SMB with Finder fallback
- Email notifications via msmtp + Gmail App Password
- macOS LaunchAgent scheduling (backup + separate notification)
- Lockfile-based concurrency protection
- Pre-commit large file detection (90MB GitHub limit)
- 30-day log and NAS backup pruning
- Full restoration guide (MD + HTML)
- Interactive setup script

---

*Created by: DT74 — Daren Threadingham*

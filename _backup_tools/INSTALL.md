# Claude Code Backup System

Automated daily backup of your `~/.claude` directory to GitHub and optionally to a NAS file share, with email notifications.

## What Gets Backed Up

Your `~/.claude` directory contains everything that makes Claude Code yours:

| Content | Examples |
|---------|----------|
| Skills | Custom skills you've built or installed |
| Agents | Custom agent configurations |
| Plugins | Installed plugins and local plugins |
| Commands | Custom slash commands |
| Hooks | PreToolUse / PostToolUse hooks |
| Settings | `settings.json`, `settings.local.json` |
| Conversation history | Project contexts, file history, debug logs |
| Plans & tasks | Active plans and task lists |

**Excluded automatically:** caches, telemetry, lock files, IDE state, temporary downloads — things that regenerate on their own.

## How It Works

```
~/.claude/                          ← source (your Claude Code config)
    │
    │  rsync (mirrors content)
    ▼
~/Projects/claude_backup/           ← git repo (the backup)
    │
    ├── git commit + push ──────────► GitHub (private repo, versioned history)
    │
    └── rsync over SMB ────────────► NAS file share (optional secondary backup)
```

- **Daily at 2:00 AM**: backup script runs via macOS LaunchAgent
- **Daily at 7:30 AM**: notification script emails you a status report
- Git history provides point-in-time restore capability
- Each step is independent — Git failure doesn't block NAS, and vice versa

## Prerequisites

| Requirement | Install | Verify |
|-------------|---------|--------|
| macOS | — | `sw_vers` |
| Homebrew | [brew.sh](https://brew.sh) | `brew --version` |
| Git | `brew install git` | `git --version` |
| GitHub CLI | `brew install gh` | `gh --version` |
| gh authenticated | `gh auth login` | `gh auth status` |
| Python 3 | Included with macOS | `python3 --version` |

## Installation

### 1. Clone This Repository

```bash
git clone https://github.com/your-username/claude-code-backup.git ~/Projects/claude_backup
```

Or fork it first if you want your own copy, then clone your fork.

### 2. Configure `backup.conf`

Edit `_backup_tools/backup.conf` to match your environment:

```bash
nano ~/Projects/claude_backup/_backup_tools/backup.conf
```

**Required changes:**

```bash
# ── Source & Destination ──────────────────────────────────────────────
BACKUP_SOURCE="$HOME/.claude"
BACKUP_REPO="$HOME/Projects/claude_backup"       # ← path where you cloned this repo
LOG_DIR="$HOME/Library/Logs/claude-backup"

# ── NAS Settings ──────────────────────────────────────────────────────
NAS_BACKUP_ENABLED=true                           # ← set to false if you don't have a NAS
NAS_SHARE="//YOUR-NAS-IP/YOUR-SHARE-NAME"         # ← your SMB share
NAS_MOUNT_POINT="/tmp/claude_nas_mount"
NAS_SUBDIR="claude_code_backup"                   # ← subfolder within the share
NAS_KEYCHAIN_SERVICE="claude-backup-nas"
NAS_KEYCHAIN_ACCOUNT="your-nas-username"          # ← your NAS service account

# ── Email Notification ────────────────────────────────────────────────
NOTIFY_EMAIL="you@gmail.com"                      # ← your Gmail address
GMAIL_KEYCHAIN_SERVICE="claude-backup-gmail"
GMAIL_KEYCHAIN_ACCOUNT="you@gmail.com"            # ← your Gmail address
```

**If you don't have a NAS**, just set `NAS_BACKUP_ENABLED=false` — everything else works without it.

### 3. Update the LaunchAgent Plists

The plist files contain hardcoded paths. Update them to match your username:

```bash
cd ~/Projects/claude_backup/_backup_tools

# Replace the username in both plists
sed -i '' "s|/Users/youruser|$HOME|g" com.claude-backup.plist
sed -i '' "s|/Users/youruser|$HOME|g" com.claude-backup-notify.plist
```

Verify the paths look correct:

```bash
grep -A1 "ProgramArguments\|StandardOutPath" com.claude-backup.plist
```

### 4. Set Up Your GitHub Remote

If you forked the repo, the remote is already set. If you cloned directly and want to push to your own repo:

```bash
cd ~/Projects/claude_backup

# Create your own private repo
gh repo create YOUR-USERNAME/claude-code-backup --private

# Update the remote
git remote set-url origin https://github.com/YOUR-USERNAME/claude-code-backup.git
```

### 5. Run the Interactive Setup

```bash
bash ~/Projects/claude_backup/_backup_tools/setup.sh
```

The setup script will:

1. Install `msmtp` (email client) via Homebrew
2. Initialize the git repo and set the remote
3. Prompt for your **NAS password** (stored in macOS Keychain — never in plaintext)
4. Prompt for your **Gmail App Password** (see below)
5. Configure msmtp for email notifications
6. Create the log directory
7. Install and load the LaunchAgent schedules
8. Run an initial test backup

### 6. Create a Gmail App Password

Gmail requires an App Password when 2-factor authentication is enabled:

1. Go to [https://myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords)
2. Sign in to your Google account
3. Click **Select app** → choose **Other** → enter "claude-backup"
4. Click **Generate**
5. Copy the 16-character password — the setup script will prompt for this

**Note:** If you don't use Gmail, you can modify `_backup_tools/.msmtprc` after setup to use any SMTP provider (Outlook, Fastmail, etc.).

### 7. Verify Everything Works

```bash
# Check LaunchAgents are registered
launchctl list | grep claude-backup

# Run a manual backup
~/Projects/claude_backup/_backup_tools/claude-backup.sh

# Send a test notification
~/Projects/claude_backup/_backup_tools/claude-backup-notify.sh

# Check your inbox for the report email
```

## Usage

### Automatic (Default)

Once installed, backups run automatically:

- **2:00 AM daily** — full backup (rsync + git push + NAS sync)
- **7:30 AM daily** — email notification with backup status

### Manual / Ad-Hoc

```bash
# Full backup
~/Projects/claude_backup/_backup_tools/claude-backup.sh

# Backup without NAS (GitHub only)
NAS_BACKUP_ENABLED=false ~/Projects/claude_backup/_backup_tools/claude-backup.sh

# Backup without conversation cache (smaller, faster)
INCLUDE_CONVERSATION_CACHE=false ~/Projects/claude_backup/_backup_tools/claude-backup.sh

# Send notification email
~/Projects/claude_backup/_backup_tools/claude-backup-notify.sh
```

### What Gets Excluded

These are automatically excluded from backups (they regenerate or aren't useful):

| Excluded | Reason |
|----------|--------|
| `cache/`, `plugins/cache/` | Regenerates automatically |
| `telemetry/`, `statsig/` | Analytics data, not config |
| `session-env/`, `ide/` | Session-specific state |
| `paste-cache/`, `downloads/` | Temporary content |
| `backups/` | Claude Code's own internal backups |
| `*.lock` | Lock files |
| `.DS_Store` | macOS metadata |

When `INCLUDE_CONVERSATION_CACHE=false`, these are also excluded:

| Excluded | Reason |
|----------|--------|
| `projects/` | Conversation history per project |
| `file-history/` | File change tracking |
| `debug/` | Debug session logs |
| `shell-snapshots/` | Shell state captures |

## Restoration

See `RESTORE.md` (or `RESTORE.html` for the styled version) for full restoration procedures including:

- Quick full restore (3 commands)
- Selective restore (specific skills, agents, or files)
- Point-in-time restore from Git history
- Restore from NAS when GitHub is unavailable

## File Structure

```
~/Projects/claude_backup/
├── _backup_tools/                    ← all backup infrastructure
│   ├── backup.conf                   ← configuration (edit this)
│   ├── claude-backup.sh              ← main backup script
│   ├── claude-backup-notify.sh       ← email notification script
│   ├── setup.sh                      ← one-time interactive setup
│   ├── com.claude-backup.plist  ← LaunchAgent (daily 2:00 AM)
│   ├── com.claude-backup-notify.plist  ← LaunchAgent (daily 7:30 AM)
│   ├── INSTALL.md                    ← this file
│   ├── INSTALL.html                  ← styled HTML version
│   ├── RESTORE.md                    ← restoration guide
│   └── RESTORE.html                  ← styled restoration guide
├── .gitignore
├── CLAUDE.md                         ← project documentation
├── notes.md                          ← original planning notes
│
│   ... mirrored ~/.claude content ...
├── skills/
├── agents/
├── plugins/
├── hooks/
├── commands/
├── settings.json
└── ...
```

## Security

- **No plaintext passwords** — NAS and Gmail credentials are stored in macOS Keychain and retrieved at runtime
- **SMB passwords are URL-encoded** — special characters in passwords are handled correctly
- **Credentials cleared from memory** — variables are `unset` immediately after use
- **Dedicated msmtp config** — stored in `_backup_tools/.msmtprc` (gitignored), won't conflict with your system config
- **Lockfile protection** — prevents concurrent backup runs from corrupting state
- **Pre-commit size check** — files over 90MB are flagged before committing (GitHub's limit is 100MB)

## Customization

### Change the Backup Schedule

Edit the plist, then reload:

```bash
# Edit the hour/minute in the plist
nano ~/Projects/claude_backup/_backup_tools/com.claude-backup.plist

# Reload (required for plist changes to take effect)
launchctl unload ~/Library/LaunchAgents/com.claude-backup.plist
launchctl load ~/Library/LaunchAgents/com.claude-backup.plist
```

**Note:** Changes to bash scripts take effect immediately. Only plist changes need a reload.

### Disable NAS Backup

Set in `backup.conf`:

```bash
NAS_BACKUP_ENABLED=false
```

Or override per-run:

```bash
NAS_BACKUP_ENABLED=false ~/Projects/claude_backup/_backup_tools/claude-backup.sh
```

### Use a Different Email Provider

Edit `_backup_tools/.msmtprc` after running setup:

```
account        outlook
host           smtp-mail.outlook.com
port           587
from           you@outlook.com
user           you@outlook.com
passwordeval   security find-generic-password -s claude-backup-email -a you@outlook.com -w

account default : outlook
```

### Add/Remove rsync Excludes

Edit the `RSYNC_EXCLUDES` array in `claude-backup.sh` to include or exclude additional directories.

## Logs

Backup logs are stored in `~/Library/Logs/claude-backup/` and automatically pruned after 30 days.

```bash
# View the latest log
ls -t ~/Library/Logs/claude-backup/backup_*.log | head -1 | xargs cat

# View all available logs
ls ~/Library/Logs/claude-backup/
```

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| NAS mount "No route to host" but server pings | Password has special characters | Script URL-encodes automatically; verify password: `security find-generic-password -s claude-backup-nas -w` |
| NAS mount "Permission denied" on mkdir | Mount point under `/Volumes/` | Use `/tmp/` mount point (default in config) |
| NAS subfolder access denied | Service account lacks permissions | Fix share ACLs on the NAS |
| Gmail auth fails | Not using App Password | Generate at [myaccount.google.com/apppasswords](https://myaccount.google.com/apppasswords) |
| Schedule change not working | Plist not reloaded | `launchctl unload` then `launchctl load` the plist |
| `git`/`msmtp` not found at 2 AM | PATH not set in LaunchAgent | Check `EnvironmentVariables` in plist includes `/opt/homebrew/bin` |
| Backup script hangs | Previous run didn't clean up | Delete `~/Library/Logs/claude-backup/.claude-backup.lock` |

## License

MIT — use it, fork it, adapt it to your needs.

---

*Created by: DT74 — Daren Threadingham*

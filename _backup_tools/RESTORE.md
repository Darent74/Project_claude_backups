# Claude Code Backup — Restoration Guide

## Prerequisites

| Requirement | Install Command | Verify |
|-------------|----------------|--------|
| macOS | — | `sw_vers` |
| Homebrew | `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"` | `brew --version` |
| Git | `brew install git` | `git --version` |
| GitHub CLI | `brew install gh` | `gh --version` |
| gh authenticated | `gh auth login` | `gh auth status` |

## Quick Restore (macOS — Full)

Four steps to restore everything:

```bash
# 1. Clone the backup repo
gh repo clone your-username/claude-code-backup ~/Projects/claude_backup

# 2. Restore ~/.claude (merges into existing, won't delete extras)
rsync -av --exclude='_backup_tools/' --exclude='.git/' --exclude='.gitignore' \
    ~/Projects/claude_backup/ ~/.claude/

# 3. Re-inject secrets (repo copy has placeholders, not real values)
#    Option A: edit settings.json directly
#    Replace "__GITHUB_PAT_SET_VIA_ENV__" and "__ATLASSIAN_TOKEN_SET_VIA_ENV__"
#    with your actual tokens in ~/.claude/settings.json
#
#    Option B (recommended): set env vars in your shell profile (~/.zshrc)
#    export GITHUB_PERSONAL_ACCESS_TOKEN="your-github-pat"
#    export ATLASSIAN_API_TOKEN="your-atlassian-token"
#    Shell env vars override settings.json values at runtime.

# 4. Re-enable automated backups
cd ~/Projects/claude_backup && bash _backup_tools/setup.sh
```

After restoring, restart Claude Code to pick up the restored configuration.

## Quick Restore (Linux — Remote Server)

Deploy skills and config to a Linux server from the backup repo:

```bash
# 1. Clone the backup repo
git clone git@github.com:your-username/claude-code-backup.git ~/claude-backup

# 2. Run the automated setup script
~/claude-backup/_backup_tools/linux-setup.sh
```

The setup script will:
- Copy skills, agents, commands, and hooks to `~/.claude/`
- Generate a settings.json with Linux-appropriate paths (rewrites macOS paths)
- Remove macOS-only hooks (e.g. sound notifications)
- List marketplace plugins and offer to install them
- Prompt you to set environment variables for secrets

## Selective Restore

Restore only specific directories or files:

```bash
# Restore just skills
rsync -av ~/Projects/claude_backup/skills/ ~/.claude/skills/

# Restore just agents
rsync -av ~/Projects/claude_backup/agents/ ~/.claude/agents/

# Restore a single file
cp ~/Projects/claude_backup/settings.json ~/.claude/settings.json

# Restore hooks
rsync -av ~/Projects/claude_backup/hooks/ ~/.claude/hooks/
```

## Point-in-Time Restore

Use Git history to restore from a specific backup:

```bash
# View backup history
cd ~/Projects/claude_backup
git log --oneline

# Check what changed in a specific backup
git show <commit-hash> --stat

# Restore from a specific point in time
git checkout <commit-hash> -- skills/
rsync -av skills/ ~/.claude/skills/

# Or restore the entire state from a date
git checkout <commit-hash>
rsync -av --exclude='_backup_tools/' --exclude='.git/' --exclude='.gitignore' \
    ./ ~/.claude/
git checkout main  # return to latest
```

## Restore from NAS

If GitHub is unavailable, restore from the NAS backup:

```bash
# Create mount point with full RW permissions
mkdir -p ~/mounts/claude-restore
chmod 0777 ~/mounts/claude-restore

# Mount the NAS share (use hostname or IP)
mount_smbfs -f 0777 -d 0777 //nas-service-account@your-nas-host/your-share ~/mounts/claude-restore

# List available backup dates
ls ~/mounts/claude-restore/claude_code_backup/

# Restore from a specific date
rsync -av --exclude='.git/' \
    ~/mounts/claude-restore/claude_code_backup/2026-03-21/ ~/.claude/

# Re-inject secrets (see Quick Restore step 3 above)

# Unmount
diskutil unmount ~/mounts/claude-restore
```

## Verification

After restoring, confirm everything loaded correctly:

```bash
# Check directory structure
ls ~/.claude/skills/
ls ~/.claude/agents/

# Verify settings file is valid JSON
python3 -c "import json; json.load(open('$HOME/.claude/settings.json'))"

# Count restored items
echo "Skills: $(ls ~/.claude/skills/ 2>/dev/null | wc -l | tr -d ' ')"
echo "Agents: $(ls ~/.claude/agents/ 2>/dev/null | wc -l | tr -d ' ')"

# Launch Claude Code and verify
claude --version
```

## Managing the Backup System

### Checking LaunchAgent Status

```bash
# Verify both agents are registered
launchctl list | grep claude-backup
```

### Changing the Backup Schedule

Edit the plist file to change the time, then reload:

```bash
# Example: change backup to 3:00 AM
# Edit _backup_tools/com.claude-backup.plist — change <integer>2</integer> to <integer>3</integer>

# Reload the agent (required after any plist change)
launchctl unload ~/Library/LaunchAgents/com.claude-backup.plist
launchctl load ~/Library/LaunchAgents/com.claude-backup.plist
```

**Note:** Plist changes (schedule, paths, environment variables) only take effect after unload + load. Changes to the bash scripts do NOT require reloading — they are picked up automatically on next run.

### Disabling/Enabling Backups

```bash
# Temporarily disable the backup schedule
launchctl unload ~/Library/LaunchAgents/com.claude-backup.plist

# Re-enable
launchctl load ~/Library/LaunchAgents/com.claude-backup.plist
```

### Changing NAS Settings

Edit `_backup_tools/backup.conf` to change the NAS share, mount point, or subdirectory. No reload required — the script reads the config at runtime.

To update the NAS password in Keychain:

```bash
security add-generic-password -U \
    -s claude-backup-nas \
    -a nas-service-account \
    -w "new-password-here"
```

### Viewing Backup Logs

```bash
# Latest log
ls -t ~/Library/Logs/claude-backup/backup_*.log | head -1 | xargs cat

# All logs (last 30 days retained)
ls ~/Library/Logs/claude-backup/
```

## Troubleshooting

| Issue | Cause | Fix |
|-------|-------|-----|
| `gh repo clone` fails | Not authenticated | Run `gh auth login` |
| rsync permission errors | File ownership mismatch | Add `--chmod=u+rw` to rsync |
| Skills not loading after restore | Claude Code caching | Restart Claude Code |
| NAS mount "No route to host" but ping works | Password has special characters breaking SMB URL | Script already URL-encodes; verify with `python3 -c "import urllib.parse; ..."` |
| NAS mount "No route to host" via IP | Not on LAN / VPN | Use a Tailscale hostname instead of IP in `backup.conf` |
| NAS mount read-only / write fails | Missing mount mode flags | Use `mount_smbfs -f 0777 -d 0777` and `chmod 0777` on mount point directory |
| NAS unmount "Resource busy" | `umount` doesn't flush I/O | Use `diskutil unmount` instead (script does this automatically) |
| NAS mount succeeds but subfolder access denied | Service account lacks ACL on subfolder | Fix NAS share permissions for the service account |
| NAS mount wrong credentials | Stale Keychain entry | `security add-generic-password -U -s claude-backup-nas -a nas-service-account -w "new-pass"` |
| Secrets missing after restore | Repo uses placeholders since sanitization | Re-inject via settings.json edit or shell env vars (see Quick Restore step 3) |
| Schedule change not taking effect | Plist not reloaded | `launchctl unload` then `launchctl load` the plist |
| Backup tools missing from PATH at 2 AM | LaunchAgent missing PATH env | Check `EnvironmentVariables` in plist includes `/opt/homebrew/bin` |
| Git checkout shows conflicts | Local changes exist | `git stash` first, then checkout |
| Empty directories after restore | Git doesn't track empty dirs | Directories are created on first use |

---

*Created by: DT74 — Daren Threadingham*

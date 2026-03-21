#!/usr/bin/env bash
# linux-setup.sh — Deploy Claude Code skills, agents, and config from backup repo to ~/.claude/
# Run this on a Linux server after cloning the backup repo.
#
# Usage:
#   git clone git@github.com:your-username/claude-code-backup.git ~/claude-backup
#   ~/claude-backup/_backup_tools/linux-setup.sh
#
# Prerequisites:
#   - Claude Code installed (npm install -g @anthropic-ai/claude-code)
#   - git, jq (recommended), node

set -euo pipefail

# ── Resolve paths ────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CLAUDE_HOME="$HOME/.claude"

# macOS source path to replace in configs — update this to match your Mac username
MAC_HOME="/Users/your-username"

echo "═══════════════════════════════════════════════════════════"
echo "  Claude Code Linux Setup"
echo "═══════════════════════════════════════════════════════════"
echo "  Repo:         $REPO_ROOT"
echo "  Target:       $CLAUDE_HOME"
echo "═══════════════════════════════════════════════════════════"
echo ""

# ── Pre-flight checks ───────────────────────────────────────────────
MISSING=()
command -v node &>/dev/null  || MISSING+=("node")
command -v git &>/dev/null   || MISSING+=("git")
if [[ ${#MISSING[@]} -gt 0 ]]; then
    echo "ERROR: Missing required tools: ${MISSING[*]}"
    echo "Install them before running this script."
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "WARNING: jq not found — settings.json will use sed for path rewriting"
    echo "         Install jq for more reliable JSON handling"
    echo ""
fi

# ── Create directory structure ───────────────────────────────────────
echo "Creating ~/.claude directory structure..."
mkdir -p "$CLAUDE_HOME"/{skills,agents,commands,hooks,plugins,projects,tasks}

# ── Copy portable components ─────────────────────────────────────────
copy_dir() {
    local name="$1" src="$2" dest="$3"
    if [[ -d "$src" ]] && [[ -n "$(ls -A "$src" 2>/dev/null)" ]]; then
        cp -r "$src"/* "$dest"/
        local count
        count=$(ls -1 "$dest" 2>/dev/null | wc -l | tr -d ' ')
        echo "  ✓ $name: $count items copied"
    else
        echo "  - $name: nothing to copy"
    fi
}

echo ""
echo "Copying components from backup repo..."
copy_dir "Skills"   "$REPO_ROOT/skills"   "$CLAUDE_HOME/skills"
copy_dir "Agents"   "$REPO_ROOT/agents"   "$CLAUDE_HOME/agents"
copy_dir "Commands" "$REPO_ROOT/commands" "$CLAUDE_HOME/commands"
copy_dir "Hooks"    "$REPO_ROOT/hooks"    "$CLAUDE_HOME/hooks"

# ── Copy CLAUDE.md (global instructions) ─────────────────────────────
if [[ -f "$REPO_ROOT/CLAUDE.md" ]]; then
    echo ""
    echo "NOTE: CLAUDE.md in the repo root is project-specific (backup system docs)."
    echo "      Your global ~/.claude/CLAUDE.md needs to be created/copied separately"
    echo "      with Linux-appropriate paths."
fi

# ── Generate sanitized settings.json ─────────────────────────────────
echo ""
echo "Generating settings.json..."

if [[ -f "$REPO_ROOT/settings.json" ]]; then
    cp "$REPO_ROOT/settings.json" "$CLAUDE_HOME/settings.json"

    # ── Rewrite macOS paths to Linux ─────────────────────────────────
    # Replace hardcoded Mac home dir with current $HOME
    if command -v jq &>/dev/null; then
        TEMP=$(mktemp)
        jq --arg old "$MAC_HOME" --arg new "$HOME" '
            # Rewrite all string values recursively
            walk(if type == "string" then gsub($old; $new) else . end)
        ' "$CLAUDE_HOME/settings.json" > "$TEMP" && mv "$TEMP" "$CLAUDE_HOME/settings.json"
    else
        sed -i "s|$MAC_HOME|$HOME|g" "$CLAUDE_HOME/settings.json"
    fi

    # ── Remove macOS-only hooks ──────────────────────────────────────
    if command -v jq &>/dev/null; then
        TEMP=$(mktemp)
        jq '
            # Remove the Stop hook that plays macOS sounds (afplay)
            if .hooks.Stop then
                .hooks.Stop |= map(
                    .hooks |= map(select(.command | test("afplay") | not))
                ) |
                .hooks.Stop |= map(select(.hooks | length > 0))
            else . end |
            # Clean up empty Stop array
            if .hooks.Stop and (.hooks.Stop | length) == 0 then
                del(.hooks.Stop)
            else . end
        ' "$CLAUDE_HOME/settings.json" > "$TEMP" && mv "$TEMP" "$CLAUDE_HOME/settings.json"
        echo "  ✓ Removed macOS-only hooks (afplay sound)"
    else
        echo "  ! Cannot remove macOS hooks without jq — edit manually"
    fi

    # ── Replace secret placeholders with env var instructions ────────
    # The backup repo should already have placeholders from sanitize-settings.sh.
    # If it still has real secrets (pre-sanitization commits), scrub them now.
    if command -v jq &>/dev/null; then
        TEMP=$(mktemp)
        jq '
            .env.GITHUB_PERSONAL_ACCESS_TOKEN = "__SET_VIA_ENV__" |
            .env.ATLASSIAN_API_TOKEN = "__SET_VIA_ENV__"
        ' "$CLAUDE_HOME/settings.json" > "$TEMP" && mv "$TEMP" "$CLAUDE_HOME/settings.json"
    else
        sed -i -E 's|("GITHUB_PERSONAL_ACCESS_TOKEN":[[:space:]]*").*(")|\\1__SET_VIA_ENV__\\2|' "$CLAUDE_HOME/settings.json"
        sed -i -E 's|("ATLASSIAN_API_TOKEN":[[:space:]]*").*(")|\\1__SET_VIA_ENV__\\2|' "$CLAUDE_HOME/settings.json"
    fi

    # ── Remove Mac-specific permission entries ───────────────────────
    if command -v jq &>/dev/null; then
        TEMP=$(mktemp)
        jq '
            .permissions.allow |= map(select(test("backup_tools") | not))
        ' "$CLAUDE_HOME/settings.json" > "$TEMP" && mv "$TEMP" "$CLAUDE_HOME/settings.json"
    fi

    echo "  ✓ settings.json generated (paths rewritten, secrets placeholder'd)"
else
    echo "  ! No settings.json found in repo — you'll need to configure manually"
fi

# ── Copy settings.local.json ─────────────────────────────────────────
if [[ -f "$REPO_ROOT/settings.local.json" ]]; then
    cp "$REPO_ROOT/settings.local.json" "$CLAUDE_HOME/settings.local.json"
    echo "  ✓ settings.local.json copied"
fi

# ── Install marketplace plugins ──────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Marketplace Plugins"
echo "═══════════════════════════════════════════════════════════"
echo ""

# Extract enabled plugin names from settings.json
PLUGINS=()
if [[ -f "$CLAUDE_HOME/settings.json" ]] && command -v jq &>/dev/null; then
    while IFS= read -r plugin; do
        PLUGINS+=("$plugin")
    done < <(jq -r '.enabledPlugins // {} | keys[]' "$CLAUDE_HOME/settings.json" 2>/dev/null)
fi

if [[ ${#PLUGINS[@]} -gt 0 ]]; then
    echo "The following marketplace plugins need to be installed:"
    echo ""
    for plugin in "${PLUGINS[@]}"; do
        echo "  claude plugin install $plugin"
    done
    echo ""
    read -rp "Install all plugins now? [y/N] " INSTALL_PLUGINS
    if [[ "$INSTALL_PLUGINS" =~ ^[Yy] ]]; then
        for plugin in "${PLUGINS[@]}"; do
            echo "  Installing $plugin..."
            if claude plugin install "$plugin" 2>/dev/null; then
                echo "    ✓ $plugin"
            else
                echo "    ✗ $plugin (install manually: claude plugin install $plugin)"
            fi
        done
    else
        echo "Skipped. Install manually when ready."
    fi
else
    echo "No marketplace plugins found in settings.json."
    echo "Install manually with: claude plugin install <name>"
fi

# ── Environment variables setup ──────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Environment Variables (REQUIRED)"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "Add these to your shell profile (~/.bashrc or ~/.zshrc):"
echo ""
echo "  # Claude Code secrets"
echo "  export GITHUB_PERSONAL_ACCESS_TOKEN=\"your-github-pat\""
echo "  export ATLASSIAN_API_TOKEN=\"your-atlassian-token\""
echo ""
echo "Claude Code reads these from the environment at runtime."
echo "The settings.json env block has placeholders that get"
echo "overridden when these shell vars are set."
echo ""

# ── Verify setup ─────────────────────────────────────────────────────
echo "═══════════════════════════════════════════════════════════"
echo "  Verification"
echo "═══════════════════════════════════════════════════════════"
echo ""

ISSUES=0

# Check skills
SKILL_COUNT=$(ls -1d "$CLAUDE_HOME/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
if [[ "$SKILL_COUNT" -gt 0 ]]; then
    echo "  ✓ Skills: $SKILL_COUNT installed"
else
    echo "  ✗ Skills: none found"
    ((ISSUES++))
fi

# Check settings
if [[ -f "$CLAUDE_HOME/settings.json" ]]; then
    echo "  ✓ settings.json exists"
    # Check for lingering Mac paths
    if grep -q "$MAC_HOME" "$CLAUDE_HOME/settings.json" 2>/dev/null; then
        echo "  ! settings.json still contains macOS paths — review manually"
        ((ISSUES++))
    fi
else
    echo "  ✗ settings.json missing"
    ((ISSUES++))
fi

# Check hooks
HOOK_COUNT=$(ls -1 "$CLAUDE_HOME/hooks"/*.js 2>/dev/null | wc -l | tr -d ' ')
if [[ "$HOOK_COUNT" -gt 0 ]]; then
    echo "  ✓ Hooks: $HOOK_COUNT JS files"
else
    echo "  - Hooks: none (optional)"
fi

echo ""
if [[ "$ISSUES" -eq 0 ]]; then
    echo "Setup complete! Run 'claude' to start using Claude Code."
else
    echo "Setup complete with $ISSUES warning(s) — review above."
fi
echo ""
echo "───────────────────────────────────────────────────────────"
echo "  Claude Code Backup System — linux-setup.sh"
echo "───────────────────────────────────────────────────────────"

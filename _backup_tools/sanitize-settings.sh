#!/usr/bin/env bash
# sanitize-settings.sh — Strip secrets from settings.json in the repo copy
# Called by claude-backup.sh after rsync, before git add.
# Replaces sensitive env values with placeholders so secrets never reach git.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SETTINGS="$REPO_ROOT/settings.json"

if [[ ! -f "$SETTINGS" ]]; then
    echo "[sanitize] No settings.json found — skipping"
    exit 0
fi

# ── Scrub secrets ────────────────────────────────────────────────────
# Add new keys to the jq filter below as needed.
# These match the env keys in your settings.json that contain tokens/secrets.
if command -v jq &>/dev/null; then
    TEMP=$(mktemp)
    if jq '
        if .env.GITHUB_PERSONAL_ACCESS_TOKEN then
            .env.GITHUB_PERSONAL_ACCESS_TOKEN = "__GITHUB_PAT_SET_VIA_ENV__"
        else . end |
        if .env.ATLASSIAN_API_TOKEN then
            .env.ATLASSIAN_API_TOKEN = "__ATLASSIAN_TOKEN_SET_VIA_ENV__"
        else . end
    ' "$SETTINGS" > "$TEMP"; then
        mv "$TEMP" "$SETTINGS"
        echo "[sanitize] Secrets replaced via jq in settings.json"
    else
        rm -f "$TEMP"
        echo "[sanitize] ERROR: jq processing failed" >&2
        exit 1
    fi
else
    # Fallback: sed-based replacement (works on both GNU and BSD sed)
    if sed --version 2>/dev/null | grep -q GNU; then
        SED_INPLACE=(sed -i)
    else
        SED_INPLACE=(sed -i '')
    fi

    "${SED_INPLACE[@]}" -E \
        's|("GITHUB_PERSONAL_ACCESS_TOKEN":[[:space:]]*").*(")|\\1__GITHUB_PAT_SET_VIA_ENV__\\2|' \
        "$SETTINGS"
    "${SED_INPLACE[@]}" -E \
        's|("ATLASSIAN_API_TOKEN":[[:space:]]*").*(")|\\1__ATLASSIAN_TOKEN_SET_VIA_ENV__\\2|' \
        "$SETTINGS"

    echo "[sanitize] Secrets replaced via sed in settings.json (jq not found)"
fi

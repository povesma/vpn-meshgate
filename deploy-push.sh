#!/usr/bin/env bash
# deploy-push.sh — Sync project files to the remote server via rsync.
#
# Exclusions come directly from .gitignore (no duplication).
# Protected config files (may be customized on the server) are detected
# and confirmed interactively before overwriting.
#
# Usage:
#   ./deploy-push.sh             — sync (prompts for changed protected files)
#   ./deploy-push.sh --force     — sync without prompts (overwrite all protected files)
#   ./deploy-push.sh --dry-run   — preview what would change (no prompts)

set -euo pipefail

# Files that may be customized on the server — prompt before overwriting.
# Paths are relative to project root (no leading slash).
#
# PROTECTED_GITIGNORED: not in git; must be force-included to reach the server.
#   Skipping means simply NOT force-including them (gitignore keeps them out).
# PROTECTED_TRACKED: in git; synced by default. Skipping adds --exclude.
#PROTECTED_GITIGNORED=(".env" "backend/.env")
#PROTECTED_TRACKED=("config.yaml" "docker-compose.yml")
PROTECTED_GITIGNORED=(".env")
PROTECTED_TRACKED=()

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Configuration (set in .env, never hardcode here) ──────────────────────────
# Add to your local .env (gitignored):
#   REMOTE_HOST=user@your-server.example.com
#   REMOTE_PATH=/home/user/technotongue
#   SSH_KEY=~/.ssh/tt_deploy              # optional, blank = use ssh-agent
REMOTE_HOST=""
REMOTE_PATH=""
SSH_KEY=""
[[ -f "$SCRIPT_DIR/.env" ]] && source "$SCRIPT_DIR/.env"
for _var in REMOTE_HOST REMOTE_PATH; do
    if [[ -z "${!_var}" ]]; then
        echo "✗ $_var not set. Add it to .env:  $_var=..."
        exit 1
    fi
done
# ──────────────────────────────────────────────────────────────────────────────

DRY_RUN=0
FORCE=0
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=1 ;;
        --force)   FORCE=1 ;;
    esac
done

if [[ -n "$SSH_KEY" ]]; then
    RSYNC_RSH="ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new"
else
    RSYNC_RSH="ssh -o StrictHostKeyChecking=accept-new"
fi

# Static exclusions — applied on every run
STATIC_FILTERS=(
    --filter=':- .gitignore'
    --exclude='/.git/'
    --exclude='/deploy-push.sh'
    --exclude='/deploy-start.sh'
    --exclude='/tasks/'
    --exclude='/tests/'
    --exclude='/backend/tests/'
    --exclude='/frontend/e2e/'
    --exclude='/diag_claude.py'
    --exclude='/run.sh'
    --exclude='/.claude/'
    --exclude='/.DS_Store'
    --exclude='/.idea/'
    --exclude='/.vscode/'
    --exclude='/*.swp'
    --exclude='/*.swo'
)

echo "▶ Syncing toremote host..."
# $REMOTE_HOST:$REMOTE_PATH ..."
[[ $DRY_RUN -eq 1 ]] && echo "  (dry-run — no files will be transferred)"

# ── Protected-file confirmation ───────────────────────────────────────────────
SKIP_GITIGNORED=()
SKIP_TRACKED=()

if [[ $DRY_RUN -eq 0 && $FORCE -eq 0 ]]; then
    # Build SSH command array matching the rsync transport settings
    SSH_CMD=(ssh -o StrictHostKeyChecking=accept-new)
    [[ -n "$SSH_KEY" ]] && SSH_CMD+=(-i "$SSH_KEY")

    ALL_PROTECTED=("${PROTECTED_GITIGNORED[@]}" "${PROTECTED_TRACKED[@]}")
    ASKED=0
    for f in "${ALL_PROTECTED[@]}"; do
        [[ ! -f "$SCRIPT_DIR/$f" ]] && continue
        # Only prompt if the file already exists on the remote host.
        # New files (no remote copy yet) are sent silently — no risk of overwrite.
        if "${SSH_CMD[@]}" "$REMOTE_HOST" "[ -f '$REMOTE_PATH/$f' ]" 2>/dev/null; then
            diff=$(rsync -ni -e "$RSYNC_RSH" \
                "$SCRIPT_DIR/$f" "$REMOTE_HOST:$REMOTE_PATH/$f" 2>&1) || true
            if [[ -n "$diff" ]]; then
                [[ $ASKED -eq 0 ]] && echo "" && ASKED=1
                echo "  ⚠  Protected file differs from remote: $f"
                printf "     Overwrite remote copy? [y/N] "
                read -r answer </dev/tty
                if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                    echo "     → Skipping $f"
                    for gi in "${PROTECTED_GITIGNORED[@]}"; do
                        [[ "$gi" == "$f" ]] && SKIP_GITIGNORED+=("$f") && break
                    done
                    for t in "${PROTECTED_TRACKED[@]}"; do
                        [[ "$t" == "$f" ]] && SKIP_TRACKED+=("$f") && break
                    done
                else
                    echo "     → Will overwrite $f"
                fi
            fi
        fi
    done
    [[ $ASKED -gt 0 ]] && echo ""
fi

# ── Build final filter list ───────────────────────────────────────────────────
FINAL_FILTERS=()

# Protect skipped files from --delete (must come before any exclude/include rules)
for f in "${SKIP_GITIGNORED[@]+"${SKIP_GITIGNORED[@]}"}"; do
    FINAL_FILTERS+=(--filter="P /$f")
done
for f in "${SKIP_TRACKED[@]+"${SKIP_TRACKED[@]}"}"; do
    FINAL_FILTERS+=(--filter="P /$f")
done

# Force-include gitignored protected files the user approved (or all in dry-run)
for f in "${PROTECTED_GITIGNORED[@]}"; do
    skip=0
    for s in "${SKIP_GITIGNORED[@]+"${SKIP_GITIGNORED[@]}"}"; do
        [[ "$s" == "$f" ]] && skip=1 && break
    done
    [[ $skip -eq 0 ]] && FINAL_FILTERS+=(--filter="+ /$f")
done

# Exclude tracked protected files the user declined
# Must come before ':- .gitignore' so the explicit exclude wins
for f in "${SKIP_TRACKED[@]+"${SKIP_TRACKED[@]}"}"; do
    FINAL_FILTERS+=(--exclude="/$f")
done

FINAL_FILTERS+=("${STATIC_FILTERS[@]}")

# ── Execute sync ──────────────────────────────────────────────────────────────
RSYNC_FLAGS=(-avz --delete -e "$RSYNC_RSH")
[[ $DRY_RUN -eq 1 ]] && RSYNC_FLAGS+=(--dry-run)

rsync "${RSYNC_FLAGS[@]}" \
    "${FINAL_FILTERS[@]}" \
    "$SCRIPT_DIR/" "$REMOTE_HOST:$REMOTE_PATH"

echo "✓ Sync complete."
[[ $DRY_RUN -eq 1 ]] && echo "  Run without --dry-run to actually transfer files."

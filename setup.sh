#!/bin/bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/Sheerabth/opencode-sync/main"
DATA_DIR="$HOME/.local/share/opencode"
SYNC_DIR="$DATA_DIR/.sync"

if [ "${OPENCODE_SYNC_REPO:-}" != "" ]; then
  REPO_URL="$OPENCODE_SYNC_REPO"
fi

for arg in "$@"; do
  case "$arg" in
    -f|--force) OC_SYNC_FORCE=1 ;;
  esac
done

if pgrep -x opencode >/dev/null && [ "${OC_SYNC_FORCE:-0}" -eq 0 ]; then
  echo "opencode is running - close it first (or use: setup.sh -f)"
  exit 1
fi

command -v python3 >/dev/null 2>&1 || { echo "python3 is required"; exit 1; }
command -v rclone >/dev/null 2>&1 || { echo "rclone is required (brew install rclone)"; exit 1; }

if ! command -v opencode >/dev/null 2>&1; then
  echo "warning: opencode not found in PATH. Install it before using oc-sync."
fi

mkdir -p "$SYNC_DIR"

curl -fsSL "$REPO_URL/oc-merge.py" -o "$SYNC_DIR/oc-merge.py"
curl -fsSL "$REPO_URL/oc-sync.sh" -o "$SYNC_DIR/oc-sync.sh"
chmod +x "$SYNC_DIR/oc-merge.py"

echo "$REPO_URL" > "$SYNC_DIR/repo-url"

if ! grep -q "source \"$SYNC_DIR/oc-sync.sh\"" "$HOME/.zshrc" 2>/dev/null; then
  echo "source \"$SYNC_DIR/oc-sync.sh\"" >> "$HOME/.zshrc"
  echo "Added oc-sync to ~/.zshrc"
else
  echo "oc-sync already in ~/.zshrc"
fi

if ! rclone listremotes | grep -q "^koofr:$"; then
  echo "Koofr remote not found. Running rclone config..."
  echo "  - Choose 'n' for new remote"
  echo "  - Name: koofr"
  echo "  - Storage: koofr (option 35)"
  echo "  - Provider: koofr (1)"
  echo "  - User: your Koofr email"
  echo "  - Password: Koofr app password (NOT login password)"
  rclone config
else
  echo "Koofr remote already configured"
fi

mkdir -p "$DATA_DIR"

echo "Ensuring Koofr sync folder exists..."
rclone mkdir koofr:opencode

echo ""
echo "Setup complete."
echo ""
echo "Next steps:"
echo "  1. Reload your shell: exec zsh"
echo "  2. Close opencode."
echo "  3. Run first sync: oc-sync --resync"

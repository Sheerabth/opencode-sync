#!/bin/bash
set -euo pipefail

REPO_URL="https://raw.githubusercontent.com/YOUR_GITHUB_USER/opencode-sync/main"
DATA_DIR="$HOME/.local/share/opencode"
SYNC_DIR="$DATA_DIR/.sync"

if [ "${OPENCODE_SYNC_REPO:-}" != "" ]; then
  REPO_URL="$OPENCODE_SYNC_REPO"
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

source "$SYNC_DIR/oc-sync.sh"

echo "Running initial oc-sync --resync..."
oc-sync --resync

echo ""
echo "Setup complete. Reload your shell or run:"
echo "  source $SYNC_DIR/oc-sync.sh"

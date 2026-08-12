oc-sync() {
  local dir=~/.local/share/opencode
  local syncdir="$dir/.sync"
  local remote="koofr:opencode"
  local force=0
  local resync=""

  for arg in "$@"; do
    case "$arg" in
      -f|--force) force=1 ;;
      --resync) resync="--resync" ;;
      --update) _oc_sync_update_scripts; return ;;
    esac
  done

  if pgrep -x opencode >/dev/null && [ "$force" -eq 0 ]; then
    echo "opencode is running - close it first (or use: oc-sync -f)"
    return 1
  fi

  mkdir -p "$syncdir"

  if [ ! -f "$dir/opencode.db" ]; then
    echo "Local opencode.db not found at $dir/opencode.db"
    return 1
  fi

  local backup="$dir/opencode.db.backup.$(date +%s)"
  cp "$dir/opencode.db" "$backup"
  echo "Backed up local DB to $backup"

  rclone bisync "$dir" "$remote" --create-empty-src-dirs \
    --exclude "auth.json" --exclude "log/**" --exclude "repos/**" \
    --exclude ".sync/**" --exclude "*.db" --exclude "*.db-wal" --exclude "*.db-shm" \
    $resync

  local tmpdir
  tmpdir=$(mktemp -d)

  if rclone lsf "$remote/opencode.db" >/dev/null 2>&1; then
    rclone copyto "$remote/opencode.db" "$tmpdir/opencode.db"
    python3 "$syncdir/oc-merge.py" "$dir/opencode.db" "$tmpdir/opencode.db"
  else
    echo "No remote opencode.db found; pushing local DB as initial remote copy."
  fi

  rclone copyto "$dir/opencode.db" "$remote/opencode.db"

  rm -rf "$tmpdir"
}

_oc_sync_update_scripts() {
  local syncdir=~/.local/share/opencode/.sync
  local repo_url
  repo_url=$(cat "$syncdir/repo-url" 2>/dev/null || true)
  if [ -z "$repo_url" ]; then
    echo "No repo-url configured. Set it in $syncdir/repo-url"
    return 1
  fi

  mkdir -p "$syncdir"
  curl -fsSL "$repo_url/oc-merge.py" -o "$syncdir/oc-merge.py"
  curl -fsSL "$repo_url/oc-sync.sh" -o "$syncdir/oc-sync.sh"
  chmod +x "$syncdir/oc-merge.py"
  echo "Scripts updated. Run: source $syncdir/oc-sync.sh"
}

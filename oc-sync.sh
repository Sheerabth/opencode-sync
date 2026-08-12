oc-sync() {
  local dir=~/.local/share/opencode
  local syncdir="$dir/.sync"
  local remote="koofr:opencode"
  local force=0
  local resync=""
  local yes=0

  for arg in "$@"; do
    case "$arg" in
      -f|--force) force=1 ;;
      --resync) resync="--resync" ;;
      -y|--yes) yes=1 ;;
      --update) _oc_sync_update_scripts; return ;;
    esac
  done

  if pgrep -x opencode >/dev/null && [ "$force" -eq 0 ]; then
    echo "opencode is running - close it first (or use: oc-sync -f)"
    return 1
  fi

  mkdir -p "$syncdir"
  rclone mkdir "$remote" 2>/dev/null || true

  if [ ! -f "$dir/opencode.db" ]; then
    echo "Local opencode.db not found at $dir/opencode.db"
    return 1
  fi

  local backup="$dir/opencode.db.backup.$(date +%s)"
  cp "$dir/opencode.db" "$backup"
  echo "Backed up local DB to $backup"

  local working="$dir/opencode.db.working"
  cp "$dir/opencode.db" "$working"

  echo "Normalizing local DB..."
  python3 "$syncdir/oc-merge.py" --normalize "$working"

  if ! rclone bisync "$dir" "$remote" --create-empty-src-dirs \
    --exclude "auth.json" --exclude "log/**" --exclude "repos/**" \
    --exclude ".sync/**" --exclude "*.db" --exclude "*.db-wal" --exclude "*.db-shm" \
    --exclude "*.backup.*" --exclude "*.working" \
    $resync; then
    echo "Bisync failed. Backup kept at $backup"
    rm -f "$working"
    return 1
  fi

  local tmpdir
  tmpdir=$(mktemp -d)

  if rclone lsf "$remote/opencode.db" >/dev/null 2>&1; then
    echo "Fetching and normalizing remote DB..."
    rclone copyto "$remote/opencode.db" "$tmpdir/opencode.db"
    python3 "$syncdir/oc-merge.py" --normalize "$tmpdir/opencode.db"

    echo ""
    echo "Preview of changes:"
    python3 "$syncdir/oc-merge.py" --dry-run "$working" "$tmpdir/opencode.db"
    echo ""

    if [ "$yes" -eq 0 ]; then
      printf "Apply merged DB to local? [Y/n] "
      read -r reply
      if [ "$reply" != "" ] && [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
        echo "Cancelled. Backup kept at $backup"
        rm -rf "$tmpdir" "$working"
        return 1
      fi
    fi

    python3 "$syncdir/oc-merge.py" "$working" "$tmpdir/opencode.db"
  else
    echo "No remote opencode.db found; this machine will seed the remote copy."
  fi

  local upload="$tmpdir/opencode.db.upload"
  cp "$working" "$upload"
  rclone copyto "$upload" "$remote/opencode.db"
  echo "Uploaded normalized DB to remote."

  echo "Denormalizing merged DB for local use..."
  python3 "$syncdir/oc-merge.py" --denormalize "$working"

  mv "$working" "$dir/opencode.db"
  echo "Local DB updated."

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

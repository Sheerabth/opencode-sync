oc-sync() {
  local dir=~/.local/share/opencode
  local syncdir="$dir/.sync"
  local remote="koofr:opencode"
  local force=0
  local yes=0

  for arg in "$@"; do
    case "$arg" in
      -f|--force) force=1 ;;
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

  local working="$dir/opencode.db.working"
  cp "$dir/opencode.db" "$working"

  python3 "$syncdir/oc-merge.py" --normalize "$working" >/dev/null

  local resync=""
  if ! rclone lsf "$remote/opencode.db" >/dev/null 2>&1; then
    resync="--resync"
  fi

  if ! rclone bisync "$dir" "$remote" --create-empty-src-dirs \
    --exclude "auth.json" --exclude "log/**" --exclude "repos/**" \
    --exclude ".sync/**" --exclude "*.db" --exclude "*.db-wal" --exclude "*.db-shm" \
    --exclude "*.backup.*" --exclude "*.working" \
    $resync >/dev/null 2>&1; then
    echo "Retrying bisync with --resync..."
    rclone bisync "$dir" "$remote" --create-empty-src-dirs \
      --exclude "auth.json" --exclude "log/**" --exclude "repos/**" \
      --exclude ".sync/**" --exclude "*.db" --exclude "*.db-wal" --exclude "*.db-shm" \
      --exclude "*.backup.*" --exclude "*.working" \
      --resync >/dev/null 2>&1 || {
        echo "Bisync failed. Backup kept at $backup"
        rm -f "$working"
        return 1
      }
  fi

  local tmpdir
  tmpdir=$(mktemp -d)

  local remote_has_db=0
  if rclone lsf "$remote/opencode.db" >/dev/null 2>&1; then
    remote_has_db=1
    rclone copyto "$remote/opencode.db" "$tmpdir/opencode.db"
    python3 "$syncdir/oc-merge.py" --normalize "$tmpdir/opencode.db" >/dev/null

    local to_copy
    to_copy=$(python3 "$syncdir/oc-merge.py" --dry-run "$working" "$tmpdir/opencode.db" | grep -c '^  ses' || true)

    if [ "$to_copy" -gt 0 ]; then
      echo "Remote has $to_copy newer session(s)."
      if [ "$yes" -eq 0 ]; then
        printf "Apply to local? [Y/n] "
        read -r reply
        if [ "$reply" != "" ] && [ "$reply" != "y" ] && [ "$reply" != "Y" ]; then
          echo "Cancelled. Backup kept at $backup"
          rm -rf "$tmpdir" "$working"
          return 1
        fi
      fi
    fi

    python3 "$syncdir/oc-merge.py" "$working" "$tmpdir/opencode.db" >/dev/null
  fi

  local upload="$tmpdir/opencode.db.upload"
  cp "$working" "$upload"
  rclone copyto "$upload" "$remote/opencode.db"

  python3 "$syncdir/oc-merge.py" --denormalize "$working" >/dev/null

  mv "$working" "$dir/opencode.db"

  rm -rf "$tmpdir"

  if [ "$remote_has_db" -eq 0 ]; then
    echo "Seeded remote DB."
  elif [ "$to_copy" -gt 0 ]; then
    echo "Synced. Merged $to_copy remote session(s)."
  else
    echo "Synced. No remote changes."
  fi
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

# opencode-sync

Session-level sync for OpenCode across machines, using Koofr + rclone.

## What it does

OpenCode stores all sessions in a single SQLite DB (`~/.local/share/opencode/opencode.db`).
Plain `rclone bisync` is file-level last-writer-wins, so syncing after both
machines created sessions loses data.

This repo adds `oc-merge.py`: a script that merges two `opencode.db` files at
session level. For every session id, the version with the latest
`session.time_updated` is kept.

## Files

- `setup.sh` — one-command installer/bootstrap
- `oc-sync.sh` — `oc-sync` shell function (backs up, syncs files, merges DB, pushes DB)
- `oc-merge.py` — SQLite session-level merge logic

## Setup

1. Push this repo to GitHub.
2. Edit `setup.sh` and set `REPO_URL` to your repo's raw `main` branch URL.
3. On each machine:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/opencode-sync/main/setup.sh | bash
   ```
   On a new machine, **run this before launching opencode** so it pulls the DB
   from Koofr instead of creating an empty one.

## Usage

```bash
oc-sync          # normal sync
oc-sync -f       # force even if opencode appears running
oc-sync --resync # recover stale bisync state
oc-sync --update # re-download scripts from GitHub
```

## Caveats

- Close opencode before syncing. WAL/shm files are process-specific.
- Same session edited on both machines: later `time_updated` wins the whole
  session; messages within a session are not merged.
- Project/workspace paths may be machine-specific; missing ones are copied but
  existing ones are never overwritten.
- `auth.json` is never synced.

# opencode-sync

Session-level sync for OpenCode across machines, using Koofr + rclone.

## What it does

OpenCode stores all sessions in a single SQLite DB (`~/.local/share/opencode/opencode.db`).
Plain `rclone bisync` is file-level last-writer-wins, so syncing after both
machines created sessions loses data.

This repo adds `oc-merge.py`: a script that merges two `opencode.db` files at
session level. For every session id, the version with the latest
`session.time_updated` is kept.

It also normalizes home-directory paths (`/Users/sheerabth`, `/home/otheruser`)
to a placeholder before uploading, so the remote DB stores machine-independent
paths. Each machine denormalizes to its own home dir on download.

## Files

- `setup.sh` — one-command installer/bootstrap
- `oc-sync.sh` — `oc-sync` shell function (backs up, syncs files, merges DB, pushes DB)
- `oc-merge.py` — SQLite session-level merge logic + path normalization

## Setup

1. Push this repo to GitHub.
2. On each machine:
   ```bash
   curl -fsSL https://raw.githubusercontent.com/Sheerabth/opencode-sync/main/setup.sh | bash
   ```
   On a new machine, **run this before launching opencode** so it pulls the DB
   from Koofr instead of creating an empty one.

## Usage

```bash
oc-sync          # normal sync (interactive confirmation)
oc-sync -y       # skip confirmation
oc-sync -f       # force even if opencode appears running
oc-sync --resync # recover stale bisync state
oc-sync --update # re-download scripts from GitHub
```

## How the sync works

1. Backs up local `opencode.db`.
2. Clones it to a working copy and replaces local home-dir paths with `__OC_HOME__`.
3. Syncs non-DB files with `rclone bisync`.
4. Fetches remote DB and normalizes it the same way.
5. Merges remote sessions into the working copy (session-level, latest wins).
6. Uploads the normalized merged copy to Koofr.
7. Denormalizes the working copy to the local home dir.
8. Shows a preview and asks for confirmation before overwriting the real local DB.

## Caveats

- Close opencode before syncing. WAL/shm files are process-specific.
- Same session edited on both machines: later `time_updated` wins the whole
  session; messages within a session are not merged.
- Project/workspace paths may be machine-specific; missing ones are copied but
  existing ones are never overwritten.
- `auth.json` is never synced.

#!/usr/bin/env python3
import argparse
import os
import sqlite3
import sys

HOME_REF = "__OC_HOME__"
HOME_PREFIXES = ("/Users/", "/home/")

SESSION_SUBTREE = [
    ("session_message", "session_id"),
    ("message", "session_id"),
    ("session_context_epoch", "session_id"),
    ("session_input", "session_id"),
    ("session_share", "session_id"),
    ("todo", "session_id"),
    ("event_sequence", "aggregate_id"),
]

PATH_COLUMNS = [
    ("session", "directory"),
    ("session", "path"),
    ("project", "worktree"),
]


def detect_home_dir(cur, absolute=True):
    paths = []
    for table, col in PATH_COLUMNS:
        try:
            cur.execute(f"SELECT {col} FROM {table} WHERE {col} IS NOT NULL AND {col} != ''")
            paths.extend(row[0] for row in cur.fetchall())
        except sqlite3.OperationalError:
            pass

    prefixes = {}
    for p in paths:
        if absolute:
            checks = ("/Users/", "/home/")
            offset = 0
        else:
            checks = ("Users/", "home/")
            offset = -1

        for prefix in checks:
            if p.startswith(prefix):
                parts = p.split("/")
                take = 3 if absolute else 2
                if len(parts) >= take:
                    home = "/".join(parts[:take])
                    prefixes[home] = prefixes.get(home, 0) + 1
                break

    if not prefixes:
        return None
    return max(prefixes.items(), key=lambda x: x[1])[0]


def rewrite_paths(cur, old_prefix, new_prefix):
    changed = 0
    for table, col in PATH_COLUMNS:
        try:
            cur.execute(f"SELECT rowid, {col} FROM {table} WHERE {col} IS NOT NULL AND {col} != ''")
            for rowid, val in cur.fetchall():
                if val.startswith(old_prefix):
                    new_val = new_prefix + val[len(old_prefix):]
                    cur.execute(f"UPDATE {table} SET {col} = ? WHERE rowid = ?", (new_val, rowid))
                    changed += 1
        except sqlite3.OperationalError:
            pass
    return changed


def normalize_db(path, ref=HOME_REF):
    conn = sqlite3.connect(path)
    cur = conn.cursor()
    changed = False

    abs_home = detect_home_dir(cur, absolute=True)
    if abs_home:
        rewrite_paths(cur, abs_home, ref)
        print(f"Normalized {abs_home} -> {ref}")
        changed = True

    rel_home = detect_home_dir(cur, absolute=False)
    if rel_home:
        rewrite_paths(cur, rel_home, ref)
        print(f"Normalized {rel_home} -> {ref}")
        changed = True

    if changed:
        conn.commit()
    else:
        print("No home dir prefix found; nothing to normalize")
    conn.close()


def denormalize_db(path, home_dir=None):
    home_dir = home_dir or os.path.expanduser("~")
    rel_home = home_dir.lstrip("/")
    conn = sqlite3.connect(path)
    cur = conn.cursor()

    changed = 0
    for table, col in (("session", "directory"), ("project", "worktree")):
        try:
            cur.execute(f"SELECT rowid, {col} FROM {table} WHERE INSTR({col}, ?) > 0", (HOME_REF,))
            for rowid, val in cur.fetchall():
                new_val = val.replace(HOME_REF, home_dir)
                cur.execute(f"UPDATE {table} SET {col} = ? WHERE rowid = ?", (new_val, rowid))
                changed += 1
        except sqlite3.OperationalError:
            pass

    try:
        cur.execute("SELECT rowid, path FROM session WHERE INSTR(path, ?) > 0", (HOME_REF,))
        for rowid, val in cur.fetchall():
            new_val = val.replace(HOME_REF, rel_home)
            cur.execute("UPDATE session SET path = ? WHERE rowid = ?", (new_val, rowid))
            changed += 1
    except sqlite3.OperationalError:
        pass

    conn.commit()
    print(f"Denormalized {HOME_REF} -> {home_dir} ({changed} paths)")
    conn.close()


def get_time_updated(cur, session_id):
    cur.execute("SELECT time_updated FROM session WHERE id = ?", (session_id,))
    row = cur.fetchone()
    return row[0] if row else 0


def table_rows(cur, table, where_col, where_val):
    cur.execute(f"SELECT * FROM {table} WHERE {where_col} = ?", (where_val,))
    return cur.fetchall()


def insert_rows(cur, table, rows):
    if not rows:
        return 0
    cur.execute(f"PRAGMA table_info({table})")
    cols = [row[1] for row in cur.fetchall()]
    placeholders = ", ".join("?" for _ in cols)
    sql = f"INSERT OR REPLACE INTO {table} ({', '.join(cols)}) VALUES ({placeholders})"
    cur.executemany(sql, rows)
    return len(rows)


def delete_session_subtree(cur, session_id):
    cur.execute("DELETE FROM event WHERE aggregate_id = ?", (session_id,))
    cur.execute("DELETE FROM part WHERE session_id = ?", (session_id,))
    for table, col in SESSION_SUBTREE:
        cur.execute(f"DELETE FROM {table} WHERE {col} = ?", (session_id,))
    cur.execute("DELETE FROM session WHERE id = ?", (session_id,))


def copy_session_subtree(src_cur, dst_cur, session_id):
    rows = table_rows(src_cur, "session", "id", session_id)
    insert_rows(dst_cur, "session", rows)

    for table, col in SESSION_SUBTREE:
        rows = table_rows(src_cur, table, col, session_id)
        insert_rows(dst_cur, table, rows)

    rows = table_rows(src_cur, "part", "session_id", session_id)
    insert_rows(dst_cur, "part", rows)

    rows = table_rows(src_cur, "event", "aggregate_id", session_id)
    insert_rows(dst_cur, "event", rows)


def existing_ids(cur, table, col):
    cur.execute(f"SELECT {col} FROM {table}")
    return {row[0] for row in cur.fetchall()}


def copy_missing_project(src_cur, dst_cur, project_id):
    if project_id in existing_ids(dst_cur, "project", "id"):
        return
    rows = table_rows(src_cur, "project", "id", project_id)
    insert_rows(dst_cur, "project", rows)
    rows = table_rows(src_cur, "project_directory", "project_id", project_id)
    insert_rows(dst_cur, "project_directory", rows)


def copy_missing_workspace(src_cur, dst_cur, workspace_id):
    if not workspace_id or workspace_id in existing_ids(dst_cur, "workspace", "id"):
        return
    src_cur.execute("SELECT project_id FROM workspace WHERE id = ?", (workspace_id,))
    row = src_cur.fetchone()
    if row and row[0]:
        copy_missing_project(src_cur, dst_cur, row[0])
    rows = table_rows(src_cur, "workspace", "id", workspace_id)
    insert_rows(dst_cur, "workspace", rows)


def merge(local_path, remote_path, dry_run=False):
    local = sqlite3.connect(local_path)
    remote = sqlite3.connect(remote_path)
    local_cur = local.cursor()
    remote_cur = remote.cursor()

    local_cur.execute("PRAGMA foreign_keys = OFF")

    local_ids = existing_ids(local_cur, "session", "id")
    remote_ids = existing_ids(remote_cur, "session", "id")
    all_ids = local_ids | remote_ids

    to_copy = []

    for session_id in sorted(all_ids):
        local_updated = get_time_updated(local_cur, session_id)
        remote_updated = get_time_updated(remote_cur, session_id)
        if remote_updated > local_updated:
            to_copy.append(session_id)

    if dry_run:
        remote.close()
        local.close()
        return to_copy

    copied = 0
    for session_id in to_copy:
        remote_cur.execute(
            "SELECT project_id, workspace_id FROM session WHERE id = ?",
            (session_id,),
        )
        row = remote_cur.fetchone()
        if row:
            project_id, workspace_id = row
            if project_id:
                copy_missing_project(remote_cur, local_cur, project_id)
            copy_missing_workspace(remote_cur, local_cur, workspace_id)

        delete_session_subtree(local_cur, session_id)
        copy_session_subtree(remote_cur, local_cur, session_id)
        copied += 1

    local.commit()
    local_cur.execute("PRAGMA foreign_keys = ON")
    local.close()
    remote.close()

    return copied


def main():
    parser = argparse.ArgumentParser(description="Merge opencode.db files at session level.")
    parser.add_argument("local")
    parser.add_argument("remote", nargs="?")
    parser.add_argument("--normalize", action="store_true", help="Replace home dir with ref")
    parser.add_argument("--denormalize", action="store_true", help="Replace ref with home dir")
    parser.add_argument("--ref", default=HOME_REF, help="Home dir placeholder ref")
    parser.add_argument("--home-dir", default=None, help="Local home dir for denormalize")
    parser.add_argument("--dry-run", action="store_true", help="Show sessions that would be copied")
    args = parser.parse_args()

    if args.normalize:
        normalize_db(args.local, args.ref)
        return

    if args.denormalize:
        denormalize_db(args.local, args.home_dir)
        return

    if not args.remote:
        parser.error("remote db is required for merge")

    to_copy = merge(args.local, args.remote, dry_run=True)
    print(f"Would copy {len(to_copy)} session(s) from remote")
    for sid in to_copy:
        print(f"  {sid}")

    if args.dry_run:
        return

    copied = merge(args.local, args.remote, dry_run=False)
    kept = len(existing_ids(sqlite3.connect(args.local).cursor(), "session", "id")) - copied
    print(f"Merged sessions: {copied} copied from remote, {kept} kept local")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
import sqlite3
import sys

SESSION_SUBTREE = [
    ("session_message", "session_id"),
    ("message", "session_id"),
    ("session_context_epoch", "session_id"),
    ("session_input", "session_id"),
    ("session_share", "session_id"),
    ("todo", "session_id"),
    ("event_sequence", "aggregate_id"),
]


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


def merge(local_path, remote_path):
    local = sqlite3.connect(local_path)
    remote = sqlite3.connect(remote_path)
    local_cur = local.cursor()
    remote_cur = remote.cursor()

    local_cur.execute("PRAGMA foreign_keys = OFF")

    local_ids = existing_ids(local_cur, "session", "id")
    remote_ids = existing_ids(remote_cur, "session", "id")
    all_ids = local_ids | remote_ids

    copied = 0
    kept = 0

    for session_id in sorted(all_ids):
        local_updated = get_time_updated(local_cur, session_id)
        remote_updated = get_time_updated(remote_cur, session_id)

        if remote_updated > local_updated:
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
        else:
            kept += 1

    local.commit()
    local_cur.execute("PRAGMA foreign_keys = ON")
    local.close()
    remote.close()

    print(f"Merged sessions: {copied} copied from remote, {kept} kept local")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print("Usage: oc-merge.py <local.db> <remote.db>")
        sys.exit(1)
    merge(sys.argv[1], sys.argv[2])

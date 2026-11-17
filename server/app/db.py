"""SQLite：文件索引 + 播放进度 + 对话记录。

为什么用 trigram：中文文件名没有空格，unicode61 分词会把「实时测试文件」当成
一整串；trigram 可以按 3 字滑窗命中「试文件」这类子串。
不足 3 字的查询 trigram 命中不了，退回 LIKE（家庭规模的文件量够用）。
"""

from __future__ import annotations

import json
import os
import sqlite3
import threading
import time

from .config import CFG

_local = threading.local()

SCHEMA = """
CREATE TABLE IF NOT EXISTS files (
  id      INTEGER PRIMARY KEY,
  source  TEXT NOT NULL,
  path    TEXT NOT NULL,
  name    TEXT NOT NULL,
  parent  TEXT NOT NULL,
  is_dir  INTEGER NOT NULL DEFAULT 0,
  kind    TEXT NOT NULL DEFAULT 'file',
  size    INTEGER NOT NULL DEFAULT 0,
  mtime   REAL NOT NULL DEFAULT 0,
  gen     INTEGER NOT NULL DEFAULT 0,
  UNIQUE(source, path)
);
CREATE INDEX IF NOT EXISTS idx_files_parent ON files(source, parent);
CREATE INDEX IF NOT EXISTS idx_files_gen ON files(gen);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT);

CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(
  name, path, content='files', content_rowid='id', tokenize='trigram'
);
CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
  INSERT INTO files_fts(rowid, name, path) VALUES (new.id, new.name, new.path);
END;
CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
  INSERT INTO files_fts(files_fts, rowid, name, path) VALUES('delete', old.id, old.name, old.path);
END;
CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
  INSERT INTO files_fts(files_fts, rowid, name, path) VALUES('delete', old.id, old.name, old.path);
  INSERT INTO files_fts(rowid, name, path) VALUES (new.id, new.name, new.path);
END;

CREATE TABLE IF NOT EXISTS play (
  path    TEXT PRIMARY KEY,
  name    TEXT,
  pos     REAL DEFAULT 0,
  dur     REAL DEFAULT 0,
  updated REAL DEFAULT 0
);

-- 对话：一轮问答。parent 指向上一轮，用来重建上下文
CREATE TABLE IF NOT EXISTS conv (
  id      TEXT PRIMARY KEY,
  parent  TEXT,
  ts      REAL NOT NULL,
  model   TEXT,
  user    TEXT,
  text    TEXT,
  think   TEXT,
  status  TEXT DEFAULT 'running'
);

-- 对话记录（多端同步的那本账）
CREATE TABLE IF NOT EXISTS msg (
  id      TEXT PRIMARY KEY,
  ts      REAL NOT NULL,
  role    TEXT NOT NULL,
  text    TEXT,
  think   TEXT,
  steps   TEXT,
  rid     TEXT,
  status  TEXT
);
CREATE TABLE IF NOT EXISTS op (
  seq   INTEGER PRIMARY KEY AUTOINCREMENT,
  kind  TEXT NOT NULL,
  mid   TEXT
);
"""


def conn() -> sqlite3.Connection:
    c = getattr(_local, "c", None)
    if c is None:
        os.makedirs(os.path.dirname(CFG.db_path) or ".", exist_ok=True)
        c = sqlite3.connect(CFG.db_path, timeout=15, check_same_thread=False)
        c.row_factory = sqlite3.Row
        c.execute("PRAGMA journal_mode=WAL")
        c.execute("PRAGMA synchronous=NORMAL")
        c.executescript(SCHEMA)
        _local.c = c
    return c


def get_meta(k: str, default: str = "") -> str:
    row = conn().execute("SELECT v FROM meta WHERE k=?", (k,)).fetchone()
    return row["v"] if row else default


def set_meta(k: str, v: str) -> None:
    c = conn()
    c.execute("INSERT INTO meta(k, v) VALUES(?, ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v", (k, v))
    c.commit()


def counts() -> dict:
    c = conn()
    files = c.execute("SELECT COUNT(*) n FROM files WHERE is_dir=0").fetchone()["n"]
    dirs = c.execute("SELECT COUNT(*) n FROM files WHERE is_dir=1").fetchone()["n"]
    return {"files": files, "dirs": dirs}


# ---------------- 索引 ----------------

def upsert_many(rows: list[tuple]) -> None:
    """rows: (source, path, name, parent, is_dir, kind, size, mtime, gen)"""
    if not rows:
        return
    c = conn()
    c.executemany(
        """INSERT INTO files(source, path, name, parent, is_dir, kind, size, mtime, gen)
           VALUES(?,?,?,?,?,?,?,?,?)
           ON CONFLICT(source, path) DO UPDATE SET
             name=excluded.name, parent=excluded.parent, is_dir=excluded.is_dir,
             kind=excluded.kind, size=excluded.size, mtime=excluded.mtime, gen=excluded.gen""",
        rows,
    )
    c.commit()


def delete_path(source: str, path: str) -> None:
    c = conn()
    c.execute("DELETE FROM files WHERE source=? AND (path=? OR path LIKE ?)",
              (source, path, path.rstrip("/") + "/%"))
    c.commit()


def drop_stale(source: str, gen: int) -> int:
    c = conn()
    cur = c.execute("DELETE FROM files WHERE source=? AND gen<>?", (source, gen))
    c.commit()
    return cur.rowcount


def search(q: str, source: str | None = None, kind: str | None = None,
           limit: int = 50, offset: int = 0) -> tuple[int, list[dict]]:
    c = conn()
    q = (q or "").strip()
    where, args = [], []
    if source:
        where.append("f.source=?")
        args.append(source)
    if kind:
        where.append("f.kind=?")
        args.append(kind)
    order = "ORDER BY f.is_dir DESC, f.mtime DESC"

    if not q:
        sql_where = (" WHERE " + " AND ".join(where)) if where else ""
        total = c.execute(f"SELECT COUNT(*) n FROM files f{sql_where}", args).fetchone()["n"]
        rows = c.execute(
            f"SELECT f.* FROM files f{sql_where} {order} LIMIT ? OFFSET ?",
            [*args, limit, offset]).fetchall()
        return total, [dict(r) for r in rows]

    if len(q) >= 3:
        match = '"' + q.replace('"', '""') + '"'
        sql_where = ["files_fts MATCH ?", *where]
        args2 = [match, *args]
        total = c.execute(
            "SELECT COUNT(*) n FROM files_fts JOIN files f ON f.id=files_fts.rowid"
            f" WHERE {' AND '.join(sql_where)}", args2).fetchone()["n"]
        rows = c.execute(
            "SELECT f.* FROM files_fts JOIN files f ON f.id=files_fts.rowid"
            f" WHERE {' AND '.join(sql_where)} {order} LIMIT ? OFFSET ?",
            [*args2, limit, offset]).fetchall()
        return total, [dict(r) for r in rows]

    like = f"%{q}%"
    where_l = [*where, "(f.name LIKE ? OR f.path LIKE ?)"]
    args3 = [*args, like, like]
    total = c.execute(f"SELECT COUNT(*) n FROM files f WHERE {' AND '.join(where_l)}",
                      args3).fetchone()["n"]
    rows = c.execute(f"SELECT f.* FROM files f WHERE {' AND '.join(where_l)} {order} LIMIT ? OFFSET ?",
                     [*args3, limit, offset]).fetchall()
    return total, [dict(r) for r in rows]


def stats() -> dict:
    n = counts()
    return {**n, "last_scan": get_meta("last_scan"),
            "scanning": get_meta("scanning", "0") == "1",
            "db_bytes": os.path.getsize(CFG.db_path) if os.path.exists(CFG.db_path) else 0,
            "ts": time.time()}


# ---------------- 对话：一轮问答 ----------------

def conv_new(cid: str, parent: str | None, model: str, user: str) -> None:
    c = conn()
    c.execute("INSERT OR REPLACE INTO conv(id, parent, ts, model, user, text, think, status)"
              " VALUES(?,?,?,?,?,'','','running')",
              (cid, parent, time.time(), model, user))
    c.commit()


def conv_update(cid: str, text: str, think: str, status: str) -> None:
    c = conn()
    c.execute("UPDATE conv SET text=?, think=?, status=? WHERE id=?", (text, think, status, cid))
    c.commit()


def conv_get(cid: str) -> dict | None:
    row = conn().execute("SELECT * FROM conv WHERE id=?", (cid,)).fetchone()
    return dict(row) if row else None


def conv_chain(cid: str | None, limit: int = 12) -> list[dict]:
    """从 cid 往上爬，返回时间正序的 [{role, content}]（不含 system）。"""
    out: list[dict] = []
    seen: set[str] = set()
    cur = cid
    while cur and cur not in seen and len(out) < limit * 2:
        seen.add(cur)
        row = conv_get(cur)
        if not row:
            break
        if row.get("text"):
            out.append({"role": "assistant", "content": row["text"]})
        if row.get("user"):
            out.append({"role": "user", "content": row["user"]})
        cur = row.get("parent")
    out.reverse()
    return out


def conv_recent(limit: int = 20) -> list[dict]:
    rows = conn().execute(
        "SELECT * FROM conv WHERE text<>'' ORDER BY ts DESC LIMIT ?", (limit,)
    ).fetchall()
    return [dict(r) for r in rows]


# ---------------- 对话记录（多端同步） ----------------

def _msg_row(m: dict) -> tuple:
    return (
        str(m.get("id") or ""),
        float(m.get("ts") or time.time()),
        m.get("role") or "assistant",
        m.get("text") or "",
        m.get("think") or "",
        json.dumps(m.get("steps") or [], ensure_ascii=False),
        m.get("rid") or "",
        m.get("status") or "done",
    )


def log_push(msgs: list[dict]) -> int:
    """写一批消息（按 id 幂等 upsert），返回新的游标。"""
    c = conn()
    for m in msgs:
        mid = str(m.get("id") or "").strip()
        if not mid:
            continue
        exists = c.execute("SELECT 1 FROM msg WHERE id=?", (mid,)).fetchone()
        if not exists:
            # 服务端兜底去重：同一个 (ts, role, text) 已经在了就不重复插
            dup = c.execute("SELECT 1 FROM msg WHERE ts=? AND role=? AND text=?",
                            (float(m.get("ts") or 0), m.get("role") or "", m.get("text") or "")).fetchone()
            if dup:
                continue
        c.execute(
            """INSERT INTO msg(id, ts, role, text, think, steps, rid, status)
               VALUES(?,?,?,?,?,?,?,?)
               ON CONFLICT(id) DO UPDATE SET
                 text=excluded.text, think=excluded.think, steps=excluded.steps,
                 rid=excluded.rid, status=excluded.status""",
            _msg_row({**m, "id": mid}),
        )
        c.execute("INSERT INTO op(kind, mid) VALUES('add', ?)", (mid,))
    c.commit()
    return log_cursor()


def log_cursor() -> int:
    row = conn().execute("SELECT COALESCE(MAX(seq), 0) n FROM op").fetchone()
    return int(row["n"] or 0)


def log_since(since: int) -> tuple[list[dict], int]:
    c = conn()
    rows = c.execute(
        "SELECT op.seq, op.kind, op.mid FROM op WHERE op.seq>? ORDER BY op.seq LIMIT 500",
        (int(since),),
    ).fetchall()
    ops: list[dict] = []
    for r in rows:
        kind = r["kind"]
        if kind in ("add", "upd"):
            m = c.execute("SELECT * FROM msg WHERE id=?", (r["mid"],)).fetchone()
            if not m:
                continue
            try:
                steps = json.loads(m["steps"] or "[]")
            except ValueError:
                steps = []
            ops.append({"seq": r["seq"], "kind": kind, "id": m["id"], "msg": {
                "id": m["id"], "ts": int(m["ts"]), "role": m["role"], "text": m["text"] or "",
                "think": m["think"] or "", "steps": steps, "rid": m["rid"] or "",
                "status": m["status"] or "done",
            }})
        else:
            ops.append({"seq": r["seq"], "kind": kind, "id": r["mid"]})
    return ops, log_cursor()


def log_clear() -> int:
    c = conn()
    c.execute("DELETE FROM msg")
    c.execute("INSERT INTO op(kind, mid) VALUES('clear', '')")
    c.commit()
    return log_cursor()


def log_del(ids: list[str]) -> int:
    c = conn()
    n = 0
    for mid in ids:
        cur = c.execute("DELETE FROM msg WHERE id=?", (mid,))
        n += cur.rowcount
        c.execute("INSERT INTO op(kind, mid) VALUES('del', ?)", (mid,))
    c.commit()
    return n

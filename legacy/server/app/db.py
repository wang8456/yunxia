"""SQLite：文件名索引（不依赖 dufs，dufs 的 ?search 是坏的）。

为什么用 trigram：中文文件名没有空格，unicode61 分词会把「实时测试文件」当成
一整串；trigram 可以按 3 字滑窗命中「试文件」这类子串。
不足 3 字的查询 trigram 命中不了，退回 LIKE（共享盘规模小，够用）。
"""

from __future__ import annotations

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
CREATE TABLE IF NOT EXISTS play (
  path    TEXT PRIMARY KEY,
  name    TEXT,
  pos     REAL DEFAULT 0,
  dur     REAL DEFAULT 0,
  updated REAL DEFAULT 0
);
CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
  INSERT INTO files_fts(files_fts, rowid, name, path) VALUES('delete', old.id, old.name, old.path);
  INSERT INTO files_fts(rowid, name, path) VALUES (new.id, new.name, new.path);
END;
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
        # FTS5 短语查询：把整串当一个短语，避免多词被 OR 掉
        match = '"' + q.replace('"', '""') + '"'
        sql_where = ["files_fts MATCH ?", *where]
        args2 = [match, *args]
        total = c.execute(
            f"SELECT COUNT(*) n FROM files_fts JOIN files f ON f.id=files_fts.rowid"
            f" WHERE {' AND '.join(sql_where)}", args2).fetchone()["n"]
        rows = c.execute(
            f"SELECT f.* FROM files_fts JOIN files f ON f.id=files_fts.rowid"
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
    return {**n, "last_scan": get_meta("last_scan"), "scanning": get_meta("scanning", "0") == "1",
            "db_bytes": os.path.getsize(CFG.db_path) if os.path.exists(CFG.db_path) else 0,
            "ts": time.time()}

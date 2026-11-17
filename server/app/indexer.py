"""建索引：把各个来源的文件名收进 SQLite，供搜索用。

* 本地源：``os.walk`` 全量扫一遍，快（几十万文件也就几秒）。
* 远端源（dufs / WebDAV）：递归调 ``adapter.list``，慢，所以有预算上限
  （每次最多 8000 项 / 60 秒），超了就下轮再继续。家庭规模够用。

全量扫描用「代（gen）」标脏：扫完把 gen 不等于本次的删掉，
这样中途新增/删除的文件不会留下幽灵条目。
"""

from __future__ import annotations

import logging
import posixpath
import threading
import time

from . import db
from .adapters import get_adapter
from .config import CFG
from .models import kind_of

log = logging.getLogger("yunxia.index")

_lock = threading.Lock()
_scanning = False

REMOTE_BUDGET = 8000
REMOTE_SECONDS = 60.0


def _flush(buf: list[tuple]) -> None:
    if buf:
        db.upsert_many(list(buf))
        buf.clear()


def _walk_local(source_id: str, root: str, gen: int, batch: int = 2000) -> int:
    import os

    buf: list[tuple] = []
    n = 0
    for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "/" if rel_dir == "." else "/" + rel_dir.replace(os.sep, "/")
        for d in dirnames:
            buf.append((source_id, posixpath.join(rel_dir, d), d, rel_dir, 1, "dir", 0, 0.0, gen))
            n += 1
        for f in filenames:
            if f.startswith(".") or f.endswith(".part"):
                continue
            try:
                st = os.stat(os.path.join(dirpath, f))
            except OSError:
                continue
            buf.append((source_id, posixpath.join(rel_dir, f), f, rel_dir, 0,
                        kind_of(f, False), st.st_size, st.st_mtime, gen))
            n += 1
        if len(buf) >= batch:
            _flush(buf)
    _flush(buf)
    return n


def _walk_remote(source_id: str, gen: int) -> int:
    ad = get_adapter(source_id)
    buf: list[tuple] = []
    n = 0
    t0 = time.time()
    stack = ["/"]
    seen: set[str] = set()
    while stack:
        if n >= REMOTE_BUDGET or time.time() - t0 > REMOTE_SECONDS:
            log.info("远端索引 %s 达到预算，本轮扫描 %d 项", source_id, n)
            break
        path = stack.pop()
        if path in seen:
            continue
        seen.add(path)
        try:
            entries, _ = ad.list(path)
        except Exception as exc:  # noqa: BLE001
            log.warning("远端索引 %s %s 失败: %s", source_id, path, exc)
            continue
        for e in entries:
            buf.append((source_id, e.path, e.name, posixpath.dirname(e.path) or "/",
                        int(e.is_dir), e.kind, e.size, e.mtime, gen))
            n += 1
            if e.is_dir:
                stack.append(e.path)
        if len(buf) >= 500:
            _flush(buf)
    _flush(buf)
    return n


def scan_source(source_id: str) -> dict:
    """同步全量扫描一个源，返回统计。"""
    src = CFG.source(source_id)
    gen = int(time.time() * 1000)
    t0 = time.time()
    if src.kind == "local":
        n = _walk_local(source_id, src.resolved_root(), gen)
    else:
        n = _walk_remote(source_id, gen)
    removed = db.drop_stale(source_id, gen)
    return {"source": source_id, "entries": n, "removed": removed,
            "elapsed": round(time.time() - t0, 2)}


def index_dir(source_id: str, path: str = "/") -> None:
    """写操作之后顺手更新一层目录（上传/新建/删除后立刻能搜到）。"""
    try:
        ad = get_adapter(source_id)
        gen = int(time.time() * 1000)
        entries, _ = ad.list(path)
        gen += 0
        rows = [(source_id, e.path, e.name, posixpath.dirname(e.path) or "/",
                 int(e.is_dir), e.kind, e.size, e.mtime, gen) for e in entries]
        db.upsert_many(rows)
    except Exception as exc:  # noqa: BLE001
        log.debug("index_dir %s %s 失败: %s", source_id, path, exc)
    # 别让 gen 因为这一层的刷新而把全库标脏：
    # upsert 会写入新 gen，drop_stale 只在全量扫描时按那一轮的 gen 做，不受影响。


def full_scan(blocking: bool = True) -> dict:
    """全量扫描所有启用的来源。"""
    global _scanning
    if not _lock.acquire(blocking=blocking):
        return {"ok": True, "busy": True}
    try:
        _scanning = True
        db.set_meta("scanning", "1")
        result = {"ok": True, "sources": []}
        for src in CFG.sources:
            if not src.enabled:
                continue
            try:
                result["sources"].append(scan_source(src.id))
            except Exception as exc:  # noqa: BLE001
                log.warning("扫描 %s 失败: %s", src.id, exc)
                result["sources"].append({"source": src.id, "error": str(exc)})
        db.set_meta("last_scan", time.strftime("%Y-%m-%d %H:%M:%S"))
        return result
    finally:
        db.set_meta("scanning", "0")
        _scanning = False
        _lock.release()


def full_scan_async() -> dict:
    threading.Thread(target=full_scan, kwargs={"blocking": True}, daemon=True).start()
    return {"ok": True, "started": True}

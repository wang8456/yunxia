"""建索引：全量扫一遍 + 跟随 inotify 增量更新。

全量扫描用「代（gen）」标脏：扫完把 gen 不等于本次的删掉，
这样中途新增/删除的文件不会留下幽灵条目，也不需要逐条比对。
"""

from __future__ import annotations

import logging
import os
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


def scan_source(source_id: str, batch: int = 2000) -> dict:
    """同步全量扫描一个源，返回统计。"""
    ad = get_adapter(source_id)
    root = ad.abs_path("/")
    if not root:
        log.warning("源 %s 不是本地源，跳过全量扫描", source_id)
        return {"source": source_id, "skipped": True}

    gen = time.time_ns()      # 纳秒：同一秒内连扫两次也不会撞代
    buf: list[tuple] = []
    seen = 0
    t0 = time.time()
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if not d.startswith(".")]
        rel_dir = os.path.relpath(dirpath, root)
        rel_dir = "/" if rel_dir == "." else "/" + rel_dir.replace(os.sep, "/")

        for d in dirnames:
            buf.append((source_id, posixpath.join(rel_dir, d), d, rel_dir, 1, "dir", 0, 0.0, gen))
        for f in filenames:
            if f.startswith(".") or f.endswith(".part"):
                continue
            try:
                full = os.path.join(dirpath, f)
                s = os.stat(full)
            except OSError:
                continue
            buf.append((source_id, posixpath.join(rel_dir, f), f, rel_dir, 0,
                        kind_of(f, False), s.st_size, s.st_mtime, gen))
        seen += len(buf)
        if len(buf) >= batch:
            db.upsert_many(buf)
            buf.clear()

    db.upsert_many(buf)
    removed = db.drop_stale(source_id, gen)
    db.set_meta("last_scan", time.strftime("%Y-%m-%d %H:%M:%S"))
    out = {"source": source_id, "indexed": seen, "removed": removed,
           "seconds": round(time.time() - t0, 2)}
    log.info("扫描完成 %s", out)
    return out


def full_scan(blocking: bool = False) -> dict:
    """扫所有本地源。blocking=False 时扔到后台线程。"""
    global _scanning

    def run():
        global _scanning
        with _lock:
            if _scanning:
                return
            _scanning = True
        db.set_meta("scanning", "1")
        try:
            for s in CFG.sources:
                if not s.enabled:
                    continue
                try:
                    scan_source(s.id)
                except Exception as exc:  # noqa: BLE001  一个源挂了不影响其它的
                    log.warning("扫描 %s 失败: %s", s.id, exc)
        finally:
            _scanning = False
            db.set_meta("scanning", "0")

    if blocking:
        run()
        return db.stats()
    if _scanning:
        return {"started": False, "reason": "already scanning"}
    threading.Thread(target=run, daemon=True, name="index-scan").start()
    return {"started": True}


def index_event(ev: dict) -> None:
    """inotify 事件 → 索引增量。"""
    if not ev or ev.get("type") != "fs.changed":
        return
    source = ev.get("source", "nas")
    path = posixpath.join(ev.get("path", "/"), ev.get("name", ""))
    try:
        if ev.get("op") == "delete":
            db.delete_path(source, path)
            return
        ad = get_adapter(source)
        root = ad.abs_path("/")
        if not root:
            return
        abs_p = os.path.join(root, path.lstrip("/"))
        if not os.path.exists(abs_p):
            db.delete_path(source, path)
            return
        s = os.stat(abs_p)
        is_dir = os.path.isdir(abs_p)
        db.upsert_many([(source, path, os.path.basename(abs_p),
                         posixpath.dirname(path) or "/", 1 if is_dir else 0,
                         kind_of(os.path.basename(abs_p), is_dir),
                         0 if is_dir else s.st_size, s.st_mtime, time.time_ns())])
    except Exception as exc:  # noqa: BLE001  索引失败不能影响推送
        log.debug("索引事件失败 %s: %s", path, exc)

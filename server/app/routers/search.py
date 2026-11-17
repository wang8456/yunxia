"""搜索域：文件名 / 路径搜索（FTS5 trigram，<3 字退回 LIKE）。"""

from __future__ import annotations

import time

from fastapi import APIRouter, Query
from pydantic import BaseModel

from .. import db, indexer
from ..auth import Device, require_write

router = APIRouter(prefix="/search", tags=["search"])


class Hit(BaseModel):
    name: str
    path: str
    parent: str
    source: str
    is_dir: bool
    kind: str
    size: int
    mtime: float


class SearchOut(BaseModel):
    q: str
    total: int
    took_ms: int
    items: list[Hit]


@router.get("", response_model=SearchOut)
def search(
    device: Device,
    q: str = "",
    source: str | None = None,
    kind: str | None = Query(None, pattern="^(dir|image|video|audio|pdf|text|code|archive|file)$"),
    limit: int = Query(50, ge=1, le=200),
    offset: int = Query(0, ge=0),
) -> SearchOut:
    t0 = time.time()
    total, rows = db.search(q, source=source or None, kind=kind, limit=limit, offset=offset)
    return SearchOut(
        q=q, total=total, took_ms=int((time.time() - t0) * 1000),
        items=[Hit(name=r["name"], path=r["path"], parent=r["parent"], source=r["source"],
                   is_dir=bool(r["is_dir"]), kind=r["kind"], size=r["size"], mtime=r["mtime"])
               for r in rows],
    )


@router.get("/status")
def status(device: Device) -> dict:
    return db.stats()


@router.post("/reindex")
def reindex(device: Device, blocking: bool = False) -> dict:
    require_write(device)
    if blocking:
        return indexer.full_scan(blocking=True)
    return indexer.full_scan_async()

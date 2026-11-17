"""继续观看：记住每个片子播到哪，回来接着看。

只存 path / 名字 / 进度。开头 10 秒内不动进度（片头曲），
离结尾不到 30 秒视为看完直接清掉，免得「继续观看」里堆一排其实看完的。
"""

from __future__ import annotations

import time

from fastapi import APIRouter, Query
from pydantic import BaseModel, Field

from ..auth import Device
from ..db import conn

router = APIRouter(tags=["play"])

_MIN_POS = 10.0
_TAIL = 30.0


class PlayIn(BaseModel):
    path: str
    pos: float = Field(ge=0)
    dur: float = Field(ge=0)
    name: str = ""


@router.get("")
def list_play(device: Device, limit: int = Query(default=8, ge=1, le=30)) -> dict:
    rows = conn().execute(
        "SELECT path, name, pos, dur, updated FROM play ORDER BY updated DESC LIMIT ?",
        (limit,),
    ).fetchall()
    items = []
    for r in rows:
        dur = float(r["dur"] or 0)
        pos = float(r["pos"] or 0)
        items.append({
            "path": r["path"],
            "name": r["name"] or r["path"].rsplit("/", 1)[-1],
            "pos": round(pos, 2),
            "dur": round(dur, 2),
            "pct": round(pos / dur * 100, 1) if dur > 0 else 0.0,
            "updated": r["updated"],
        })
    return {"items": items}


@router.get("/one")
def get_one(device: Device, path: str = Query(...)) -> dict:
    r = conn().execute(
        "SELECT path, name, pos, dur, updated FROM play WHERE path=?", (path,)
    ).fetchone()
    if not r:
        return {"found": False}
    dur = float(r["dur"] or 0)
    return {
        "found": True,
        "path": r["path"],
        "name": r["name"] or r["path"].rsplit("/", 1)[-1],
        "pos": round(float(r["pos"] or 0), 2),
        "dur": round(dur, 2),
        "pct": round(float(r["pos"] or 0) / dur * 100, 1) if dur > 0 else 0.0,
    }


@router.put("")
def save_play(body: PlayIn, device: Device) -> dict:
    c = conn()
    dur = float(body.dur or 0)
    pos = float(body.pos or 0)
    if dur > 0 and pos >= dur - _TAIL:            # 看完了
        c.execute("DELETE FROM play WHERE path=?", (body.path,))
        c.commit()
        return {"ok": True, "kept": False}
    if pos < _MIN_POS and dur > 0 and pos / dur < 0.02:   # 刚开头，不留
        c.execute("DELETE FROM play WHERE path=?", (body.path,))
        c.commit()
        return {"ok": True, "kept": False}
    c.execute(
        """INSERT INTO play(path, name, pos, dur, updated) VALUES(?,?,?,?,?)
           ON CONFLICT(path) DO UPDATE SET
             name=excluded.name, pos=excluded.pos, dur=excluded.dur, updated=excluded.updated""",
        (body.path, body.name, pos, dur, time.time()),
    )
    c.commit()
    return {"ok": True, "kept": True}


@router.delete("")
def forget(device: Device, path: str = Query(...)) -> dict:
    c = conn()
    c.execute("DELETE FROM play WHERE path=?", (path,))
    c.commit()
    return {"ok": True}

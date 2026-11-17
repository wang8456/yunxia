"""听译 API。

路径顺序有讲究：``/subs/for``、``/subs/config`` 这类静态段必须写在 ``/subs/{jid}`` 前面，
否则会被当成 jid（表现为「听译中转：no such job」这种看不懂的 404）。
"""

from __future__ import annotations

import importlib.util

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import Response
from pydantic import BaseModel, Field

from .. import subs as core
from ..auth import Device, require_write
from ..config import CFG

router = APIRouter(prefix="/subs", tags=["subs"])


def _deps() -> dict:
    """转写依赖装没装（前端据此提示「去装 faster-whisper」）。"""
    return {
        "faster_whisper": importlib.util.find_spec("faster_whisper") is not None,
        "av": importlib.util.find_spec("av") is not None,
    }


def _state() -> dict:
    tr = CFG.subs.tr()
    return {
        "enabled": bool(CFG.subs.enabled),
        "model": CFG.subs.model,
        "device": CFG.subs.device,
        "compute_type": CFG.subs.compute_type,
        "language": CFG.subs.language,
        "max_active": int(CFG.subs.max_active or 1),
        "deps": _deps(),
        "translate": {"ready": bool(tr["base"] and tr["api_key"] and tr["model"]),
                      "to": tr["to"], "model": tr["model"], "base": tr["base"]},
    }


def _ensure() -> None:
    if not CFG.subs.enabled:
        raise HTTPException(503, "听译没开：config.json 里把 subs.enabled 改成 true 再重启服务")
    if not _deps()["faster_whisper"]:
        raise HTTPException(
            503, "服务端没装 faster-whisper：pip install -r requirements-subs.txt 后重启")


@router.get("")
def list_jobs(device: Device) -> dict:
    core.load_all()
    return {"jobs": core.list_jobs(), **_state()}


class AddIn(BaseModel):
    source: str = ""
    path: str = Field(description="视频在该来源里的路径")
    name: str = ""
    lang: str = Field("", description="留空=自动识别；也可以写 ja / en / zh")


@router.post("/add")
def add(device: Device, body: AddIn) -> dict:
    require_write(device)
    _ensure()
    if not body.path:
        raise HTTPException(400, "缺少 path")
    return core.add(body.source or CFG.default_source, body.path, body.name, body.lang)


class IdIn(BaseModel):
    id: str


@router.post("/cancel")
def cancel(device: Device, body: IdIn) -> dict:
    require_write(device)
    return {"ok": core.cancel(body.id)}


@router.post("/delete")
def delete(device: Device, body: IdIn) -> dict:
    require_write(device)
    return {"ok": core.delete(body.id), "deleted": body.id}


class TrIn(BaseModel):
    id: str
    to: str = ""


@router.post("/translate")
def translate(device: Device, body: TrIn) -> dict:
    require_write(device)
    try:
        return core.translate(body.id, body.to)
    except KeyError:
        raise HTTPException(404, "没有这个任务")
    except RuntimeError as exc:
        raise HTTPException(409, str(exc))


class CfgIn(BaseModel):
    max_active: int = Field(ge=1, le=4)


@router.post("/config")
def set_config(device: Device, body: CfgIn) -> dict:
    require_write(device)
    return {"ok": True, "max_active": core.set_max_active(body.max_active)}


@router.get("/for")
def find_for(device: Device, source: str = "", path: str = Query(...)) -> dict:
    """播放器用：这条视频有没有现成字幕。"""
    return core.for_path(source or CFG.default_source, path)


@router.get("/status")
def status(device: Device) -> dict:
    return _state()


@router.get("/{jid}")
def detail(device: Device, jid: str, since: int = Query(0, ge=0)) -> dict:
    got = core.segments(jid, since)
    if got is None:
        raise HTTPException(404, "没有这个任务")
    segs, pub = got
    return {**pub, "since": since, "segments_list": segs}


@router.get("/{jid}/srt")
def srt(device: Device, jid: str, trans: int = Query(1, ge=0, le=1)):
    try:
        text = core.srt(jid, bool(trans))
    except KeyError:
        raise HTTPException(404, "没有这个任务")
    job = core.get(jid) or {}
    name = (job.get("name") or jid).rsplit(".", 1)[0]
    from urllib.parse import quote

    return Response(
        text, media_type="application/x-subrip; charset=utf-8",
        headers={"Content-Disposition":
                 f"attachment; filename*=UTF-8''{quote(name)}.zh.srt"},
    )

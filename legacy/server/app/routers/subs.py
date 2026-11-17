"""听译（字幕）任务：NAS 上的 subs-hub（127.0.0.1:5092）负责排队、翻译、存字幕，
真正吃 CPU 的转写在电脑上的 asr-worker 里跑。

这里只做两件事：
  1. 把 hub 的数据归一成和磁力/ed2k 一样的口径，前端只认一种；
  2. 建任务时替客户端签发直链（电脑上的 worker 要能直接拉到那个视频文件）。
"""

from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request

from fastapi import APIRouter, HTTPException, Response
from pydantic import BaseModel, Field

from ..auth import Device, sign_path
from ..config import CFG

router = APIRouter(prefix="/subs", tags=["subs"])

TIMEOUT = 8


def _hub() -> str:
    return CFG.hubs.get("subs", "http://127.0.0.1:5092")


def _call(path: str, data: dict | None = None, timeout: int = TIMEOUT) -> dict:
    url = _hub() + path
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request(url, data=body,
                                method="POST" if body is not None else "GET")
    if body is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read() or b"{}")
    except urllib.error.HTTPError as e:
        try:
            detail = json.loads(e.read() or b"{}").get("error", str(e))
        except Exception:
            detail = str(e)
        raise HTTPException(e.code, f"听译中转：{detail}")
    except Exception as e:
        raise HTTPException(502, f"听译中转不可达：{e}")


def _pct(j: dict) -> float:
    total = float(j.get("dur_total") or 0)
    done = float(j.get("done_until") or 0)
    if total <= 0:
        return 0.0
    return round(min(100.0, done / total * 100), 1)


def _norm(j: dict) -> dict:
    return {
        "id": j.get("id", ""),
        "kind": "sub",
        "name": j.get("name") or j.get("folder") or "(未命名)",
        "folder": j.get("folder", ""),
        "state": j.get("state", ""),
        "lang": j.get("lang", ""),
        "pct": _pct(j),
        "dur": round(float(j.get("dur_total") or 0), 1),
        "segments": len(j.get("segments") or []),
        "msg": j.get("msg", ""),
        "age": int(float(j.get("created_age") or 0)),
    }


class AddIn(BaseModel):
    path: str = Field(min_length=1)
    name: str = ""
    source: str = "nas"
    model: str = "turbo"


class IdIn(BaseModel):
    id: str = Field(min_length=1)


@router.get("")
def list_subs(device: Device, limit: int = 40) -> dict:
    try:
        r = _call("/jobs")
    except HTTPException as e:
        # 中转挂了不影响别的任务，只是这一栏空着
        return {"jobs": [], "online": False, "error": str(e.detail)}
    jobs = sorted(r.get("jobs") or [], key=lambda j: -(j.get("created_age") or 0))
    out = [_norm(j) for j in jobs[:limit]]
    return {"jobs": out, "online": True}


@router.post("/add")
def add_sub(device: Device, body: AddIn) -> dict:
    """建一个听译任务：给 hub 一个电脑能直接拉到的直链。"""
    exp = int(time.time()) + 6 * 3600
    sig = sign_path(body.path, exp, extra=body.source)
    rel = f"/f/{exp}/{sig}/{body.source}{urllib.parse.quote(body.path)}"
    # hub 与 worker 都在局域网里，用 NAS 自己的地址而不是 127.0.0.1
    host = CFG.public_base.rstrip("/")
    url = f"{host}{rel}"
    name = body.name or body.path.rsplit("/", 1)[-1]
    r = _call("/job", {"url": url, "name": name,
                       "model": body.model if body.model in ("turbo", "small") else "turbo"})
    return {"ok": True, **r}


def _stem(name: str) -> str:
    base = name.replace("\\", "/").rsplit("/", 1)[-1]
    for ext in (".mp4", ".mkv", ".avi", ".mov", ".ts", ".m4v", ".wmv", ".webm", ".flv"):
        if base.lower().endswith(ext):
            return base[: -len(ext)]
    return base


def _match(path: str, j: dict) -> int:
    """给一个视频路径，看这个听译任务是不是它的字幕。分越高越可信。"""
    want = _stem(path).lower()
    if not want:
        return 0
    job_name = _stem(str(j.get("name") or "")).lower()
    folder = str(j.get("folder") or "").lower()
    if job_name and (job_name == want or want.startswith(job_name)):
        return 3
    if folder and (folder == want or want.startswith(folder) or folder.startswith(want)):
        return 2
    if job_name and (job_name in want or want in job_name):
        return 1
    return 0


@router.get("/for")
def subs_for(device: Device, path: str) -> dict:
    """播放器用：这个片有没有字幕？有就把整段返回，前端自己按时间轴叠。"""
    r = _call("/jobs")
    best, score = None, 0
    for j in r.get("jobs") or []:
        sc = _match(path, j)
        if sc > score:
            best, score = j, sc
    if not best:
        return {"found": False}
    segs = best.get("segments") or []
    return {
        "found": bool(segs),
        "id": best.get("id", ""),
        "name": best.get("name") or best.get("folder") or "",
        "state": best.get("state", ""),
        "lang": best.get("lang", ""),
        "done": best.get("state") == "done",
        "segments": segs,
    }


@router.get("/{jid}")
def get_sub(device: Device, jid: str) -> dict:
    j = _call(f"/job/{urllib.parse.quote(jid)}")
    out = _norm(j)
    out["segments_list"] = j.get("segments") or []
    return out


@router.get("/{jid}/srt")
def srt(device: Device, jid: str) -> Response:
    """把 hub 上的双语 srt 原样给客户端，文件名用任务名，存下来就能丢给播放器。"""
    url = _hub() + f"/srt/{urllib.parse.quote(jid)}"
    try:
        with urllib.request.urlopen(url, timeout=20) as r:
            body = r.read()
    except Exception as e:  # noqa: BLE001
        raise HTTPException(502, f"取字幕失败：{e}")
    name = "subtitle"
    try:
        for j in _call("/jobs").get("jobs") or []:
            if j.get("id") == jid:
                name = _stem(str(j.get("name") or j.get("folder") or "subtitle"))
                break
    except Exception:  # noqa: BLE001
        pass
    fn = urllib.parse.quote(f"{name}.srt")
    return Response(content=body, media_type="application/x-subrip; charset=utf-8",
                    headers={"Content-Disposition": f"attachment; filename*=UTF-8''{fn}"})


@router.post("/cancel")
def cancel_sub(device: Device, body: IdIn) -> dict:
    r = _call("/cancel", {"id": body.id})
    return {"ok": True, **r}

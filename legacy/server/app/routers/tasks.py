"""任务中心：磁力（5094）+ ed2k（5093）统一成一个列表。

两个中转的返回格式不一样（一个用 aria2 的 gid，一个用 ed2k hash），
这里全部归一化成同一种 Task，前端只认这一种。
"""

from __future__ import annotations

import logging

import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field

from ..auth import Device
from ..config import CFG

log = logging.getLogger("yunxia.tasks")
router = APIRouter(prefix="/tasks", tags=["tasks"])

TIMEOUT = httpx.Timeout(4.0, connect=1.5)
# 只有这两种是下载任务；subs（听译）在 routers/subs.py 里单独处理
DOWNLOAD_KINDS = ("magnet", "ed2k")


class Task(BaseModel):
    id: str
    kind: str                     # magnet | ed2k
    name: str = ""
    size: int = 0
    done: int = 0
    pct: float = 0.0
    speed: int = 0                # 字节/秒
    state: str = ""               # active | waiting | paused | done | error
    target: str = "nas"
    target_name: str = ""
    path: str = ""
    error: str = ""


class TasksOut(BaseModel):
    tasks: list[Task]
    hubs: dict[str, dict]         # 每个中转的健康状态（挂一个不影响另一个）


def _get_json(base: str, path: str) -> dict:
    with httpx.Client(timeout=TIMEOUT, trust_env=False) as c:
        r = c.get(base.rstrip("/") + path)
        r.raise_for_status()
        return r.json()


def _post_json(base: str, path: str, body: dict) -> dict:
    with httpx.Client(timeout=TIMEOUT, trust_env=False) as c:
        r = c.post(base.rstrip("/") + path, json=body)
        r.raise_for_status()
        return r.json()


def normalize(raw: dict, kind: str) -> Task:
    """把两种中转的字段名对齐成一个 Task。"""
    pct = raw.get("pct")
    size = int(raw.get("size") or raw.get("total") or 0)
    done = int(raw.get("done") or raw.get("completed") or 0)
    if pct is None:
        pct = (done / size * 100) if size else 0.0
    return Task(
        id=str(raw.get("gid") or raw.get("hash") or raw.get("id") or ""),
        kind=kind,
        name=str(raw.get("name") or raw.get("title") or ""),
        size=size,
        done=done,
        pct=round(float(pct), 1),
        speed=int(raw.get("speed") or raw.get("downspeed") or 0),
        state=str(raw.get("status") or raw.get("state") or ""),
        target=str(raw.get("target") or "nas"),
        target_name=str(raw.get("target_name") or ""),
        path=str(raw.get("path") or raw.get("file") or ""),
        error=str(raw.get("error") or ""),
    )


def _hub_status(kind: str, base: str) -> dict:
    try:
        h = _get_json(base, "/health")
        return {"online": bool(h.get("ok")), "name": h.get("name", ""),
                "dir": h.get("dir", ""), "free_gb": h.get("free_gb"),
                "error": h.get("error", "")}
    except Exception as exc:  # noqa: BLE001  一个中转挂了不能拖垮整个列表
        log.debug("中转 %s 不可用: %s", kind, exc)
        return {"online": False, "error": str(exc)}


# /tasks 每 2 秒被前端拉一次，而两个中转都要回话（一个挂了就等满 6 秒）。
# 所以：并发去问 + 结果缓存 3 秒，别让「一个中转掉线」把整栏拖成十几秒。
_CACHE: dict = {"at": 0.0, "data": None, "key": None}
_CACHE_TTL = 8.0


def _one_hub(kind: str) -> tuple[str, dict, list]:
    base = CFG.hubs.get(kind, "")
    if not base:
        return kind, {}, []
    st = _hub_status(kind, base)
    rows: list = []
    if st["online"]:
        try:
            data = _get_json(base, "/list")
            rows = data.get("tasks") or []
        except Exception as exc:  # noqa: BLE001
            st["error"] = f"取任务失败：{exc}"
    return kind, st, rows


@router.get("", response_model=TasksOut)
def list_tasks(device: Device) -> TasksOut:
    import time as _t
    from concurrent.futures import ThreadPoolExecutor

    now = _t.time()
    # 缓存键里带上中转地址：配置一变（测试会换地址）就自动失效，不会串味
    key = tuple(sorted((k, v) for k, v in CFG.hubs.items() if k in DOWNLOAD_KINDS))
    if (_CACHE["data"] is not None and _CACHE["key"] == key
            and now - _CACHE["at"] < _CACHE_TTL):
        return _CACHE["data"]

    tasks: list[Task] = []
    hubs: dict[str, dict] = {}
    with ThreadPoolExecutor(max_workers=len(DOWNLOAD_KINDS)) as pool:
        for kind, st, rows in pool.map(_one_hub, DOWNLOAD_KINDS):
            if not st:
                continue
            hubs[kind] = st
            for raw in rows:
                try:
                    tasks.append(normalize(raw, kind))
                except Exception:  # noqa: BLE001  一条坏数据不影响整个列表
                    continue
    tasks.sort(key=lambda t: (t.state not in ("active", "waiting"), -t.pct))
    out = TasksOut(tasks=tasks, hubs=hubs)
    _CACHE["data"], _CACHE["at"], _CACHE["key"] = out, now, key
    return out


class AddIn(BaseModel):
    kind: str = Field(pattern="^(magnet|ed2k)$")
    urls: list[str]
    dir: str = ""
    target: str = "nas"


@router.post("/add")
def add(device: Device, body: AddIn) -> dict:
    base = CFG.hubs.get(body.kind)
    if not base:
        raise HTTPException(400, f"没有这个下载器：{body.kind}")
    links = [u.strip() for u in body.urls if u.strip()]
    if not links:
        raise HTTPException(400, "没有给链接")
    payload = {
        "magnet": links[0],
        "links": links,
        "link": links[0],
        "dir": body.dir.strip("/"),
        "target": body.target,
    }
    try:
        return _post_json(base, "/add", payload)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(502, f"{body.kind} 中转不可用：{exc}")


class ActIn(BaseModel):
    kind: str = Field(pattern="^(magnet|ed2k)$")
    id: str
    act: str = Field(pattern="^(pause|resume|remove)$")


@router.post("/act")
def act(device: Device, body: ActIn) -> dict:
    base = CFG.hubs.get(body.kind)
    if not base:
        raise HTTPException(400, f"没有这个下载器：{body.kind}")
    if body.kind == "magnet":
        path = {"pause": "/pause", "resume": "/resume", "remove": "/purge"}[body.act]
        payload = {"gid": body.id, "target": "nas"}
    else:
        path = "/cancel" if body.act == "remove" else f"/{body.act}"
        payload = {"hash": body.id, "target": "nas"}
    try:
        return _post_json(base, path, payload)
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(502, f"{body.kind} 中转不可用：{exc}")

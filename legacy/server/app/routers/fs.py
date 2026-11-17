"""文件域 API：列目录、直链、上传、改名、删除、新建、文本预览。

写操作走 FastAPI（同一台 NAS，直写磁盘最快）；
下载/播放走 /f/ 签名直链 → dufs 出字节（Range、断点续传都是 dufs 的活）。
"""

from __future__ import annotations

import os
import posixpath
import time
import urllib.parse

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import Response
from pydantic import BaseModel, Field

from ..adapters import get_adapter
from ..auth import Device, sign_path
from ..config import CFG
from ..models import FileEntry, LinkOut, ListOut

router = APIRouter(prefix="/fs", tags=["fs"])

LINK_TTL = 6 * 3600          # 直链有效期：够看一部电影，也不至于长期泄露


def _adapter(source: str):
    try:
        return get_adapter(source)
    except KeyError:
        raise HTTPException(400, f"未知来源：{source}")


def _safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except ValueError as exc:
        raise HTTPException(400, str(exc))
    except FileNotFoundError:
        raise HTTPException(404, "路径不存在")
    except PermissionError:
        raise HTTPException(403, "没有权限")
    except OSError as exc:
        raise HTTPException(500, f"文件系统错误：{exc}")


@router.get("/list", response_model=ListOut)
def list_dir(
    device: Device,
    source: str = "nas",
    path: str = "/",
    sort: str = Query("name", pattern="^(name|size|mtime|kind)$"),
    order: str = Query("asc", pattern="^(asc|desc)$"),
) -> ListOut:
    ad = _adapter(source)
    entries, meta = _safe(ad.list, path)
    reverse = order == "desc"
    if sort == "name":
        entries.sort(key=lambda e: (not e.is_dir, e.name.lower()), reverse=reverse)
        if reverse:   # 倒序时仍然目录在前
            entries.sort(key=lambda e: not e.is_dir)
    else:
        key = {"size": lambda e: e.size, "mtime": lambda e: e.mtime,
               "kind": lambda e: (e.kind, e.name.lower())}[sort]
        entries.sort(key=lambda e: (not e.is_dir, key(e)), reverse=reverse)
        if reverse:
            entries.sort(key=lambda e: not e.is_dir)
    clean = posixpath.normpath("/" + path.lstrip("/"))
    parent = None if clean == "/" else posixpath.dirname(clean) or "/"
    return ListOut(
        source=source, path=clean, parent=parent, entries=entries,
        allow_upload=meta.get("allow_upload", False),
        allow_delete=meta.get("allow_delete", False),
    )


@router.get("/stat", response_model=FileEntry)
def stat(device: Device, source: str = "nas", path: str = "/") -> FileEntry:
    ad = _adapter(source)
    return _safe(ad.stat, path)


@router.get("/link", response_model=LinkOut)
def link(device: Device, source: str = "nas", path: str = "/") -> LinkOut:
    """签发下载地址。

    本地源（NAS）→ /f/<exp>/<sig>/<source><path>，由 5007 前置校验后带 Basic 转发给 dufs，
    客户端零口令、Range 直通、34MB/s。
    远端源（115/电脑）→ /api/v1/fs/raw?…&sig=…，由本服务流式代理（它们本来就在别的机器上）。
    """
    ad = _adapter(source)
    entry = _safe(ad.stat, path)
    if entry.is_dir:
        raise HTTPException(400, "目录没有直链，用 /fs/archive")
    exp = int(time.time()) + LINK_TTL
    sig = sign_path(entry.path, exp, extra=source)
    if ad.abs_path("/") is not None:
        url = f"/f/{exp}/{sig}/{source}{urllib.parse.quote(entry.path)}"
    else:
        q = urllib.parse.urlencode(
            {"source": source, "path": entry.path, "exp": exp, "sig": sig})
        url = f"/api/v1/fs/raw?{q}"
    return LinkOut(url=url, expires=exp, size=entry.size)


@router.get("/raw")
def raw(request: Request, source: str = "nas", path: str = "/", exp: int = 0, sig: str = ""):
    """远端源的字节流代理（带签名，不需要 Bearer —— 播放器带不了 header）。"""
    from ..auth import check_path_sig

    if not check_path_sig(path, exp, sig, extra=source):
        raise HTTPException(403, "直链已过期或签名不对")
    ad = _adapter(source)
    status, headers, body, closer = _safe(ad.raw_request, path, request.headers.get("range"))
    keep = {k: v for k, v in headers.items()
            if k.lower() in ("content-type", "content-length", "content-range",
                             "accept-ranges", "last-modified", "etag")}
    from starlette.responses import StreamingResponse

    def gen():
        try:
            yield from body
        finally:
            try:
                closer[1].close()
                closer[0].close()
            except Exception:  # noqa: BLE001
                pass

    return StreamingResponse(gen(), status_code=status, headers=keep)


class MkdirIn(BaseModel):
    source: str = "nas"
    path: str = Field(description="父目录")
    name: str


@router.post("/mkdir", response_model=FileEntry)
def mkdir(device: Device, body: MkdirIn) -> FileEntry:
    from ..adapters import join

    ad = _adapter(body.source)
    target = _safe(join, body.path, body.name)
    _safe(ad.mkdir, target)
    return _safe(ad.stat, target)


class MoveIn(BaseModel):
    source: str = "nas"
    src: str
    dst: str


@router.post("/move", response_model=FileEntry)
def move(device: Device, body: MoveIn) -> FileEntry:
    ad = _adapter(body.source)
    _safe(ad.move, body.src, body.dst)
    return _safe(ad.stat, body.dst)


class DeleteIn(BaseModel):
    source: str = "nas"
    paths: list[str]


@router.post("/delete")
def delete(device: Device, body: DeleteIn) -> dict:
    ad = _adapter(body.source)
    removed, failed = [], []
    for p in body.paths:
        try:
            ad.delete(p)
            removed.append(p)
        except Exception as exc:  # noqa: BLE001  一个失败不影响其它
            failed.append({"path": p, "error": str(exc)})
    return {"removed": removed, "failed": failed}


@router.put("/upload")
async def upload(
    request: Request,
    device: Device,
    source: str = "nas",
    path: str = Query(description="目标目录"),
    name: str = Query(description="文件名"),
    offset: int = Query(0, ge=0, description="断点续传起始偏移"),
):
    """原始字节上传（PUT body = 文件）。offset>0 时从该偏移继续写。"""
    from ..adapters import join

    ad = _adapter(source)
    target = _safe(join, path, name)
    abs_target = ad.abs_path(target)

    if offset and abs_target:
        # 续传：直接追加，不再走临时文件
        written = 0
        with open(abs_target, "ab") as fh:
            async for chunk in request.stream():
                fh.write(chunk)
                written += len(chunk)
        size = os.path.getsize(abs_target)
        return {"path": target, "size": size, "appended": written}

    if abs_target:
        os.makedirs(os.path.dirname(abs_target), exist_ok=True)
        tmp = abs_target + ".part"
        size = 0
        with open(tmp, "wb") as fh:
            async for chunk in request.stream():
                fh.write(chunk)
                size += len(chunk)
        os.replace(tmp, abs_target)
        return {"path": target, "size": size}

    size = await _safe_async(ad.write_stream, target, request.stream())
    return {"path": target, "size": size}


async def _safe_async(fn, *a):
    try:
        return fn(*a)
    except ValueError as exc:
        raise HTTPException(400, str(exc))


@router.get("/text")
def text(device: Device, source: str = "nas", path: str = "/", max_bytes: int = 262144):
    ad = _adapter(source)
    data = _safe(ad.read_head, path, max_bytes)
    try:
        body = data.decode("utf-8")
    except UnicodeDecodeError:
        body = data.decode("utf-8", "replace")
    return Response(body, media_type="text/plain; charset=utf-8",
                    headers={"X-Truncated": "1" if len(data) >= max_bytes else "0"})

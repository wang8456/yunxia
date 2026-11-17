"""文件域 API：列目录、直链、上传、改名、删除、新建、文本预览。

写操作直接落盘/转发；下载和播放一律走 ``/api/v1/fs/raw`` 的签名直链
（相对路径，局域网和外网域名都能用），本服务负责按 Range 出字节。
"""

from __future__ import annotations

import os
import posixpath
import time
import urllib.parse

from fastapi import APIRouter, HTTPException, Query, Request
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel, Field

from .. import indexer
from ..adapters import get_adapter, get_source, join
from ..auth import Device, check_path_sig, require_write, sign_path
from ..config import CFG
from ..models import FileEntry, LinkOut, ListOut

router = APIRouter(prefix="/fs", tags=["fs"])

LINK_TTL = 6 * 3600          # 直链有效期：够看一部电影，也不至于长期泄露

# 大目录一次列目录在远端要 1-3 秒，来回翻同一层不该每次都重拉。
# stale-while-revalidate：新鲜期内直接给；过期了先把旧的端出去，后台再刷。
_LIST_TTL = 60.0        # 新鲜期
_LIST_STALE = 600.0     # 过期后还能顶多久（顶的时候后台刷新）
_LIST_CACHE: dict[tuple, tuple] = {}
_LIST_BUSY: set[tuple] = set()


def _drop_list_cache(source: str | None = None) -> None:
    """写操作之后清缓存：不清就会看到一分钟前的旧目录。"""
    if source is None:
        _LIST_CACHE.clear()
        return
    for k in [k for k in _LIST_CACHE if k[0] == source]:
        _LIST_CACHE.pop(k, None)


def _sort_entries(entries, sort: str, order: str):
    """目录项排序：目录永远在前，倒序时也保持。"""
    reverse = order == "desc"
    if sort == "name":
        entries.sort(key=lambda e: (not e.is_dir, e.name.lower()), reverse=reverse)
    else:
        key = {"size": lambda e: e.size, "mtime": lambda e: e.mtime,
               "kind": lambda e: (e.kind, e.name.lower())}[sort]
        entries.sort(key=lambda e: (not e.is_dir, key(e)), reverse=reverse)
    if reverse:   # 倒序时仍然目录在前
        entries.sort(key=lambda e: not e.is_dir)
    return entries


def _refresh_list_async(cache_key, source: str, path: str, sort: str, order: str) -> None:
    import threading

    def work():
        try:
            ad = _adapter(source)
            entries, meta = ad.list(path)
            _sort_entries(entries, sort, order)
            if len(_LIST_CACHE) > 64:      # 别把内存当缓存用
                _LIST_CACHE.clear()
            _LIST_CACHE[cache_key] = (time.time(), entries, meta)
        except Exception:  # noqa: BLE001
            pass                            # 保持旧缓存，别把界面打空
        finally:
            _LIST_BUSY.discard(cache_key)

    threading.Thread(target=work, daemon=True).start()


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
    except PermissionError as exc:
        raise HTTPException(403, str(exc) or "没有权限")
    except OSError as exc:
        raise HTTPException(500, f"文件系统错误：{exc}")


@router.get("/list", response_model=ListOut)
def list_dir(
    device: Device,
    source: str = "",
    path: str = "/",
    sort: str = Query("name", pattern="^(name|size|mtime|kind)$"),
    order: str = Query("asc", pattern="^(asc|desc)$"),
) -> ListOut:
    source = source or CFG.default_source
    clean = posixpath.normpath("/" + path.lstrip("/"))
    cache_key = (source, clean, sort, order)
    hit = _LIST_CACHE.get(cache_key)
    age = time.time() - hit[0] if hit else None
    if hit is not None and age < _LIST_TTL:
        entries, meta = hit[1], hit[2]
    elif hit is not None and age < _LIST_STALE:
        entries, meta = hit[1], hit[2]
        if cache_key not in _LIST_BUSY:
            _LIST_BUSY.add(cache_key)
            _refresh_list_async(cache_key, source, clean, sort, order)
    else:
        ad = _adapter(source)
        entries, meta = _safe(ad.list, clean)
        _sort_entries(entries, sort, order)
        if len(_LIST_CACHE) > 64:
            _LIST_CACHE.clear()
        _LIST_CACHE[cache_key] = (time.time(), entries, meta)
    parent = None if clean == "/" else posixpath.dirname(clean) or "/"
    return ListOut(
        source=source, path=clean, parent=parent, entries=entries,
        allow_upload=meta.get("allow_upload", False),
        allow_delete=meta.get("allow_delete", False),
    )


@router.get("/stat", response_model=FileEntry)
def stat(device: Device, source: str = "", path: str = "/") -> FileEntry:
    ad = _adapter(source or CFG.default_source)
    return _safe(ad.stat, path)


@router.get("/link", response_model=LinkOut)
def link(request: Request, device: Device, source: str = "", path: str = "/") -> LinkOut:
    """签发下载地址：一律是相对路径，客户端自己按当前 origin 补全。"""
    source = source or CFG.default_source
    ad = _adapter(source)
    entry = _safe(ad.stat, path)
    if entry.is_dir:
        raise HTTPException(400, "目录没有直链")
    exp = int(time.time()) + LINK_TTL
    sig = sign_path(entry.path, exp, extra=source)
    q = urllib.parse.urlencode(
        {"source": source, "path": entry.path, "exp": exp, "sig": sig})
    return LinkOut(url=f"/api/v1/fs/raw?{q}", expires=exp, size=entry.size)


def _local_stream(abs_path: str, range_header: str | None):
    """本地文件按 Range 出字节（206 + content-range），没有 Range 就整段流。"""
    size = os.path.getsize(abs_path)
    start, end = 0, size - 1
    status = 200
    if range_header and range_header.startswith("bytes="):
        spec = range_header[6:].split(",")[0].strip()
        a, _, b = spec.partition("-")
        try:
            if a:
                start = int(a)
                end = int(b) if b else size - 1
            elif b:                       # bytes=-N 取最后 N 字节
                start = max(0, size - int(b))
                end = size - 1
        except ValueError:
            start, end = 0, size - 1
        if start >= size:
            raise HTTPException(416, "Range 超出文件大小")
        end = min(end, size - 1)
        status = 206
    length = max(0, end - start + 1)

    def gen():
        with open(abs_path, "rb") as fh:
            fh.seek(start)
            left = length
            while left > 0:
                chunk = fh.read(min(1 << 20, left))
                if not chunk:
                    break
                left -= len(chunk)
                yield chunk

    headers = {
        "content-length": str(length),
        "accept-ranges": "bytes",
        "content-type": _mime(abs_path),
    }
    if status == 206:
        headers["content-range"] = f"bytes {start}-{end}/{size}"
    return status, headers, gen()


def _mime(path: str) -> str:
    import mimetypes

    mime, _ = mimetypes.guess_type(path)
    if not mime:
        mime = "application/octet-stream"
    if path.lower().endswith((".mkv", ".ts", ".m4v")):
        mime = "video/mp4"          # 有些浏览器不认 video/x-matroska
    if path.lower().endswith((".srt", ".ass", ".vtt")):
        mime = "text/plain; charset=utf-8"
    return mime


@router.get("/raw")
def raw(request: Request, source: str = "", path: str = "/", exp: int = 0, sig: str = ""):
    """字节流：带签名，不需要 Bearer —— 播放器 / <video> 带不了 header。"""
    source = source or CFG.default_source
    if not check_path_sig(path, exp, sig, extra=source):
        raise HTTPException(403, "直链已过期或签名不对")
    ad = _adapter(source)
    abs_path = ad.abs_path(path)
    if abs_path:
        status, headers, body = _local_stream(abs_path, request.headers.get("range"))
        return StreamingResponse(body, status_code=status, headers=headers)
    status, headers, body, closer = ad.raw_request(path, request.headers.get("range"))
    keep = {k: v for k, v in headers.items()
            if k.lower() in ("content-type", "content-length", "content-range",
                             "accept-ranges", "last-modified", "etag")}

    def gen():
        try:
            yield from body
        finally:
            for obj in closer:
                try:
                    obj.close()
                except Exception:  # noqa: BLE001
                    pass

    return StreamingResponse(gen(), status_code=status, headers=keep)


class MkdirIn(BaseModel):
    source: str = ""
    path: str = Field(description="父目录")
    name: str


@router.post("/mkdir", response_model=FileEntry)
def mkdir(device: Device, body: MkdirIn) -> FileEntry:
    require_write(device)
    source = body.source or CFG.default_source
    ad = _adapter(source)
    target = _safe(join, body.path, body.name)
    _safe(ad.mkdir, target)
    _drop_list_cache(source)
    indexer.index_dir(source, body.path)
    return _safe(ad.stat, target)


class MoveIn(BaseModel):
    source: str = ""
    src: str
    dst: str


@router.post("/move", response_model=FileEntry)
def move(device: Device, body: MoveIn) -> FileEntry:
    require_write(device)
    source = body.source or CFG.default_source
    ad = _adapter(source)
    _safe(ad.move, body.src, body.dst)
    _drop_list_cache(source)
    indexer.index_dir(source, posixpath.dirname(body.dst) or "/")
    return _safe(ad.stat, body.dst)


class DeleteIn(BaseModel):
    source: str = ""
    paths: list[str]


@router.post("/delete")
def delete(device: Device, body: DeleteIn) -> dict:
    require_write(device)
    source = body.source or CFG.default_source
    ad = _adapter(source)
    removed, failed = [], []
    for p in body.paths:
        try:
            ad.delete(p)
            removed.append(p)
        except Exception as exc:  # noqa: BLE001  一个失败不影响其它
            failed.append({"path": p, "error": str(exc)})
    if removed:
        _drop_list_cache(source)
        for p in removed:
            indexer.index_dir(source, posixpath.dirname(p) or "/")
    return {"removed": removed, "failed": failed}


@router.put("/upload")
async def upload(
    request: Request,
    device: Device,
    source: str = "",
    path: str = Query(description="目标目录"),
    name: str = Query(description="文件名"),
    offset: int = Query(0, ge=0, description="断点续传起始偏移"),
):
    """原始字节上传（PUT body = 文件内容）。offset>0 时从该偏移继续写。"""
    require_write(device)
    source = source or CFG.default_source
    ad = _adapter(source)
    target = _safe(join, path, name)
    abs_target = ad.abs_path(target)

    if offset and abs_target:
        written = 0
        with open(abs_target, "ab") as fh:
            async for chunk in request.stream():
                fh.write(chunk)
                written += len(chunk)
        _drop_list_cache(source)
        return {"path": target, "size": os.path.getsize(abs_target), "appended": written}

    if abs_target:
        os.makedirs(os.path.dirname(abs_target), exist_ok=True)
        tmp = abs_target + ".part"
        size = 0
        with open(tmp, "wb") as fh:
            async for chunk in request.stream():
                fh.write(chunk)
                size += len(chunk)
        os.replace(tmp, abs_target)
        _drop_list_cache(source)
        indexer.index_dir(source, path)
        return {"path": target, "size": size}

    # 远端来源：先落到本地临时文件，再把文件对象交给（同步的）适配器。
    # 直接把 request.stream() 递过去会得到 async generator，适配器里 .read() 直接崩。
    tmp = CFG.tmp_dir / f"up-{os.getpid()}-{int(time.time() * 1000)}.part"
    size = 0
    try:
        with open(tmp, "wb") as fh:
            async for chunk in request.stream():
                fh.write(chunk)
                size += len(chunk)
        with open(tmp, "rb") as fh:
            try:
                ad.write_stream(target, fh)
            except ValueError as exc:
                raise HTTPException(400, str(exc))
            except PermissionError as exc:
                raise HTTPException(403, str(exc) or "没有权限")
        _drop_list_cache(source)
        indexer.index_dir(source, path)
        return {"path": target, "size": size}
    finally:
        try:
            os.unlink(tmp)
        except OSError:
            pass


@router.get("/text")
def text(device: Device, source: str = "", path: str = "/", max_bytes: int = 262144):
    source = source or CFG.default_source
    ad = _adapter(source)
    data = _safe(ad.read_head, path, max_bytes)
    body = data.decode("utf-8", "replace")
    return Response(body, media_type="text/plain; charset=utf-8",
                    headers={"X-Truncated": "1" if len(data) >= max_bytes else "0"})

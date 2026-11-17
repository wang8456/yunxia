"""缩略图：图片走 Pillow 缩放并落盘缓存（本地源读盘，远端源走适配器取字节）。

列表里直接拉原图很吃亏（一张手机照片十几兆），缩略图只有几十 KB，
把这一块的流量砍掉收益最大。视频不抽帧（要 ffmpeg），前端自己画占位。
"""

from __future__ import annotations

import hashlib
import os

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import FileResponse

from ..adapters import get_adapter
from ..auth import Device, decode_token
from ..config import CFG

router = APIRouter(prefix="/thumb", tags=["thumb"])

MAX_W = 640
MAX_SRC = 24 * 1024 * 1024      # 远端原图最多读 24MB 来缩放


def _cache_path(source: str, path: str, w: int, mtime: float) -> "os.PathLike":
    key = f"{source}|{path}|{w}|{int(mtime)}"
    h = hashlib.sha1(key.encode()).hexdigest()[:20]
    return CFG.thumb_dir / h[:2] / f"{h}.jpg"


def _load_bytes(source: str, path: str) -> bytes:
    ad = get_adapter(source)
    abs_path = ad.abs_path(path)
    if abs_path:
        if os.path.getsize(abs_path) > MAX_SRC:
            raise HTTPException(413, "图片太大")
        with open(abs_path, "rb") as fh:
            return fh.read()
    status, headers, body, closer = ad.raw_request(path, None)
    try:
        if status >= 400:
            raise HTTPException(404, "取不到原图")
        buf = bytearray()
        for chunk in body:
            buf += chunk
            if len(buf) > MAX_SRC:
                raise HTTPException(413, "图片太大")
        return bytes(buf)
    finally:
        for obj in closer:
            try:
                obj.close()
            except Exception:  # noqa: BLE001
                pass


def _make(source: str, path: str, w: int) -> FileResponse:
    ad = get_adapter(source)
    try:
        entry = ad.stat(path)
    except FileNotFoundError:
        raise HTTPException(404, "文件不存在")
    if entry.is_dir:
        raise HTTPException(400, "目录没有缩略图")

    out = _cache_path(source, path, w, entry.mtime)
    if out.exists():
        return FileResponse(out, media_type="image/jpeg",
                            headers={"Cache-Control": "public, max-age=86400"})

    try:
        from PIL import Image, ImageOps
    except Exception:  # noqa: BLE001
        raise HTTPException(503, "服务端缺少 Pillow，无法生成缩略图")

    raw = _load_bytes(source, path)
    import io

    try:
        with Image.open(io.BytesIO(raw)) as im:
            im = ImageOps.exif_transpose(im)
            if im.mode not in ("RGB", "L"):
                im = im.convert("RGB")
            im.thumbnail((w, w * 4), Image.LANCZOS)
            out.parent.mkdir(parents=True, exist_ok=True)
            tmp = out.with_suffix(".tmp")
            im.save(tmp, "JPEG", quality=82, optimize=True)
            os.replace(tmp, out)
    except HTTPException:
        raise
    except Exception as exc:  # noqa: BLE001  坏图不该把列表打崩
        raise HTTPException(415, f"无法生成缩略图：{type(exc).__name__}")

    return FileResponse(out, media_type="image/jpeg",
                        headers={"Cache-Control": "public, max-age=86400"})


@router.get("/t")
def thumb_token(path: str = Query(min_length=1), source: str = "", w: int = 320,
                t: str = Query(default="")):
    """给 <img src> 用的版本：浏览器发不了 Authorization 头，令牌走查询串。"""
    try:
        decode_token(t)
    except Exception:  # noqa: BLE001
        if CFG.password:
            raise HTTPException(401, "令牌无效")
    w = max(64, min(MAX_W, w))
    return _make(source or CFG.default_source, path, w)


@router.get("")
def thumb(device: Device, path: str = Query(min_length=1), source: str = "", w: int = 320):
    w = max(64, min(MAX_W, w))
    return _make(source or CFG.default_source, path, w)

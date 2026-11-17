"""缩略图：图片走 Pillow 缩放并落盘缓存，视频没有 ffmpeg 就返回 404 让前端自己画占位。

为什么不用现成的缩略图服务：NAS 上没有 ffmpeg，装一个要连带一大串依赖；
而列表里最吃流量的是手机相册那种十几兆的原图，把这一块的流量砍掉收益最大。
"""

from __future__ import annotations

import hashlib
import os
import urllib.parse
from pathlib import Path

from fastapi import APIRouter, HTTPException, Query
from fastapi.responses import FileResponse

from ..auth import Device, decode_token
from ..config import CFG

router = APIRouter(prefix="/thumb", tags=["thumb"])

CACHE = Path("/mnt/data/home/yunxia-api/thumbs")
MAX_W = 640


def _source_root(source: str) -> Path | None:
    for s in CFG.sources:
        if s.id == source and s.kind == "dufs":
            return Path(s.root)
    return None


def _cache_path(source: str, path: str, w: int, mtime: float) -> Path:
    key = f"{source}|{path}|{w}|{int(mtime)}"
    h = hashlib.sha1(key.encode()).hexdigest()[:20]
    return CACHE / h[:2] / f"{h}.jpg"




@router.get("/t")
def thumb_token(path: str = Query(min_length=1), source: str = "nas", w: int = 320,
                t: str = Query(default="")) -> FileResponse:
    """给 <img src> 用的版本：浏览器发不了 Authorization 头，令牌走查询串。"""
    try:
        decode_token(t)
    except Exception:  # noqa: BLE001
        raise HTTPException(401, "令牌无效")
    return thumb(device=None, path=path, source=source, w=w)  # type: ignore[arg-type]


@router.get("")
def thumb(device: Device, path: str = Query(min_length=1),
          source: str = "nas", w: int = 320) -> FileResponse:
    w = max(64, min(MAX_W, w))
    root = _source_root(source)
    if root is None:
        raise HTTPException(404, "该源不支持缩略图")
    fp = (root / path.lstrip("/")).resolve()
    if not str(fp).startswith(str(root.resolve())):
        raise HTTPException(400, "路径越界")
    if not fp.is_file():
        raise HTTPException(404, "文件不存在")

    out = _cache_path(source, path, w, fp.stat().st_mtime)
    if out.exists():
        return FileResponse(out, media_type="image/jpeg",
                            headers={"Cache-Control": "public, max-age=86400"})

    try:
        from PIL import Image, ImageOps
    except Exception:  # noqa: BLE001
        raise HTTPException(503, "缺少 Pillow")

    try:
        with Image.open(fp) as im:
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

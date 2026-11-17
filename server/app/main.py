"""云匣统一 API（FastAPI）。

一个进程只做控制面：认证、目录、搜索、播放进度、缩略图、对话。
文件字节尽量少经这里：本地源由本服务按 Range 直出，远端源（dufs / WebDAV）
由本服务流式代理，客户端只需要拿一条带签名的相对直链。
"""

from __future__ import annotations

import time
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.middleware.gzip import GZipMiddleware

from .auth import Device
from .config import CFG
from .routers import auth as auth_router
from .routers import chat as chat_router
from .routers import fs as fs_router
from .routers import play as play_router
from .routers import search as search_router
from .routers import thumb as thumb_router

APP_VERSION = "1.0.0"
STARTED_AT = time.time()

@asynccontextmanager
async def lifespan(_app: FastAPI):
    """启动就把文件索引跑起来（后台线程）。"""
    import logging

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    from .indexer import full_scan_async

    full_scan_async()
    yield


app = FastAPI(
    title="云匣 API",
    version=APP_VERSION,
    description="云匣多端统一接口。契约见 /api/v1/openapi.json，前端不手写类型。",
    docs_url="/api/v1/docs",
    openapi_url="/api/v1/openapi.json",
    redoc_url=None,
    lifespan=lifespan,
)

# 局域网私有服务，前端可能跑在别的端口（开发时 vite dev server），放开来源；
# 但凭据不放行 —— 令牌走 Authorization 头，浏览器不会替第三方站点带上。
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
    allow_credentials=False,
    expose_headers=["content-range", "accept-ranges", "x-run-id", "x-truncated"],
)

# 列表页 JSON 动辄几十 KB，压缩后能小一半以上
app.add_middleware(GZipMiddleware, minimum_size=1024)

app.include_router(auth_router.router, prefix="/api/v1")
app.include_router(fs_router.router, prefix="/api/v1")
app.include_router(search_router.router, prefix="/api/v1")
app.include_router(thumb_router.router, prefix="/api/v1")
app.include_router(play_router.router, prefix="/api/v1/play")
# 对话沿用 /hermes/api/* 这套路径（前端就是这么写的，别改）
app.include_router(chat_router.router, prefix="/hermes/api")



# ─────────────────────────────────────────────────────────────────────────────
# 顺手把编译好的网页端也发出去（web/dist 存在时）：单容器部署就不用再挂 nginx。
# 路由是先注册先匹配，所以 /api、/hermes 不会被这个静态挂载抢走。
# ─────────────────────────────────────────────────────────────────────────────
def _mount_web(app_: FastAPI) -> None:
    from pathlib import Path

    from fastapi.responses import FileResponse
    from fastapi.staticfiles import StaticFiles

    candidates = [CFG.web_dir] if CFG.web_dir else []
    candidates += [str(Path(__file__).resolve().parent.parent.parent / "web" / "dist")]
    dist = next((Path(c) for c in candidates if c and (Path(c) / "index.html").is_file()), None)
    if dist is None:
        return

    class SPA(StaticFiles):
        async def get_response(self, path, scope):        # type: ignore[override]
            try:
                return await super().get_response(path, scope)
            except Exception:                              # noqa: BLE001
                return FileResponse(dist / "index.html")

    app_.mount("/", SPA(directory=str(dist), html=True), name="web")
    import logging

    logging.getLogger("yunxia").info("静态前端：%s", dist)


@app.get("/api/v1/meta/sources", tags=["meta"])
def sources(device: Device) -> dict:
    """给前端用的来源列表：哪个能写，前端据此决定显不显示上传/删除。"""
    out = []
    for s in CFG.sources:
        if not s.enabled:
            continue
        writable = s.writable and s.kind in ("local", "dufs", "webdav")
        out.append({
            "id": s.id, "name": s.name, "sub": s.subtitle or "",
            "kind": s.kind, "writable": writable, "root": s.root,
            "local": s.kind == "local",
        })
    return {
        "sources": out,
        "default": CFG.default_source,
        "chat": {"enabled": bool(CFG.chat.enabled and CFG.chat.api_key and CFG.chat.base)},
    }


@app.get("/api/v1/meta/storage", tags=["meta"])
def storage() -> dict:
    """共享盘容量（首页容量卡）：只有本地源才有真实磁盘容量。"""
    import os

    for s in CFG.sources:
        if s.enabled and s.kind == "local":
            st = os.statvfs(s.resolved_root())
            total = st.f_frsize * st.f_blocks
            free = st.f_frsize * st.f_bavail
            return {"total": total, "free": free, "used": total - free,
                    "root": s.root, "source": s.id}
    return {"total": 0, "free": 0, "used": 0, "root": "", "source": ""}


@app.get("/api/v1/healthz", tags=["meta"])
def healthz() -> dict:
    return {
        "ok": True,
        "version": APP_VERSION,
        "uptime": round(time.time() - STARTED_AT, 1),
        "sources": [s.id for s in CFG.sources if s.enabled],
        "chat": bool(CFG.chat.enabled),
    }


# ─────────────────────────────────────────────────────────────────────────────
# 首页「储存占用 + 文件分析」卡：磁盘容量 + 按类型统计
# 遍历异步跑 + 落盘缓存（6 小时），过期后台重扫，接口立刻返回旧值。
# ─────────────────────────────────────────────────────────────────────────────
_KIND_EXT = {
    "video": "mp4 mkv avi mov wmv flv ts m2ts mts webm rmvb rm m4v mpg mpeg vob 3gp",
    "image": "jpg jpeg png gif webp bmp heic heif avif tif tiff svg",
    "audio": "mp3 flac wav aac m4a ogg opus wma ape alac dff dsf",
    "doc": "pdf doc docx xls xlsx ppt pptx txt md rst epub mobi azw3 csv",
    "archive": "zip rar 7z tar gz bz2 xz zst iso apk",
    "code": "js ts jsx tsx vue py html htm css scss json yml yaml sh bat ps1 java kt dart go rs c h cpp hpp sql toml ini",
}
_EXT2KIND = {e: k for k, exts in _KIND_EXT.items() for e in exts.split()}
_KIND_ORDER = ["video", "image", "audio", "doc", "archive", "code", "other"]

_scan_state = {"running": False, "source": None}
_scan_lock = __import__("threading").Lock()


def _cache_path(source_id: str) -> str:
    return str(Path_join(CFG.data_path, f"analysis-cache-{source_id}.json"))


def Path_join(base, name) -> str:
    import os

    return os.path.join(str(base), name)


def _walk_analysis(root: str) -> dict:
    import os
    import time as _t

    t0 = _t.time()
    by_kind = {k: {"kind": k, "count": 0, "bytes": 0} for k in _KIND_ORDER}
    files = dirs = 0
    total = 0
    top: dict[str, int] = {}
    for dirpath, dirnames, filenames in os.walk(root, onerror=lambda e: None):
        dirs += len(dirnames)
        rel = os.path.relpath(dirpath, root).split(os.sep)[0]
        for f in filenames:
            p = os.path.join(dirpath, f)
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if not os.path.isfile(p):
                continue
            size = st.st_size
            files += 1
            total += size
            ext = os.path.splitext(f)[1].lower().lstrip(".")
            kind = _EXT2KIND.get(ext, "other")
            by_kind[kind]["count"] += 1
            by_kind[kind]["bytes"] += size
            if rel not in (".", ""):
                top[rel] = top.get(rel, 0) + size
    return {
        "files": files, "dirs": dirs, "bytes": total,
        "by_kind": [by_kind[k] for k in _KIND_ORDER],
        "top_dirs": [{"name": n, "bytes": b} for n, b in
                     sorted(top.items(), key=lambda x: -x[1])[:5]],
        "elapsed": round(_t.time() - t0, 2),
    }


def _scan_worker(root: str, source_id: str) -> None:
    import json
    import logging
    import os
    import time as _t

    try:
        data = _walk_analysis(root)
        data["scanned_at"] = _t.time()
        data["root"] = root
        tmp = _cache_path(source_id) + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, ensure_ascii=False)
        os.replace(tmp, _cache_path(source_id))
    except Exception:  # noqa: BLE001
        logging.getLogger("yunxia").exception("analysis scan failed for %s", root)
    finally:
        with _scan_lock:
            _scan_state["running"] = False
            _scan_state["source"] = None


@app.get("/api/v1/meta/storage/analysis", tags=["meta"])
def storage_analysis(source: str = "") -> dict:
    """首页储存卡：磁盘容量 + 当前来源的文件类型分析（只对本地源有效）。"""
    import json
    import os
    import threading
    import time as _t

    sid = source or CFG.default_source
    try:
        src = CFG.source(sid)
    except KeyError:
        return {"source": sid, "ok": False, "note": "没有这个来源"}

    local = src.kind == "local"
    root = src.resolved_root() if local else None
    disk = None
    if local and os.path.isdir(root):
        st = os.statvfs(root)
        total = st.f_frsize * st.f_blocks
        free = st.f_frsize * st.f_bavail
        disk = {"total": total, "free": free, "used": total - free, "root": root}

    scan = None
    stale = True
    busy = False
    if local and disk is not None:
        try:
            with open(_cache_path(sid), encoding="utf-8") as fh:
                scan = json.load(fh)
            stale = (_t.time() - float(scan.get("scanned_at") or 0)) > 6 * 3600
        except (OSError, ValueError):
            scan = None
            stale = True
        if stale:
            with _scan_lock:
                busy = _scan_state["running"] and _scan_state["source"] == sid
                if not busy:
                    _scan_state["running"] = True
                    _scan_state["source"] = sid
                    threading.Thread(target=_scan_worker, args=(root, sid),
                                     daemon=True).start()
                    busy = True

    return {
        "source": sid, "name": src.name, "kind": src.kind, "local": local,
        "disk": disk, "scan": scan, "scanning": bool(busy), "stale": bool(stale),
        "note": "" if local else "云端 / 中转来源，不统计本地磁盘",
    }


# 静态挂载必须放在所有路由注册完之后：Starlette 按注册顺序匹配，
# 先挂 "/" 会把后面定义的 /api/* 全吃掉（fetch 回的是 index.html，不会报错）。
_mount_web(app)

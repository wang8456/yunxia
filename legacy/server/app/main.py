"""云匣统一 API（FastAPI）。

一个进程只做控制面：认证、目录、搜索、进度、任务、WebSocket。
文件字节不走这里 —— 客户端拿直链去 dufs 自己拉，
实测直连 34MB/s，走 API 中转只有 14MB/s。
"""

from __future__ import annotations

import time

from fastapi import FastAPI

from .auth import Device
from .config import CFG
from .routers import (auth, fs, play as play_router, search as search_router,
                      subs as subs_router, tasks as tasks_router,
                      thumb as thumb_router, ws)

APP_VERSION = "0.7.2"
STARTED_AT = time.time()

app = FastAPI(
    title="云匣 API",
    version=APP_VERSION,
    description="云匣多端统一接口。契约由本服务的 openapi.json 提供，前端不手写类型。",
    docs_url="/api/v1/docs",
    openapi_url="/api/v1/openapi.json",
    redoc_url=None,
)

# CORS：Flutter Web 预览版要从 localhost 调 5007；局域网私有服务，放开来源即可，
# 但凭据不放行（令牌走 Authorization 头，浏览器不会替第三方站点带上）。
from fastapi.middleware.cors import CORSMiddleware  # noqa: E402

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
    allow_credentials=False,
    expose_headers=["content-range", "accept-ranges", "x-truncated"],
)

app.include_router(auth.router, prefix="/api/v1")
app.include_router(fs.router, prefix="/api/v1")
app.include_router(search_router.router, prefix="/api/v1")
app.include_router(tasks_router.router, prefix="/api/v1")
app.include_router(subs_router.router, prefix="/api/v1")   # 听译（subs-hub 5092）
app.include_router(thumb_router.router, prefix="/api/v1")
app.include_router(play_router.router, prefix="/api/v1/play")  # 图片缩略图
app.include_router(ws.router)   # 路径就是 /ws，由 5007 前置直接转向本服务


@app.on_event("startup")
def _startup() -> None:
    """启动就把索引跑起来（后台线程），顺带把 inotify 事件接进索引。"""
    from .indexer import full_scan, index_event
    from .routers.ws import BUS

    BUS.hooks.append(index_event)
    full_scan(blocking=False)


@app.get("/api/v1/meta/sources", tags=["meta"])
def sources(device: Device) -> dict:
    """给多端前端用的源列表：哪个能写、哪个只读，前端据此决定显不显示上传/删除。"""
    out = []
    for s in CFG.sources:
        if not s.enabled:
            continue
        writable = s.kind not in ("relay115", "webdav")   # 115 中转与 webdav 目前只有读接口
        out.append({"id": s.id, "name": s.name, "writable": writable, "root": s.root})
    return {"sources": out, "default": out[0]["id"] if out else "nas"}


@app.get("/api/v1/meta/storage", tags=["meta"])
def storage() -> dict:
    """共享盘容量（首页容量卡）。statvfs 在 NAS 上是 ext4，单位是字节。"""
    import os

    st = os.statvfs(CFG.data_root)
    total = st.f_frsize * st.f_blocks
    free = st.f_frsize * st.f_bavail
    return {"total": total, "free": free, "used": total - free,
            "root": CFG.data_root}


@app.get("/api/v1/healthz", tags=["meta"])
def healthz() -> dict:
    return {
        "ok": True,
        "version": APP_VERSION,
        "uptime": round(time.time() - STARTED_AT, 1),
        "data_root": CFG.data_root,
        "sources": [s.id for s in CFG.sources if s.enabled],
    }

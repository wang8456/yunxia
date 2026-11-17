"""来源注册表：id → 适配器实例（按需构造，失败不影响别的源）。"""

from __future__ import annotations

import logging

from ..config import CFG, Source
from .base import Adapter, clean_path, join
from .local_fs import LocalFS

log = logging.getLogger("yunxia.adapters")

_cache: dict[str, Adapter] = {}


def get_source(source_id: str) -> Source:
    for s in CFG.sources:
        if s.id == source_id:
            return s
    raise KeyError(source_id)


def get_adapter(source_id: str) -> Adapter:
    if source_id in _cache:
        return _cache[source_id]
    src = get_source(source_id)
    if src.kind in ("dufs", "local"):
        # NAS 共享盘走本地文件系统；远端 dufs（电脑）在 P2 后期接 HTTP 版
        ad: Adapter = LocalFS(src)
    elif src.kind in ("webdav", "relay115"):
        from .webdav import WebDAV

        ad = WebDAV(src)
    else:
        from .remote_dufs import RemoteDufs

        ad = RemoteDufs(src)
    _cache[source_id] = ad
    return ad


__all__ = ["Adapter", "LocalFS", "clean_path", "join", "get_adapter", "get_source"]

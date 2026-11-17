"""来源注册表：id → 适配器实例（按需构造，失败不影响别的源）。"""

from __future__ import annotations

import logging

from ..config import CFG, Source
from .base import Adapter, clean_path, join
from .local_fs import LocalFS

log = logging.getLogger("yunxia.adapters")

_cache: dict[str, Adapter] = {}


def get_source(source_id: str) -> Source:
    try:
        return CFG.source(source_id)
    except KeyError:
        raise KeyError(source_id)


def get_adapter(source_id: str) -> Adapter:
    if source_id in _cache:
        return _cache[source_id]
    src = get_source(source_id)
    ad: Adapter
    if src.kind == "local":
        ad = LocalFS(src)
    elif src.kind == "webdav":
        from .webdav import WebDAV

        ad = WebDAV(src)
    elif src.kind == "dufs":
        from .remote_dufs import RemoteDufs

        ad = RemoteDufs(src)
    else:
        raise KeyError(f"未知来源类型：{src.kind}")
    _cache[source_id] = ad
    return ad


def reset_cache() -> None:
    """改完配置（重新加载）后清一下缓存的适配器。"""
    _cache.clear()


__all__ = ["Adapter", "LocalFS", "clean_path", "join", "get_adapter", "get_source", "reset_cache"]

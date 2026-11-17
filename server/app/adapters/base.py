"""来源适配层：本地磁盘 / 远端 dufs / 标准 WebDAV —— 对外都是同一组方法。

写操作一律做路径校验：任何 ".."、绝对路径逃逸都直接 400。
"""

from __future__ import annotations

import os
import posixpath
from abc import ABC, abstractmethod

from ..config import Source
from ..models import FileEntry


def clean_path(path: str) -> str:
    """规范化成源内绝对路径；拒绝任何 ".." 段（不做静默折叠）。"""
    if not path:
        return "/"
    path = path.replace("\\", "/")
    if "\x00" in path:
        raise ValueError("非法路径")
    segs = [s for s in path.split("/") if s not in ("", ".")]
    if any(s == ".." for s in segs):
        raise ValueError("非法路径")
    return "/" + "/".join(segs)


def join(parent: str, name: str) -> str:
    if not name or "/" in name or name in (".", ".."):
        raise ValueError("非法文件名")
    return clean_path(posixpath.join(clean_path(parent), name))


class Adapter(ABC):
    source: Source

    @abstractmethod
    def list(self, path: str) -> tuple[list[FileEntry], dict]: ...

    @abstractmethod
    def stat(self, path: str) -> FileEntry: ...

    @abstractmethod
    def mkdir(self, path: str) -> None: ...

    @abstractmethod
    def move(self, src: str, dst: str) -> None: ...

    @abstractmethod
    def delete(self, path: str) -> None: ...

    @abstractmethod
    def write_stream(self, path: str, fileobj) -> int: ...

    @abstractmethod
    def read_head(self, path: str, n: int = 262144) -> bytes: ...

    @abstractmethod
    def raw_request(self, path: str, range_header: str | None = None):
        """远端源用：返回 (status, headers, iterator, closer)，供 /fs/raw 代理。"""

    @abstractmethod
    def abs_path(self, path: str) -> str | None:
        """本地源返回磁盘路径，远端源返回 None。"""

"""115 网盘：经 NAS 上 5008 的中转（不是标准 WebDAV，只有三个接口）。

实测契约：
  GET /ping            → 200
  GET /list?p=/路径     → {"p": "/", "items": [{"n": 名称, "d": 0|1, "s": 字节, "m": 毫秒}]}
  GET /file?p=/路径     → 文件字节，**支持 Range（206）**

只读：中转没有写接口，上传/改名/删除一律明确报错，不要假装支持。
"""

from __future__ import annotations

import posixpath
import urllib.parse

import httpx

from ..config import Source
from ..models import FileEntry, kind_of
from .base import Adapter, clean_path

TIMEOUT = httpx.Timeout(15.0, read=120.0)


class WebDAV(Adapter):
    """类名沿用 base 里的约定；实际是 115 中转适配器。"""

    def __init__(self, source: Source):
        self.source = source
        self.base = source.base.rstrip("/")

    def _readonly(self, what: str):
        raise PermissionError(f"115 网盘是只读的（中转没提供{what}接口）")

    def _q(self, path: str) -> str:
        return urllib.parse.quote(clean_path(path))

    def list(self, path: str) -> tuple[list[FileEntry], dict]:
        with httpx.Client(timeout=TIMEOUT) as c:
            r = c.get(f"{self.base}/list", params={"p": clean_path(path)})
            r.raise_for_status()
            data = r.json()
        entries = []
        for it in data.get("items", []):
            name = it["n"]
            is_dir = bool(it.get("d"))
            entries.append(FileEntry(
                name=name,
                path=posixpath.join(clean_path(path), name),
                is_dir=is_dir,
                size=0 if is_dir else int(it.get("s") or 0),
                mtime=(it.get("m") or 0) / 1000.0,
                kind=kind_of(name, is_dir),
                ext=posixpath.splitext(name)[1].lower().lstrip("."),
            ))
        entries.sort(key=lambda e: (not e.is_dir, e.name.lower()))
        return entries, {"allow_upload": False, "allow_delete": False}

    def stat(self, path: str) -> FileEntry:
        p = clean_path(path)
        if p == "/":
            return FileEntry(name="/", path="/", is_dir=True, kind="dir")
        parent, name = posixpath.split(p)
        for e in self.list(parent or "/")[0]:
            if e.name == name:
                return e
        raise FileNotFoundError(path)

    def mkdir(self, path: str) -> None:
        self._readonly("建目录")

    def move(self, src: str, dst: str) -> None:
        self._readonly("改名/移动")

    def delete(self, path: str) -> None:
        self._readonly("删除")

    def write_stream(self, path: str, fileobj) -> int:
        self._readonly("上传")

    def read_head(self, path: str, n: int = 262144) -> bytes:
        with httpx.Client(timeout=TIMEOUT) as c:
            r = c.get(f"{self.base}/file", params={"p": clean_path(path)},
                      headers={"Range": f"bytes=0-{n - 1}"})
            r.raise_for_status()
            return r.content[:n]

    def raw_request(self, path: str, range_header: str | None = None):
        c = httpx.Client(timeout=TIMEOUT)
        headers = {"Range": range_header} if range_header else {}
        req = c.build_request("GET", f"{self.base}/file",
                              params={"p": clean_path(path)}, headers=headers)
        r = c.send(req, stream=True)
        return r.status_code, dict(r.headers), r.iter_bytes(1 << 16), (c, r)

    def abs_path(self, path: str) -> str | None:
        return None

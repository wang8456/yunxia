"""远端 dufs（电脑上的那两台，经 pcproxy 5010/5011）—— 走 HTTP。

dufs 0.46 的怪癖都在这里吸收掉：
  * 列目录路径必须带尾斜杠，否则返回 HTML
  * 建目录用 MKCOL，PUT 带尾斜杠会建出 0 字节文件
  * MOVE 的 Destination 必须是绝对 URL
  * PUT 必须带 Content-Length
"""

from __future__ import annotations

import posixpath
import urllib.parse

import httpx

from ..config import Source
from ..models import FileEntry, kind_of
from .base import Adapter, clean_path

TIMEOUT = httpx.Timeout(15.0, read=120.0)


class RemoteDufs(Adapter):
    def __init__(self, source: Source):
        self.source = source
        self.base = source.base.rstrip("/")
        self.auth = (source.user, source.password) if source.user else None

    # ---------- 内部 ----------
    def _client(self) -> httpx.Client:
        return httpx.Client(base_url=self.base, auth=self.auth, timeout=TIMEOUT,
                            follow_redirects=True)

    def _url(self, path: str) -> str:
        p = clean_path(path)
        return urllib.parse.quote(p) if p != "/" else "/"

    def _entry(self, parent: str, item: dict) -> FileEntry:
        name = item["name"]
        is_dir = item.get("path_type") in ("Dir", "SymlinkDir")
        return FileEntry(
            name=name,
            path=posixpath.join(clean_path(parent), name),
            is_dir=is_dir,
            size=0 if is_dir else int(item.get("size") or 0),
            mtime=(item.get("mtime") or 0) / 1000.0,
            kind=kind_of(name, is_dir),
            ext=posixpath.splitext(name)[1].lower().lstrip("."),
        )

    # ---------- 接口 ----------
    def list(self, path: str) -> tuple[list[FileEntry], dict]:
        url = self._url(path)
        if not url.endswith("/"):
            url += "/"
        with self._client() as c:
            r = c.get(url, params={"json": ""})
            r.raise_for_status()
            data = r.json()
        if data.get("kind") != "Index":
            raise FileNotFoundError(path)
        entries = [self._entry(path, p) for p in data.get("paths", [])]
        entries.sort(key=lambda e: (not e.is_dir, e.name.lower()))
        return entries, {"allow_upload": bool(data.get("allow_upload")),
                         "allow_delete": bool(data.get("allow_delete"))}

    def stat(self, path: str) -> FileEntry:
        p = clean_path(path)
        if p == "/":
            return FileEntry(name="/", path="/", is_dir=True, kind="dir")
        parent, name = posixpath.split(p)
        entries, _ = self.list(parent or "/")
        for e in entries:
            if e.name == name:
                return e
        raise FileNotFoundError(path)

    def mkdir(self, path: str) -> None:
        with self._client() as c:
            r = c.request("MKCOL", self._url(path) + "/" if not self._url(path).endswith("/") else self._url(path))
            if r.status_code not in (200, 201, 204, 405):   # 405 = 已存在
                r.raise_for_status()

    def move(self, src: str, dst: str) -> None:
        with self._client() as c:
            r = c.request("MOVE", self._url(src), headers={
                "Destination": f"{self.base}{self._url(dst)}",
                "Overwrite": "F",
            })
            r.raise_for_status()

    def delete(self, path: str) -> None:
        with self._client() as c:
            r = c.delete(self._url(path))
            if r.status_code == 404:
                raise FileNotFoundError(path)
            r.raise_for_status()

    def write_stream(self, path: str, fileobj) -> int:
        data = fileobj.read()
        with self._client() as c:
            r = c.put(self._url(path), content=data,
                      headers={"Content-Length": str(len(data))})
            r.raise_for_status()
        return len(data)

    def read_head(self, path: str, n: int = 262144) -> bytes:
        with self._client() as c:
            r = c.get(self._url(path), headers={"Range": f"bytes=0-{n - 1}"})
            r.raise_for_status()
            return r.content[:n]

    def raw_request(self, path: str, range_header: str | None = None):
        c = self._client()
        headers = {"Range": range_header} if range_header else {}
        req = c.build_request("GET", self._url(path), headers=headers)
        r = c.send(req, stream=True)
        return r.status_code, dict(r.headers), r.iter_bytes(1 << 16), (c, r)

    def abs_path(self, path: str) -> str | None:
        return None

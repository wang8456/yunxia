"""标准 WebDAV 适配器（CloudDrive2 / Alist / Nextcloud / Nginx-dav 都能用）。

只用最基础的一组方法，兼容性最好：

  * 列目录 / 取属性：``PROPFIND``（Depth: 1 / 0）
  * 建目录：``MKCOL``
  * 改名 / 移动：``MOVE``（Destination 用绝对 URL）
  * 删除：``DELETE``
  * 上传：``PUT``（显式 Content-Length，不用 chunked）
  * 读取：``GET``（透传 Range，播放器要 206）

CloudDrive2 的 WebDAV 入口默认在 ``http://<host>:19798/dav``，
账号密码就是 CloudDrive2 里配的那套（见 docs/storage-webdav.md）。
"""

from __future__ import annotations

import posixpath
import urllib.parse
import xml.etree.ElementTree as ET
from email.utils import parsedate_to_datetime

import httpx

from ..config import Source
from ..models import FileEntry, kind_of
from .base import Adapter, clean_path

TIMEOUT = httpx.Timeout(20.0, read=180.0)
DAV = "{DAV:}"
PROPFIND_BODY = (
    '<?xml version="1.0" encoding="utf-8"?>'
    '<d:propfind xmlns:d="DAV:"><d:prop>'
    "<d:displayname/><d:resourcetype/><d:getcontentlength/>"
    "<d:getlastmodified/><d:getcontenttype/>"
    "</d:prop></d:propfind>"
)


def _http_date(value: str | None) -> float:
    if not value:
        return 0.0
    try:
        return parsedate_to_datetime(value).timestamp()
    except (TypeError, ValueError):
        return 0.0


class WebDAV(Adapter):
    def __init__(self, source: Source):
        self.source = source
        self.base = source.base.rstrip("/")
        self.auth = (source.user, source.password) if source.user else None
        # base 里带的前缀（比如 /dav），用来把服务器返回的 href 换算回源内路径
        self.prefix = urllib.parse.urlparse(self.base).path.rstrip("/")

    # ---------- 内部 ----------
    def _client(self) -> httpx.Client:
        # trust_env=False：别让环境里的 http_proxy 把内网请求带进代理
        return httpx.Client(auth=self.auth, timeout=TIMEOUT,
                            follow_redirects=True, trust_env=False)

    def _url(self, path: str) -> str:
        p = clean_path(path)
        quoted = urllib.parse.quote(p, safe="/")
        return self.base + (quoted if quoted != "/" else "/")

    def _rel(self, href: str) -> str:
        """把 PROPFIND 回来的 href 换算成源内路径。"""
        parsed = urllib.parse.urlparse(href)
        path = urllib.parse.unquote(parsed.path)
        if self.prefix and path.startswith(self.prefix):
            path = path[len(self.prefix):]
        path = "/" + path.strip("/")
        return path or "/"

    def _raise(self, r: httpx.Response) -> None:
        if r.status_code in (401, 403):
            raise PermissionError("WebDAV 用户名或口令不对")
        if r.status_code == 404:
            raise FileNotFoundError("路径不存在")
        r.raise_for_status()

    def _propfind(self, path: str, depth: int) -> list[ET.Element]:
        url = self._url(path)
        if depth >= 1 and not url.endswith("/"):
            url += "/"
        with self._client() as c:
            r = c.request("PROPFIND", url, content=PROPFIND_BODY.encode(),
                          headers={"Depth": str(depth),
                                   "Content-Type": 'application/xml; charset="utf-8"'})
        self._raise(r)
        if r.status_code not in (200, 207):
            raise FileNotFoundError(path)
        try:
            root = ET.fromstring(r.content)
        except ET.ParseError as exc:
            raise RuntimeError(f"WebDAV 返回的不是合法 XML：{exc}") from exc
        return root.findall(f"{DAV}response")

    def _entry(self, node: ET.Element) -> FileEntry | None:
        href = node.findtext(f"{DAV}href") or ""
        if not href:
            return None
        prop = node.find(f"{DAV}propstat/{DAV}prop")
        if prop is None:
            prop = node.find(f"{DAV}prop")
        if prop is None:
            return None
        path = self._rel(href)
        name = posixpath.basename(path.rstrip("/")) or "/"
        rt = prop.find(f"{DAV}resourcetype")
        is_dir = rt is not None and rt.find(f"{DAV}collection") is not None
        size = int(prop.findtext(f"{DAV}getcontentlength") or 0)
        mtime = _http_date(prop.findtext(f"{DAV}getlastmodified"))
        return FileEntry(
            name=name, path=path, is_dir=is_dir,
            size=0 if is_dir else size, mtime=mtime,
            kind=kind_of(name, is_dir),
            ext=posixpath.splitext(name)[1].lower().lstrip("."),
        )

    # ---------- 接口 ----------
    def list(self, path: str) -> tuple[list[FileEntry], dict]:
        p = clean_path(path)
        nodes = self._propfind(p, 1)
        out: list[FileEntry] = []
        for node in nodes:
            e = self._entry(node)
            # 第一项是目录自己，跳过
            if e is None or e.path.rstrip("/") == p.rstrip("/"):
                continue
            out.append(e)
        out.sort(key=lambda x: (not x.is_dir, x.name.lower()))
        allow = bool(self.source.writable)
        return out, {"allow_upload": allow, "allow_delete": allow}

    def stat(self, path: str) -> FileEntry:
        p = clean_path(path)
        nodes = self._propfind(p, 0)
        for node in nodes:
            e = self._entry(node)
            if e is not None:
                return e
        raise FileNotFoundError(path)

    def mkdir(self, path: str) -> None:
        url = self._url(path)
        if not url.endswith("/"):
            url += "/"
        with self._client() as c:
            r = c.request("MKCOL", url)
            if r.status_code == 405:      # 已存在
                return
            self._raise(r)

    def move(self, src: str, dst: str) -> None:
        with self._client() as c:
            r = c.request("MOVE", self._url(src), headers={
                "Destination": self._url(dst),
                "Overwrite": "T",
            })
            self._raise(r)

    def delete(self, path: str) -> None:
        with self._client() as c:
            r = c.delete(self._url(path))
            self._raise(r)

    def write_stream(self, path: str, fileobj) -> int:
        fh = fileobj
        cur = fh.tell()
        fh.seek(0, 2)
        total = fh.tell() - cur
        fh.seek(cur)

        def chunks():
            while True:
                b = fh.read(1 << 20)
                if not b:
                    break
                yield b

        with self._client() as c:
            r = c.put(self._url(path), content=chunks(),
                      headers={"Content-Length": str(total)})
            self._raise(r)
        return total

    def read_head(self, path: str, n: int = 262144) -> bytes:
        with self._client() as c:
            r = c.get(self._url(path), headers={"Range": f"bytes=0-{n - 1}"})
            self._raise(r)
            return r.content[:n]

    def raw_request(self, path: str, range_header: str | None = None):
        c = self._client()
        headers = {"Range": range_header} if range_header else {}
        req = c.build_request("GET", self._url(path), headers=headers)
        r = c.send(req, stream=True)
        return r.status_code, dict(r.headers), r.iter_raw(1 << 20), (c, r)

    def abs_path(self, path: str) -> str | None:
        return None

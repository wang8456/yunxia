"""NAS 共享盘适配器：直接读写本地文件系统。"""

from __future__ import annotations

import os
import posixpath

from ..config import Source
from ..models import FileEntry
from .base import Adapter, clean_path


class LocalFS(Adapter):
    """NAS 共享盘：直接读写本地文件系统。

    列目录/读写不走 dufs —— 同一个文件系统，直连更快也更稳；
    对外下载仍然由 dufs 出字节（Range、断点续传都是它实现的）。
    """

    def __init__(self, source: Source, hide_dotfiles: bool = True):
        self.source = source
        self.root = source.root or "/"
        self.hide_dotfiles = hide_dotfiles

    def abs_path(self, path: str) -> str:
        return os.path.join(self.root, clean_path(path).lstrip("/"))

    def _entry(self, directory: str, name: str, st: os.stat_result):
        from ..models import kind_of

        is_dir = os.path.isdir(os.path.join(directory, name))
        return FileEntry(
            name=name,
            path=posixpath.join(clean_path(self._rel(directory)), name),
            is_dir=is_dir,
            size=0 if is_dir else st.st_size,
            mtime=st.st_mtime,
            kind=kind_of(name, is_dir),
            ext=os.path.splitext(name)[1].lower().lstrip("."),
        )

    def _rel(self, abs_dir: str) -> str:
        rel = os.path.relpath(abs_dir, self.root)
        return "/" if rel == "." else "/" + rel.replace(os.sep, "/")

    def list(self, path: str) -> tuple[list[FileEntry], dict]:
        target = self.abs_path(path)
        if not os.path.isdir(target):
            raise FileNotFoundError(path)
        out: list[FileEntry] = []
        with os.scandir(target) as it:
            for e in it:
                if self.hide_dotfiles and e.name.startswith("."):
                    continue
                try:
                    st = e.stat()
                except OSError:
                    continue
                out.append(self._entry(target, e.name, st))
        out.sort(key=lambda x: (not x.is_dir, x.name.lower()))
        return out, {"allow_upload": True, "allow_delete": True}

    def stat(self, path: str) -> FileEntry:
        from ..models import kind_of

        target = self.abs_path(path)
        st = os.stat(target)
        name = os.path.basename(target.rstrip("/")) or "/"
        is_dir = os.path.isdir(target)
        return FileEntry(
            name=name, path=clean_path(path), is_dir=is_dir,
            size=0 if is_dir else st.st_size, mtime=st.st_mtime,
            kind=kind_of(name, is_dir), ext=os.path.splitext(name)[1].lower().lstrip("."),
        )

    def mkdir(self, path: str) -> None:
        os.makedirs(self.abs_path(path), exist_ok=True)

    def move(self, src: str, dst: str) -> None:
        import shutil

        s, d = self.abs_path(src), self.abs_path(dst)
        parent = os.path.dirname(d)
        if parent:
            os.makedirs(parent, exist_ok=True)
        shutil.move(s, d)

    def delete(self, path: str) -> None:
        import shutil

        target = self.abs_path(path)
        if target.rstrip("/") == self.root.rstrip("/"):
            raise ValueError("不能删根目录")
        if os.path.isdir(target):
            shutil.rmtree(target)
        elif os.path.exists(target):
            os.remove(target)
        else:
            raise FileNotFoundError(path)

    def write_stream(self, path: str, fileobj) -> int:
        target = self.abs_path(path)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        size = 0
        tmp = target + ".part"
        with open(tmp, "wb") as fh:
            while True:
                chunk = fileobj.read(1 << 20)
                if not chunk:
                    break
                fh.write(chunk)
                size += len(chunk)
        os.replace(tmp, target)   # 写完才出现，避免半个文件被别人看到
        return size

    def raw_request(self, path: str, range_header: str | None = None):
        raise NotImplementedError("本地源请用 /f/ 直链，不经过 API 中转")

    def read_head(self, path: str, n: int = 262144) -> bytes:
        with open(self.abs_path(path), "rb") as fh:
            return fh.read(n)

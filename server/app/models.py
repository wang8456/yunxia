"""对外的数据模型（= 契约）。改了这里等于改 API，前端类型要跟着改。"""

from __future__ import annotations

import os
from typing import Literal

from pydantic import BaseModel, Field

Kind = Literal["dir", "image", "video", "audio", "pdf", "text", "archive", "code", "file"]

_EXT_KIND = {
    "image": {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".avif", ".heic", ".svg", ".ico"},
    "video": {".mp4", ".mkv", ".mov", ".avi", ".webm", ".ts", ".m4v", ".flv", ".wmv", ".rmvb"},
    "audio": {".mp3", ".flac", ".wav", ".aac", ".m4a", ".ogg", ".opus", ".ape", ".wma"},
    "pdf": {".pdf"},
    "text": {".txt", ".md", ".log", ".csv", ".json", ".yml", ".yaml", ".ini", ".conf", ".xml"},
    "code": {".py", ".js", ".ts", ".vue", ".java", ".kt", ".go", ".rs", ".c", ".h", ".cpp",
             ".css", ".scss", ".html", ".sh", ".sql", ".dart", ".swift"},
    "archive": {".zip", ".rar", ".7z", ".tar", ".gz", ".xz", ".bz2", ".iso", ".tgz"},
}


def kind_of(name: str, is_dir: bool) -> Kind:
    if is_dir:
        return "dir"
    ext = os.path.splitext(name)[1].lower()
    for k, exts in _EXT_KIND.items():
        if ext in exts:
            return k  # type: ignore[return-value]
    return "file"


class FileEntry(BaseModel):
    name: str
    path: str = Field(description="源内绝对路径，以 / 开头")
    is_dir: bool
    size: int = 0
    mtime: float = Field(0.0, description="秒级时间戳")
    kind: Kind = "file"
    ext: str = ""


class ListOut(BaseModel):
    source: str
    path: str
    parent: str | None
    entries: list[FileEntry]
    allow_upload: bool = False
    allow_delete: bool = False
    truncated: bool = False


class LinkOut(BaseModel):
    url: str = Field(description="带签名的直链（相对路径），客户端直接拿它下文件（走 Range）")
    expires: int
    size: int = 0

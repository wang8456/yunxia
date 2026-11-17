"""配置：一个 JSON 文件，路径由 YUNXIA_CONFIG 决定（默认 NAS 上的那份）。"""

from __future__ import annotations

import json
import os
from dataclasses import dataclass, field
from pathlib import Path

DEFAULT_PATH = os.environ.get("YUNXIA_CONFIG", "/mnt/data/home/yunxia-api/config.json")


@dataclass
class Source:
    id: str
    name: str
    kind: str                     # dufs | webdav | pcdufs
    base: str                     # http://127.0.0.1:15007
    user: str = ""
    password: str = ""
    root: str = "/"               # 在该源里的起始路径
    enabled: bool = True


@dataclass
class Config:
    data_root: str = "/mnt/data/share"     # 共享盘根（inotify 监听、索引都在这下面）
    dufs_base: str = "http://127.0.0.1:15007"
    db_path: str = "/mnt/data/home/yunxia-api/yunxia.db"
    token_secret_path: str = "/mnt/data/home/yunxia-api/token.secret"
    token_days: int = 30
    password_hash: str = ""       # 登录口令的 pbkdf2 哈希（空则退回源口令比对）
    password_salt: str = ""
    sources: list[Source] = field(default_factory=list)
    # 任务中心靠的两个下载中转（5094 磁力 / 5093 ed2k），都是本机 HTTP
    hubs: dict = field(default_factory=lambda: {
        "magnet": "http://127.0.0.1:5094",
        "ed2k": "http://127.0.0.1:5093",
        "subs": "http://127.0.0.1:5092",      # 听译中枢
    })
    # 给本机其它进程（电脑上的 asr-worker）用的对外地址，签发直链时要带它
    public_base: str = "http://192.168.1.10:5007"

    @property
    def token_secret(self) -> str:
        """首次运行时生成，之后固定（换掉它 = 所有设备登出）。"""
        p = Path(self.token_secret_path)
        if p.exists():
            return p.read_text().strip()
        import secrets
        secret = secrets.token_urlsafe(48)
        p.write_text(secret)
        p.chmod(0o600)
        return secret


def load(path: str | None = None) -> Config:
    path = path or DEFAULT_PATH
    p = Path(path)
    if not p.exists():
        return Config()
    raw = json.loads(p.read_text(encoding="utf-8"))
    srcs = [Source(**s) for s in raw.pop("sources", [])]
    return Config(sources=srcs, **raw)


CFG = load()

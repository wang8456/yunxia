"""配置加载。

一个 JSON 文件搞定全部配置，路径由环境变量 ``YUNXIA_CONFIG`` 指定（默认
``./config.json``）。首次启动时如果文件不存在，会自动用默认值生成一份，
让服务能直接跑起来（只有一个「本机储存」来源 + 空口令）。

口令有两种写法：

* 明文：``"password": "mypassword"``
* 哈希：``"password": "pbkdf2$<salt>$<hex>"``（用 ``python -m app.cli hash`` 生成，
  配置文件泄露时不会连口令一起泄露，推荐）
"""

from __future__ import annotations

import json
import os
import secrets
from dataclasses import dataclass, field
from pathlib import Path

CONFIG_PATH = os.environ.get("YUNXIA_CONFIG", "config.json")

ROOT = Path(__file__).resolve().parent.parent          # server/ 目录


def _abs(p: str) -> str:
    """相对路径一律相对 server/ 目录解析，避免被启动时的工作目录影响。"""
    path = Path(p).expanduser()
    return str(path if path.is_absolute() else (ROOT / path))


@dataclass
class Source:
    id: str
    name: str
    kind: str = "local"            # local | dufs | webdav
    base: str = ""                 # dufs / webdav 的服务地址
    user: str = ""
    password: str = ""
    root: str = "/"                # local: 磁盘目录；远端: 源内起始路径
    subtitle: str = ""
    writable: bool = True          # webdav 可单独设成只读
    enabled: bool = True

    def resolved_root(self) -> str:
        return _abs(self.root) if self.kind == "local" else (self.root or "/")


@dataclass
class ChatSettings:
    enabled: bool = False
    base: str = "https://api.deepseek.com/v1"    # 任意 OpenAI 兼容服务
    api_key: str = ""
    model: str = ""
    system: str = ""
    max_turns: int = 12
    timeout: float = 120.0


@dataclass
class SubsSettings:
    """听译：本机 faster-whisper 转写 + OpenAI 兼容翻译（默认关闭）。"""
    enabled: bool = False
    model: str = "base"              # tiny/base/small/medium/large-v3，或本地模型目录
    device: str = "auto"             # auto / cpu / cuda
    compute_type: str = "int8"       # int8 / int8_float16 / float16 / float32
    language: str = "auto"           # auto / zh / ja / en ...
    beam_size: int = 1
    vad: bool = True
    max_active: int = 1              # 同时转写几部
    model_dir: str = "./data/models"
    translate: dict = field(default_factory=dict)   # {base,api_key,model,to}

    @property
    def model_path(self) -> str:
        p = Path(_abs(self.model_dir))
        p.mkdir(parents=True, exist_ok=True)
        return str(p)

    def tr(self) -> dict:
        """翻译配置：没单独配就用 chat 那份（一条 Key 两处用）。"""
        out = {"base": self.translate.get("base") or "",
               "api_key": self.translate.get("api_key") or "",
               "model": self.translate.get("model") or "",
               "to": self.translate.get("to") or "zh"}
        ch = getattr(CFG, "chat", None)
        if ch is not None:
            out["base"] = out["base"] or ch.base
            out["api_key"] = out["api_key"] or ch.api_key
            out["model"] = out["model"] or ch.model
        return out

    @property
    def ready(self) -> bool:
        return bool(self.enabled)


@dataclass
class Config:
    host: str = "0.0.0.0"
    port: int = 8686
    public_base: str = ""          # 签直链时用的对外地址，留空则按请求头推断
    web_dir: str = ""              # 编译好的网页端目录（web/dist），留空则自动找 ../web/dist
    password: str = ""             # 空 = 只读（不需要登录，也不能上传/删除）
    data_dir: str = "./data"
    token_days: int = 30
    sources: list[Source] = field(default_factory=list)
    chat: ChatSettings = field(default_factory=ChatSettings)
    subs: SubsSettings = field(default_factory=SubsSettings)

    # ---- 派生路径 ----
    @property
    def data_path(self) -> Path:
        p = Path(_abs(self.data_dir))
        p.mkdir(parents=True, exist_ok=True)
        return p

    @property
    def db_path(self) -> str:
        return str(self.data_path / "yunxia.db")

    @property
    def secret_path(self) -> Path:
        return self.data_path / "token.secret"

    @property
    def thumb_dir(self) -> Path:
        p = self.data_path / "thumbs"
        p.mkdir(parents=True, exist_ok=True)
        return p

    @property
    def media_dir(self) -> Path:
        """对话附件落盘目录。"""
        p = self.data_path / "media"
        p.mkdir(parents=True, exist_ok=True)
        return p

    @property
    def subs_dir(self) -> Path:
        """听译任务与段落落盘目录。"""
        p = self.data_path / "subs"
        p.mkdir(parents=True, exist_ok=True)
        return p

    @property
    def tmp_dir(self) -> Path:
        p = self.data_path / "tmp"
        p.mkdir(parents=True, exist_ok=True)
        return p

    @property
    def token_secret(self) -> str:
        """首次运行时生成，之后固定（换掉它 = 所有设备登出）。"""
        p = self.secret_path
        if p.exists():
            return p.read_text(encoding="utf-8").strip()
        secret = secrets.token_urlsafe(48)
        p.write_text(secret, encoding="utf-8")
        try:
            p.chmod(0o600)
        except OSError:
            pass
        return secret

    def source(self, source_id: str) -> Source:
        for s in self.sources:
            if s.id == source_id:
                return s
        raise KeyError(source_id)

    @property
    def default_source(self) -> str:
        for s in self.sources:
            if s.enabled:
                return s.id
        return "local"


def _build(raw: dict) -> Config:
    server = raw.get("server") or {}
    auth = raw.get("auth") or {}
    paths = raw.get("paths") or {}
    cfg = Config(
        host=server.get("host", "0.0.0.0"),
        port=int(server.get("port", 8686)),
        public_base=(server.get("public_base") or "").rstrip("/"),
        web_dir=server.get("web_dir") or "",
        password=auth.get("password") or "",
        data_dir=paths.get("data", "./data"),
        token_days=int(raw.get("token_days", 30)),
        sources=[Source(**s) for s in (raw.get("sources") or [])],
        chat=ChatSettings(**(raw.get("chat") or {})),
        subs=SubsSettings(**(raw.get("subs") or {})),
    )
    if not cfg.sources:
        # 没有任何来源时给一个能直接用的：./data/files
        default_root = cfg.data_path / "files"
        default_root.mkdir(parents=True, exist_ok=True)
        cfg.sources = [Source(id="local", name="本机储存", kind="local",
                              root=str(default_root), subtitle="服务器本机磁盘")]
    return cfg


def load(path: str | None = None) -> Config:
    p = Path(path or CONFIG_PATH)
    if not p.exists():
        example = ROOT / "config.example.json"
        if example.exists():
            p.write_text(example.read_text(encoding="utf-8"), encoding="utf-8")
    if not p.exists():
        return _build({})
    raw = json.loads(p.read_text(encoding="utf-8"))
    return _build(raw)


CFG = load()

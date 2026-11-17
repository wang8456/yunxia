"""服务端冒烟测试：``python -m pytest -q``（在 server/ 目录里跑）。

不碰网络：WebDAV 用 MockTransport，dufs 用同一套解析逻辑的 XML 夹具。
"""

from __future__ import annotations

import os
import tempfile

import pytest

# 必须在 import app.* 之前把配置指到一个临时目录
_TMP = tempfile.mkdtemp(prefix="yunxia-test-")
os.environ["YUNXIA_CONFIG"] = os.path.join(_TMP, "config.json")

from app import config as config_mod  # noqa: E402


def _write_config(**over) -> None:
    files = os.path.join(_TMP, "files")
    os.makedirs(files, exist_ok=True)
    with open(os.path.join(files, "hello.txt"), "w", encoding="utf-8") as fh:
        fh.write("hi")
    import json

    cfg = {
        "server": {"host": "127.0.0.1", "port": 0},
        "auth": {"password": "pw"},
        "paths": {"data": os.path.join(_TMP, "data")},
        "sources": [{"id": "local", "name": "本地", "kind": "local", "root": files}],
        "chat": {"enabled": False},
    }
    cfg.update(over)
    with open(os.environ["YUNXIA_CONFIG"], "w", encoding="utf-8") as fh:
        json.dump(cfg, fh)


_write_config()
# 注意：直接复用 import 时那个 CFG 对象（各模块都是 `from .config import CFG`
# 绑定的引用），把测试配置灌进它的属性里，否则改了密码/来源后各模块看到的还是旧值。
_loaded = config_mod.load(os.environ["YUNXIA_CONFIG"])
config_mod.CFG.__dict__.update(_loaded.__dict__)
CFG = config_mod.CFG


@pytest.fixture(scope="session", autouse=True)
def _patch_cfg():
    """确保 app.* 里各模块用的是同一个 CFG 对象（默认就是，这里只是兜底）。"""
    import app.adapters as adapters_mod
    import app.auth as auth_mod
    import app.db as db_mod
    import app.main as main_mod

    for mod in (auth_mod, db_mod, main_mod, adapters_mod, config_mod):
        mod.CFG = CFG
    adapters_mod.reset_cache()
    yield


def test_hash_and_verify():
    from app.auth import hash_password, verify_password

    original = CFG.password
    try:
        CFG.password = hash_password("s3cret")
        assert CFG.password.startswith("pbkdf2$")
        assert verify_password("s3cret")
        assert not verify_password("wrong")
        CFG.password = "plain"
        assert verify_password("plain")
    finally:
        CFG.password = original


def test_token_roundtrip():
    from app.auth import decode_token, make_token

    token, exp = make_token("test")
    assert decode_token(token)["sub"] == "test"


def test_path_sign():
    import time

    from app.auth import check_path_sig, sign_path

    exp = int(time.time()) + 60
    sig = sign_path("/a/b", exp, extra="local")
    assert check_path_sig("/a/b", exp, sig, extra="local")
    assert not check_path_sig("/a/b", exp, sig, extra="other")
    assert not check_path_sig("/a/b", 1, sig, extra="local")


def test_clean_path_rejects_escape():
    from app.adapters.base import clean_path, join

    assert clean_path("/a//b/") == "/a/b"
    with pytest.raises(ValueError):
        clean_path("/a/../../etc")
    with pytest.raises(ValueError):
        join("/", "../x")


def test_local_adapter_roundtrip():
    from app.adapters.local_fs import LocalFS

    ad = LocalFS(CFG.source("local"))
    entries, meta = ad.list("/")
    assert [e.name for e in entries] == ["hello.txt"]
    assert meta["allow_upload"] is True
    st = ad.stat("/hello.txt")
    assert st.size == 2 and st.kind == "text"
    ad.mkdir("/sub")
    assert ad.stat("/sub").is_dir
    ad.delete("/sub")
    with pytest.raises(FileNotFoundError):
        ad.stat("/sub")


def test_webdav_propfind_parsing(monkeypatch):
    """PROPFIND 的 XML 解析（CloudDrive2 实际返回的形状）。"""
    import httpx

    from app.adapters.webdav import WebDAV

    xml = """<?xml version="1.0" encoding="utf-8"?>
<d:multistatus xmlns:d="DAV:">
  <d:response>
    <d:href>/dav/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/></d:resourcetype>
      <d:getlastmodified>Mon, 17 Nov 2025 10:00:00 GMT</d:getlastmodified>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/%E7%94%B5%E5%BD%B1/</d:href>
    <d:propstat><d:prop>
      <d:resourcetype><d:collection/></d:resourcetype>
      <d:getlastmodified>Mon, 17 Nov 2025 10:00:00 GMT</d:getlastmodified>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
  <d:response>
    <d:href>/dav/movie.mkv</d:href>
    <d:propstat><d:prop>
      <d:resourcetype/>
      <d:getcontentlength>1234</d:getcontentlength>
      <d:getlastmodified>Tue, 18 Nov 2025 10:00:00 GMT</d:getlastmodified>
    </d:prop><d:status>HTTP/1.1 200 OK</d:status></d:propstat>
  </d:response>
</d:multistatus>"""

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.method == "PROPFIND"
        return httpx.Response(207, content=xml.encode(),
                              headers={"content-type": "application/xml"})

    src = config_mod.Source(id="dav", name="dav", kind="webdav",
                            base="http://h/dav", user="u", password="p")
    ad = WebDAV(src)
    monkeypatch.setattr(ad, "_client",
                        lambda: httpx.Client(transport=httpx.MockTransport(handler)))
    entries, meta = ad.list("/")
    names = [e.name for e in entries]
    assert names == ["电影", "movie.mkv"]           # 目录在前，第一项（自己）被跳过
    movie = entries[1]
    assert movie.path == "/movie.mkv" and movie.size == 1234 and movie.kind == "video"
    assert meta["allow_upload"] is True


def test_api_list_and_raw():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    token = client.post("/api/v1/auth/login",
                        json={"password": "pw", "device": "t"}).json()["token"]
    h = {"Authorization": f"Bearer {token}"}
    r = client.get("/api/v1/fs/list", params={"source": "local", "path": "/"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["entries"][0]["name"] == "hello.txt"

    link = client.get("/api/v1/fs/link",
                      params={"source": "local", "path": "/hello.txt"}, headers=h).json()
    raw = client.get(link["url"])
    assert raw.status_code == 200 and raw.content == b"hi"
    assert client.get(link["url"] + "&bogus=1").content == b"hi"


def test_chat_disabled_returns_503():
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    r = client.post("/hermes/api/chat",
                    json={"input": [{"type": "input_text", "text": "hi"}]},
                    auth=("hermes", "pw"))
    assert r.status_code == 503

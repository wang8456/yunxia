"""测试夹具：用临时 config.json，别碰线上那份。"""

from __future__ import annotations

import json
import os
import tempfile
from pathlib import Path

import pytest

_TMP = Path(tempfile.mkdtemp(prefix="yunxia-test-"))
_CFG = _TMP / "config.json"
SECRET = _TMP / "token.secret"
DATA = _TMP / "data"
DATA.mkdir(exist_ok=True)
PW = "test-pass-123"


def _write_config():
    _CFG.write_text(json.dumps({
        "data_root": str(_TMP),
        "dufs_base": "http://127.0.0.1:15007",
        "db_path": str(_TMP / "test.db"),
        "token_secret_path": str(SECRET),
        "token_days": 30,
        "password_hash": "",
        "password_salt": "",
        "sources": [{
            "id": "nas", "name": "NAS", "kind": "dufs",
            "base": "http://127.0.0.1:15007",
            "user": "admin", "password": PW, "root": str(DATA), "enabled": True,
        }],
    }, ensure_ascii=False), encoding="utf-8")


_write_config()
# 必须在 import app 之前设置 —— config.CFG 是模块级单例
os.environ["YUNXIA_CONFIG"] = str(_CFG)


@pytest.fixture(scope="session")
def client():
    from fastapi.testclient import TestClient

    from app.main import app

    with TestClient(app) as c:
        yield c


@pytest.fixture(scope="session")
def password() -> str:
    return PW


@pytest.fixture(scope="session")
def token(client, password) -> str:
    r = client.post("/api/v1/auth/login", json={"password": password, "device": "pytest"})
    assert r.status_code == 200, r.text
    return r.json()["token"]

@pytest.fixture(autouse=True)
def _clear_tasks_cache():
    """任务列表有 3 秒缓存，测试之间会串味（上一个用例的结果被下一个复用）。"""
    from app.routers import tasks as _t
    _t._CACHE.update({"at": 0.0, "data": None, "key": None})
    yield
    _t._CACHE.update({"at": 0.0, "data": None, "key": None})

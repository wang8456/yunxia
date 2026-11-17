"""P1 验收：认证。"""

from __future__ import annotations

import time

import jwt


def test_healthz(client):
    r = client.get("/api/v1/healthz")
    assert r.status_code == 200
    body = r.json()
    assert body["ok"] is True
    assert "nas" in body["sources"]


def test_login_ok(client, password):
    r = client.post("/api/v1/auth/login", json={"password": password, "device": "手机"})
    assert r.status_code == 200
    body = r.json()
    assert body["token"].count(".") == 2
    assert body["expires_at"] > time.time() + 29 * 86400


def test_login_bad(client):
    r = client.post("/api/v1/auth/login", json={"password": "wrong"})
    assert r.status_code == 401
    assert "口令" in r.json()["detail"]


def test_me_requires_token(client):
    assert client.get("/api/v1/auth/me").status_code == 401


def test_me_with_bearer(client, token):
    r = client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200
    assert r.json()["device"] == "pytest"


def test_me_with_query_token(client, token):
    """播放器/图片标签带不了 header，得支持 ?t="""
    r = client.get(f"/api/v1/auth/me?t={token}")
    assert r.status_code == 200


def test_expired_token_rejected(client):
    from app.config import CFG

    expired = jwt.encode(
        {"sub": "x", "iat": int(time.time()) - 100, "exp": int(time.time()) - 10},
        CFG.token_secret, algorithm="HS256",
    )
    assert client.get("/api/v1/auth/me", headers={"Authorization": f"Bearer {expired}"}).status_code == 401


def test_garbage_token_rejected(client):
    assert client.get("/api/v1/auth/me", headers={"Authorization": "Bearer abc.def.ghi"}).status_code == 401


def test_openapi_served(client):
    r = client.get("/api/v1/openapi.json")
    assert r.status_code == 200
    paths = r.json()["paths"]
    assert "/api/v1/auth/login" in paths
    assert "/api/v1/healthz" in paths

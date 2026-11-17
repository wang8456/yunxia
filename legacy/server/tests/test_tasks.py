"""P6 验收：任务中心（磁力 / ed2k 归一化 + 中转健康）。"""

from __future__ import annotations

import pytest

from app.routers import tasks as T


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_needs_token(client):
    assert client.get("/api/v1/tasks").status_code == 401


def test_normalize_magnet_aria2_shape():
    t = T.normalize({"gid": "abc123", "name": "沙丘2.mkv", "size": 1000, "done": 250,
                     "speed": 2048, "status": "active", "target": "nas",
                     "target_name": "NAS"}, "magnet")
    assert t.id == "abc123"
    assert t.pct == 25.0
    assert t.speed == 2048
    assert t.state == "active"


def test_normalize_ed2k_uses_hash_and_computes_pct():
    t = T.normalize({"hash": "A" * 32, "name": "老片.avi", "total": 400, "completed": 100,
                     "state": "queued"}, "ed2k")
    assert t.id == "A" * 32
    assert t.size == 400
    assert t.pct == 25.0
    assert t.kind == "ed2k"


def test_normalize_zero_size_no_div_by_zero():
    t = T.normalize({"gid": "x", "name": "[METADATA]x", "size": 0, "done": 0}, "magnet")
    assert t.pct == 0.0


def test_list_aggregates_and_sorts(client, token, monkeypatch):
    def fake_get(base, path):
        if path == "/health":
            return {"ok": True, "name": "NAS", "dir": "/d", "free_gb": 10}
        return {"ok": True, "tasks": [
            {"gid": "b", "name": "慢的", "size": 100, "done": 10, "status": "active"},
            {"gid": "a", "name": "快的", "size": 100, "done": 90, "status": "active"},
            {"gid": "c", "name": "停的", "size": 100, "done": 5, "status": "paused"},
        ]}

    monkeypatch.setattr(T, "_get_json", fake_get)
    r = client.get("/api/v1/tasks", headers=_h(token))
    assert r.status_code == 200
    body = r.json()
    names = [t["name"] for t in body["tasks"]]
    assert names[0] == "快的"          # 进度高的在前
    assert "停的" in names
    assert body["hubs"]["magnet"]["online"] is True


def test_one_hub_down_does_not_break_list(client, token, monkeypatch):
    def fake_get(base, path):
        if "5094" in base:
            raise RuntimeError("connection refused")
        return {"ok": True, "tasks": [{"hash": "H" * 32, "name": "ed2k 任务", "total": 10, "completed": 5}]}

    monkeypatch.setattr(T, "_get_json", fake_get)
    r = client.get("/api/v1/tasks", headers=_h(token))
    assert r.status_code == 200
    body = r.json()
    assert [t["kind"] for t in body["tasks"]] == ["ed2k"]
    assert body["hubs"]["magnet"]["online"] is False


def test_hub_offline_reports_error(client, token, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("down")

    monkeypatch.setattr(T, "_get_json", boom)
    body = client.get("/api/v1/tasks", headers=_h(token)).json()
    assert body["tasks"] == []
    assert body["hubs"]["magnet"]["online"] is False
    assert "down" in body["hubs"]["magnet"]["error"]


def test_add_rejects_empty(client, token):
    r = client.post("/api/v1/tasks/add", json={"kind": "magnet", "urls": ["  "]}, headers=_h(token))
    assert r.status_code == 400


def test_add_rejects_bad_kind(client, token):
    r = client.post("/api/v1/tasks/add", json={"kind": "ftp", "urls": ["x"]}, headers=_h(token))
    assert r.status_code == 422


def test_add_forwards_to_hub(client, token, monkeypatch):
    seen = {}

    def fake_post(base, path, body):
        seen["path"] = path
        seen["body"] = body
        return {"ok": True, "gid": "new1"}

    monkeypatch.setattr(T, "_post_json", fake_post)
    r = client.post("/api/v1/tasks/add",
                    json={"kind": "magnet", "urls": ["magnet:?xt=urn:btih:abc"], "dir": "影片"},
                    headers=_h(token))
    assert r.status_code == 200
    assert seen["path"] == "/add"
    assert seen["body"]["magnet"] == "magnet:?xt=urn:btih:abc"
    assert seen["body"]["dir"] == "影片"


def test_remove_maps_to_purge_for_magnet(client, token, monkeypatch):
    seen = {}
    monkeypatch.setattr(T, "_post_json", lambda base, path, body: seen.update(path=path) or {"ok": True})
    client.post("/api/v1/tasks/act", json={"kind": "magnet", "id": "g1", "act": "remove"}, headers=_h(token))
    assert seen["path"] == "/purge"


def test_cancel_maps_to_cancel_for_ed2k(client, token, monkeypatch):
    seen = {}
    monkeypatch.setattr(T, "_post_json", lambda base, path, body: seen.update(path=path) or {"ok": True})
    client.post("/api/v1/tasks/act", json={"kind": "ed2k", "id": "A" * 32, "act": "remove"}, headers=_h(token))
    assert seen["path"] == "/cancel"


def test_hub_unreachable_returns_502(client, token, monkeypatch):
    def boom(*a, **k):
        raise RuntimeError("down")

    monkeypatch.setattr(T, "_post_json", boom)
    r = client.post("/api/v1/tasks/add", json={"kind": "magnet", "urls": ["magnet:?x"]}, headers=_h(token))
    assert r.status_code == 502

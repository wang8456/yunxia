"""P4 验收：搜索索引。"""

from __future__ import annotations

import os

import pytest


@pytest.fixture()
def data_dir(tmp_path, monkeypatch):
    """把源根换到临时目录，避免动到真实共享盘。"""
    from app.adapters import _cache
    from app.config import CFG

    _cache.clear()
    for s in CFG.sources:
        if s.id == "nas":
            s.root = str(tmp_path)
    (tmp_path / "电影").mkdir()
    (tmp_path / "电影" / "星际穿越.2014.1080p.mkv").write_bytes(b"x" * 100)
    (tmp_path / "电影" / "沙丘2.mkv").write_bytes(b"y" * 50)
    (tmp_path / "说明.txt").write_text("hi", encoding="utf-8")
    yield tmp_path
    _cache.clear()


def _h(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def test_search_needs_token(client):
    assert client.get("/api/v1/search?q=x").status_code == 401


def test_reindex_then_search(client, token, data_dir):
    r = client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    assert r.status_code == 200, r.text
    assert r.json()["files"] >= 3

    r = client.get("/api/v1/search?q=星际穿越", headers=_h(token))
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["total"] == 1, body
    assert body["items"][0]["name"] == "星际穿越.2014.1080p.mkv"
    assert body["items"][0]["kind"] == "video"


def test_short_chinese_query_uses_like(client, token, data_dir):
    client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    r = client.get("/api/v1/search?q=沙丘", headers=_h(token))   # 2 字，trigram 命中不了
    assert r.json()["total"] == 1
    assert "沙丘2.mkv" == r.json()["items"][0]["name"]


def test_mid_substring_of_long_name(client, token, data_dir):
    client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    r = client.get("/api/v1/search?q=1080p", headers=_h(token))
    assert r.json()["total"] == 1


def test_kind_filter(client, token, data_dir):
    client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    r = client.get("/api/v1/search?q=&kind=text", headers=_h(token))
    names = [i["name"] for i in r.json()["items"]]
    assert names == ["说明.txt"]


def test_txt_extension_matched_by_kind(client, token, data_dir):
    client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    item = client.get("/api/v1/search?q=说明", headers=_h(token)).json()["items"][0]
    assert item["kind"] == "text"


def test_status_reports_counts(client, token, data_dir):
    client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    st = client.get("/api/v1/search/status", headers=_h(token)).json()
    assert st["files"] >= 3
    assert st["dirs"] >= 1
    assert st["last_scan"]


def test_deleted_file_disappears_after_rescan(client, token, data_dir):
    client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    assert client.get("/api/v1/search?q=沙丘", headers=_h(token)).json()["total"] == 1
    os.remove(data_dir / "电影" / "沙丘2.mkv")
    client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    assert client.get("/api/v1/search?q=沙丘", headers=_h(token)).json()["total"] == 0


def test_incremental_index_follows_events(client, token, data_dir):
    """inotify 事件 → 索引即时更新（不重扫全盘）"""
    from app.indexer import index_event

    client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    (data_dir / "新下载.mkv").write_bytes(b"z" * 10)
    index_event({"type": "fs.changed", "source": "nas", "path": "/", "name": "新下载.mkv",
                 "op": "create", "is_dir": False})
    assert client.get("/api/v1/search?q=新下载", headers=_h(token)).json()["total"] == 1

    index_event({"type": "fs.changed", "source": "nas", "path": "/", "name": "新下载.mkv",
                 "op": "delete", "is_dir": False})
    assert client.get("/api/v1/search?q=新下载", headers=_h(token)).json()["total"] == 0


def test_limit_and_offset(client, token, data_dir):
    client.post("/api/v1/search/reindex?blocking=true", headers=_h(token))
    a = client.get("/api/v1/search?q=&limit=1&offset=0", headers=_h(token)).json()
    b = client.get("/api/v1/search?q=&limit=1&offset=1", headers=_h(token)).json()
    assert len(a["items"]) == 1 and len(b["items"]) == 1
    assert a["items"][0]["path"] != b["items"][0]["path"]

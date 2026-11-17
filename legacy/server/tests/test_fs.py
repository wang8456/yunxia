"""P2 验收：文件域。"""

from __future__ import annotations

import os

import pytest

from app.adapters.base import clean_path, join
from app.models import kind_of


# ---------- 纯函数 ----------

@pytest.mark.parametrize("raw,expect", [
    ("", "/"), ("/", "/"), ("下载", "/下载"), ("/下载/", "/下载"),
    ("/a/./b", "/a/b"), ("/a//b/", "/a/b"),
])
def test_clean_path(raw, expect):
    assert clean_path(raw) == expect


@pytest.mark.parametrize("raw", ["/../etc/passwd", "../x", "/a/../../b"])
def test_clean_path_rejects_escape(raw):
    with pytest.raises(ValueError):
        clean_path(raw)


@pytest.mark.parametrize("name", ["..", ".", "a/b", ""])
def test_join_rejects_bad_name(name):
    with pytest.raises(ValueError):
        join("/x", name)


def test_join_ok():
    assert join("/下载", "影片.mp4") == "/下载/影片.mp4"


@pytest.mark.parametrize("name,kind", [
    ("a.mp4", "video"), ("b.MKV", "video"), ("c.jpg", "image"),
    ("d.pdf", "pdf"), ("e.py", "code"), ("f.zip", "archive"), ("g.bin", "file"),
])
def test_kind_of(name, kind):
    assert kind_of(name, False) == kind


def test_kind_of_dir():
    assert kind_of("任意", True) == "dir"


# ---------- 接口 ----------

def test_list_needs_token(client):
    assert client.get("/api/v1/fs/list").status_code == 401


def test_list_empty(client, token):
    r = client.get("/api/v1/fs/list", headers={"Authorization": f"Bearer {token}"})
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["path"] == "/"
    assert body["entries"] == []
    assert body["parent"] is None


def test_mkdir_and_list(client, token):
    h = {"Authorization": f"Bearer {token}"}
    r = client.post("/api/v1/fs/mkdir", json={"path": "/", "name": "测试目录"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["is_dir"] is True

    r = client.get("/api/v1/fs/list?path=/", headers=h)
    names = [e["name"] for e in r.json()["entries"]]
    assert "测试目录" in names
    assert r.json()["entries"][0]["is_dir"] is True


def test_mkdir_duplicate_is_idempotent(client, token):
    h = {"Authorization": f"Bearer {token}"}
    assert client.post("/api/v1/fs/mkdir", json={"path": "/", "name": "重复"}, headers=h).status_code == 200
    assert client.post("/api/v1/fs/mkdir", json={"path": "/", "name": "重复"}, headers=h).status_code == 200


def test_upload_then_stat_and_text(client, token):
    h = {"Authorization": f"Bearer {token}"}
    client.post("/api/v1/fs/mkdir", json={"path": "/", "name": "上传"}, headers=h)
    payload = "第一行\n第二行\n".encode()
    r = client.put("/api/v1/fs/upload?path=/上传&name=笔记.txt", content=payload, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["size"] == len(payload)

    r = client.get("/api/v1/fs/stat?path=/上传/笔记.txt", headers=h)
    assert r.status_code == 200
    assert r.json()["kind"] == "text"

    r = client.get("/api/v1/fs/text?path=/上传/笔记.txt", headers=h)
    assert r.status_code == 200
    assert "第二行" in r.text


def test_upload_no_partial_file_visible(client, token):
    """上传中途失败不能留下半截文件（先写 .part 再改名）"""
    h = {"Authorization": f"Bearer {token}"}
    client.put("/api/v1/fs/upload?path=/上传&name=完整.bin", content=b"x" * 1024, headers=h)
    d = client.get("/api/v1/fs/list?path=/上传", headers=h).json()
    names = [e["name"] for e in d["entries"]]
    assert "完整.bin" in names
    assert not [n for n in names if n.endswith(".part")]


def test_move_and_delete(client, token):
    h = {"Authorization": f"Bearer {token}"}
    client.put("/api/v1/fs/upload?path=/上传&name=old.txt", content=b"hi", headers=h)
    r = client.post("/api/v1/fs/move",
                    json={"src": "/上传/old.txt", "dst": "/上传/new.txt"}, headers=h)
    assert r.status_code == 200, r.text
    assert r.json()["name"] == "new.txt"

    r = client.post("/api/v1/fs/delete", json={"paths": ["/上传/new.txt"]}, headers=h)
    assert r.json()["removed"] == ["/上传/new.txt"]
    assert client.get("/api/v1/fs/stat?path=/上传/new.txt", headers=h).status_code == 404


def test_delete_missing_reports_not_500(client, token):
    h = {"Authorization": f"Bearer {token}"}
    r = client.post("/api/v1/fs/delete", json={"paths": ["/不存在.txt"]}, headers=h)
    assert r.status_code == 200
    assert r.json()["failed"]


def test_link_for_file(client, token):
    h = {"Authorization": f"Bearer {token}"}
    client.put("/api/v1/fs/upload?path=/上传&name=片子.mp4", content=b"0" * 32, headers=h)
    r = client.get("/api/v1/fs/link?path=/上传/片子.mp4", headers=h)
    assert r.status_code == 200, r.text
    body = r.json()
    assert body["url"].startswith("/f/")
    assert body["size"] == 32


def test_link_rejects_dir(client, token):
    h = {"Authorization": f"Bearer {token}"}
    assert client.get("/api/v1/fs/link?path=/上传", headers=h).status_code == 400


def test_list_rejects_dotdot(client, token):
    h = {"Authorization": f"Bearer {token}"}
    assert client.get("/api/v1/fs/list?path=/../..", headers=h).status_code == 400


def test_unknown_source(client, token):
    h = {"Authorization": f"Bearer {token}"}
    assert client.get("/api/v1/fs/list?source=nope", headers=h).status_code == 400

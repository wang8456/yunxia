"""听译域测试：不跑真的 whisper（CI 里没有模型），只测路由、状态与导出。"""

from __future__ import annotations

import json

import pytest


def _cfg():
    from app.config import CFG

    return CFG


def _fake_job(jid: str = "testjob0001") -> dict:
    return {
        "id": jid, "source": "local", "path": "/x.mp4", "name": "x.mp4",
        "state": "done", "pct": 100.0, "msg": "听译完成", "lang": "en", "dur": 30.0,
        "model": "base", "created": 1.0,
        "segs": [[0.5, 2.0, "hello", "你好"], [30.0, 32.5, "bye", ""]],
    }


@pytest.fixture()
def subs_enabled(tmp_path):
    from app import subs as core

    cfg = _cfg()
    old = (cfg.subs.enabled, core.JOBS.copy())
    cfg.subs.enabled = True
    core.JOBS.clear()
    yield core
    cfg.subs.enabled = old[0]
    core.JOBS.clear()
    core.JOBS.update(old[1])


def test_disabled_returns_503():
    from fastapi.testclient import TestClient

    from app.main import app

    cfg = _cfg()
    old = cfg.subs.enabled
    cfg.subs.enabled = False
    try:
        c = TestClient(app)
        token = c.post("/api/v1/auth/login",
                       json={"password": "pw", "device": "t"}).json()["token"]
        r = c.post("/api/v1/subs/add", json={"source": "local", "path": "/a.mp4"},
                   headers={"Authorization": f"Bearer {token}"})
        assert r.status_code == 503
    finally:
        cfg.subs.enabled = old


def test_srt_export_bilingual(subs_enabled):
    core = subs_enabled
    job = _fake_job()
    core.JOBS[job["id"]] = job
    text = core.srt(job["id"], trans=True)
    lines = text.strip().split("\n")
    assert lines[0] == "1"
    assert lines[1] == "00:00:00,500 --> 00:00:02,000"
    assert lines[2] == "你好"          # 译文在上
    assert lines[3] == "hello"         # 原文在下
    # 没译文的段只输出原文，不会留空行
    assert "bye" in text


def test_for_and_detail_roundtrip(subs_enabled):
    from fastapi.testclient import TestClient

    from app.main import app

    core = subs_enabled
    # for_path 按 sha1(source|path) 找任务，测试里也用同一个算法生成 id
    jid = core.job_id("local", "/x.mp4")
    job = _fake_job(jid)
    core.JOBS[job["id"]] = job

    c = TestClient(app)
    token = c.post("/api/v1/auth/login",
                   json={"password": "pw", "device": "t"}).json()["token"]
    h = {"Authorization": f"Bearer {token}"}

    got = c.get("/api/v1/subs/for", params={"source": "local", "path": "/x.mp4"}, headers=h).json()
    assert got["found"] is True and len(got["segments"]) == 2

    miss = c.get("/api/v1/subs/for", params={"source": "local", "path": "/nope.mp4"}, headers=h).json()
    assert miss["found"] is False

    d = c.get(f"/api/v1/subs/{jid}", params={"since": 1}, headers=h).json()
    assert d["segments"] == 2 and len(d["segments_list"]) == 1   # since 只回新增段
    assert d["pending"] == 1                                     # 第二段没译文

    srt = c.get(f"/api/v1/subs/{jid}/srt", params={"trans": 0}, headers=h)
    assert srt.status_code == 200 and "hello" in srt.text and "你好" not in srt.text


def test_list_shape(subs_enabled):
    from fastapi.testclient import TestClient

    from app.main import app

    core = subs_enabled
    core.JOBS["j1"] = _fake_job("j1")
    c = TestClient(app)
    token = c.post("/api/v1/auth/login",
                   json={"password": "pw", "device": "t"}).json()["token"]
    d = c.get("/api/v1/subs", headers={"Authorization": f"Bearer {token}"}).json()
    assert d["enabled"] is True
    assert d["jobs"][0]["id"] == "j1"
    assert "translate" in d and "deps" in d

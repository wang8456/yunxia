"""继续观看：存进度、播完自动清、手动忘掉。"""


def _h(token):
    return {"Authorization": f"Bearer {token}"}


def test_save_and_list(client, token):
    p = "/电影/测试片.mp4"
    r = client.put("/api/v1/play", json={"path": p, "name": "测试片.mp4", "pos": 120, "dur": 3600},
                   headers=_h(token))
    assert r.status_code == 200
    assert r.json()["kept"] is True

    r = client.get("/api/v1/play", headers=_h(token))
    assert r.status_code == 200
    items = r.json()["items"]
    it = next(x for x in items if x["path"] == p)
    assert it["name"] == "测试片.mp4"
    assert it["pos"] == 120
    assert it["pct"] == 3.3


def test_finished_is_removed(client, token):
    p = "/电影/看完的.mp4"
    client.put("/api/v1/play", json={"path": p, "pos": 10, "dur": 600}, headers=_h(token))
    # 只剩 5 秒，算看完
    r = client.put("/api/v1/play", json={"path": p, "pos": 595, "dur": 600}, headers=_h(token))
    assert r.json()["kept"] is False
    items = client.get("/api/v1/play", headers=_h(token)).json()["items"]
    assert all(x["path"] != p for x in items)


def test_beginning_is_ignored(client, token):
    p = "/电影/刚点开.mp4"
    r = client.put("/api/v1/play", json={"path": p, "pos": 3, "dur": 3600}, headers=_h(token))
    assert r.json()["kept"] is False


def test_forget(client, token):
    p = "/电影/不想看.mp4"
    client.put("/api/v1/play", json={"path": p, "pos": 300, "dur": 3600}, headers=_h(token))
    assert client.delete("/api/v1/play", params={"path": p}, headers=_h(token)).status_code == 200
    items = client.get("/api/v1/play", headers=_h(token)).json()["items"]
    assert all(x["path"] != p for x in items)


def test_needs_auth(client):
    assert client.get("/api/v1/play").status_code == 401

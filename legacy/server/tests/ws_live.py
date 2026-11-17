#!/usr/bin/env python3
"""P3 验收：WebSocket 实时推送（经 5007 前置，不是直连 15100）。

用法：python3 server/tests/ws_live.py [host]
做的事：
  1. 登录拿 token
  2. 连 ws，收 hello
  3. 在 NAS 上 touch 一个文件（真改盘，不是假事件）
  4. 3 秒内收到 fs.changed
  5. 断线重连带 since，收到补发
  6. 假 token 必须 4401
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
import time
import urllib.request

import paramiko
import websockets

HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.10"
BASE = f"http://{HOST}:5007"
WS = f"ws://{HOST}:5007/ws"
PW = os.environ.get("YUNXIA_PW", "test-pass")
TMP = "/mnt/data/share/_wstest"

ok = fail = 0


def check(name: str, cond: bool, extra: str = ""):
    global ok, fail
    if cond:
        ok += 1
        print(f"  ✓ {name} {extra}")
    else:
        fail += 1
        print(f"  ✗ {name} {extra}")


def login() -> str:
    body = json.dumps({"password": PW, "device": "ws-live"}).encode()
    req = urllib.request.Request(f"{BASE}/api/v1/auth/login", data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.loads(r.read())["token"]


async def main() -> int:
    tok = login()
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    ssh.connect(HOST, username="root", password="password", timeout=15)

    def nas(cmd: str) -> str:
        i, o, e = ssh.exec_command(cmd, timeout=20)
        return (o.read().decode() + e.read().decode()).strip()

    nas(f"mkdir -p {TMP}")

    async with websockets.connect(f"{WS}?t={tok}", open_timeout=10) as ws:
        hello = json.loads(await asyncio.wait_for(ws.recv(), 10))
        check("hello", hello.get("type") == "hello", f"seq={hello.get('seq')}")

        nas(f"touch {TMP}/实时测试.txt")
        got = None
        deadline = time.time() + 5
        while time.time() < deadline:
            try:
                msg = json.loads(await asyncio.wait_for(ws.recv(), deadline - time.time()))
            except asyncio.TimeoutError:
                break
            if msg.get("type") == "fs.changed" and msg.get("name") == "实时测试.txt":
                got = msg
                break
        check("收到 create 事件", got is not None, json.dumps(got, ensure_ascii=False) if got else "")
        last_seq = got["seq"] if got else hello.get("seq", 0)

    # 断线期间再改一次，然后带 since 重连
    nas(f"echo change >> {TMP}/实时测试.txt")
    await asyncio.sleep(0.5)
    async with websockets.connect(f"{WS}?t={tok}&since={last_seq}", open_timeout=10) as ws:
        hello = json.loads(await asyncio.wait_for(ws.recv(), 10))
        replayed = []
        deadline = time.time() + 4
        while time.time() < deadline:
            try:
                msg = json.loads(await asyncio.wait_for(ws.recv(), 1.0))
            except asyncio.TimeoutError:
                break
            if msg.get("type") == "fs.changed":
                replayed.append(msg)
        check("重连补发", len(replayed) > 0, f"{len(replayed)} 条")

    # 假 token
    try:
        async with websockets.connect(f"{WS}?t=abc.def.ghi", open_timeout=8) as ws:
            await ws.recv()
        check("假 token 被拒", False, "竟然连上了")
    except Exception as exc:  # noqa: BLE001
        code = getattr(exc, "code", None)
        check("假 token 被拒", code in (4401, 1008, 403) or "4401" in str(exc) or "403" in str(exc), f"code={code}")

    nas(f"rm -rf {TMP}")
    ssh.close()
    print(f"\n结果：{ok} 通过 / {fail} 失败")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))

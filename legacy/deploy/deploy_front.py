#!/usr/bin/env python3
"""把打好的 dufs-front.py 推到 NAS 并重启，然后验证三条链路。

  python3 deploy/deploy_front.py

链路验收：
  1. 5007/api/v1/healthz  → 200（FastAPI）
  2. 5007/ws              → 101（WebSocket 握手，经前置）
  3. 5007/                → 200 且是云匣页面（dufs 没动）
"""

from __future__ import annotations

import base64
import os
import socket
import ssl  # noqa: F401  (仅为了明确这里走明文，勿加 TLS)
import sys
import time
from pathlib import Path

import paramiko

HOST = os.environ.get("YUNXIA_HOST", "192.168.1.10")
USER = os.environ.get("YUNXIA_SSH_USER", "root")
PASSWORD = os.environ.get("YUNXIA_SSH_PASS", "")   # 必须自己设，别再写死口令
LOCAL = Path(__file__).resolve().parent / "nas" / "dufs-front.py"
REMOTE = "/root/dufs-front.py"


def ws_handshake(host: str, port: int, path: str, timeout: float = 6.0) -> str:
    """裸 socket 发一次 WS 握手，返回状态行（客户端用，验证 101 透传）。"""
    key = base64.b64encode(os.urandom(16)).decode()
    req = (
        f"GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\n"
        "Upgrade: websocket\r\nConnection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
    )
    with socket.create_connection((host, port), timeout=timeout) as s:
        s.sendall(req.encode())
        s.settimeout(timeout)
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = s.recv(4096)
            if not chunk:
                break
            head += chunk
    first = head.split(b"\r\n", 1)[0].decode("latin-1")
    return first


def main() -> int:
    nas = paramiko.SSHClient()
    nas.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    nas.connect(HOST, username=USER, password=PASSWORD, timeout=15)
    sftp = nas.open_sftp()
    # 先备份线上那份（每次只保留最近一份 .bak）
    nas.exec_command  # noqa: B018
    i, o, e = nas.exec_command(f"cp -f {REMOTE} {REMOTE}.bak && ls -la {REMOTE}.bak")
    o.read()
    sftp.put(str(LOCAL), REMOTE)
    sftp.chmod(REMOTE, 0o755)
    sftp.close()
    print(f"[1/2] 已推送 {LOCAL.name} → {REMOTE}（旧版留 .bak）")

    i, o, e = nas.exec_command("/etc/init.d/dufs-front restart 2>&1 | tail -3")
    print("[2/2] 重启:", (o.read().decode() + e.read().decode()).strip() or "ok")
    nas.close()
    time.sleep(2)

    # 验收
    ok = True

    def check(name: str, fn):
        nonlocal ok
        try:
            res = fn()
            print(f"  {name:22s} {res}")
        except Exception as exc:  # noqa: BLE001
            print(f"  {name:22s} 失败 {exc}")
            ok = False

    def http_status(path: str) -> str:
        import urllib.request
        req = urllib.request.Request(f"http://{HOST}:5007{path}")
        req.add_header("User-Agent", "Mozilla/5.0 yunxia-check")
        with urllib.request.urlopen(req, timeout=8) as r:
            body = r.read(400).decode("utf-8", "replace")
        title = ""
        if "<title>" in body:
            title = body.split("<title>", 1)[1].split("</title>", 1)[0]
        return f"{r.status} {title}".strip()

    check("api /healthz", lambda: http_status("/api/v1/healthz")[:40])

    def ws_check() -> str:
        line = ws_handshake(HOST, 5007, "/ws")
        if "101" not in line:
            raise RuntimeError(line)      # P3 之前 /ws 还不存在，403 属预期
        return line

    check("ws 握手", ws_check)
    check("网页版 /", lambda: http_status("/"))
    print("结果:", "全部通过" if ok else "有失败")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())

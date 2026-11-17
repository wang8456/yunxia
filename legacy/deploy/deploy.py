#!/usr/bin/env python3
"""把 server/ 部署到 NAS（幂等）。

  python3 deploy/deploy.py            # 部署 + 重启 + 自检
  python3 deploy/deploy.py --no-restart

做的事：
  1. 推 app/*.py 到 /mnt/data/home/yunxia-api/app/
  2. requirements.txt 变了才装依赖（用 sha256 记指纹）
  3. 首次部署生成 config.json（dufs 口令从 share.yaml 里读，不落仓库）
  4. 写 /etc/init.d/yunxia-api（procd）并 enable + restart
  5. curl 127.0.0.1:15100/api/v1/healthz 自检
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import stat
import sys
from pathlib import Path

import paramiko

HOST = os.environ.get("YUNXIA_HOST", "192.168.1.10")
USER = os.environ.get("YUNXIA_SSH_USER", "root")
PASSWORD = os.environ.get("YUNXIA_SSH_PASS", "")   # 必须自己设，别再写死口令
REMOTE = "/mnt/data/home/yunxia-api"
PORT = 15100

LOCAL = Path(__file__).resolve().parent.parent
SERVER = LOCAL / "server"

INIT_SH = """#!/bin/sh /etc/rc.common
# 云匣统一 API（FastAPI，只监听 127.0.0.1，对外由 5007 前置分流）
USE_PROCD=1
START=95
STOP=10

start_service() {
    procd_open_instance
    procd_set_param command __REMOTE__/venv/bin/python -m uvicorn app.main:app \\
        --host 127.0.0.1 --port __PORT__ --proxy-headers --forwarded-allow-ips=127.0.0.1
    procd_set_param env PYTHONPATH=__REMOTE__ YUNXIA_CONFIG=__REMOTE__/config.json
    procd_set_param cwd __REMOTE__
    procd_set_param respawn 3600 5 0
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

service_triggers() {
    procd_add_reload_trigger "yunxia-api"
}
"""


class Nas:
    def __init__(self):
        self.c = paramiko.SSHClient()
        self.c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        self.c.connect(HOST, username=USER, password=PASSWORD, timeout=15)
        self.s = self.c.open_sftp()

    def run(self, cmd: str, timeout: int = 300) -> tuple[int, str]:
        i, o, e = self.c.exec_command(cmd, timeout=timeout)
        out = o.read().decode(errors="replace") + e.read().decode(errors="replace")
        return o.channel.recv_exit_status(), out.strip()

    def put(self, local: Path, remote: str, mode: int | None = None):
        self.s.put(str(local), remote)
        if mode is not None:
            self.s.chmod(remote, mode)


def default_config(nas: Nas) -> dict:
    """从 share.yaml 的 auth 行取口令，避免仓库里出现明文口令。"""
    user, pwd = os.environ.get("YUNXIA_WEB_USER", "admin"), ""
    _, yaml_txt = nas.run("cat /mnt/data/share-app/share.yaml")
    m = re.search(r"-\s*([^:@\s]+):([^@\s]+)@/", yaml_txt)
    if m:
        user, pwd = m.group(1), m.group(2)
    return {
        "data_root": "/mnt/data/share",
        "dufs_base": "http://127.0.0.1:15007",
        "db_path": f"{REMOTE}/yunxia.db",
        "token_secret_path": f"{REMOTE}/token.secret",
        "token_days": 30,
        "sources": [
            {"id": "nas", "name": "NAS 共享盘", "kind": "dufs",
             "base": "http://127.0.0.1:15007", "user": user, "password": pwd,
             "root": "/mnt/data/share"},
            {"id": "115", "name": "115 网盘", "kind": "relay115",
             "base": "http://127.0.0.1:5008", "root": "/", "enabled": False},
            {"id": "pc", "name": "电脑", "kind": "pcdufs",
             "base": "http://127.0.0.1:5010", "root": "/", "enabled": False},
        ],
    }


def main() -> int:
    restart = "--no-restart" not in sys.argv
    nas = Nas()

    nas.run(f"mkdir -p {REMOTE}/app {REMOTE}/logs")

    # 1. 代码（保持 app/ 下的目录结构）
    pushed = 0
    appdir = SERVER / "app"
    for f in sorted(appdir.rglob("*.py")):
        rel = f.relative_to(appdir).as_posix()
        remote_path = f"{REMOTE}/app/{rel}"
        parent = os.path.dirname(remote_path)
        nas.run(f"mkdir -p {parent}")
        nas.put(f, remote_path)
        pushed += 1
    print(f"[1/5] 推送 {pushed} 个 py 文件")

    # 2. 依赖（按 requirements 指纹）
    req_local = SERVER / "requirements.txt"
    digest = hashlib.sha256(req_local.read_bytes()).hexdigest()[:16]
    _, old = nas.run(f"cat {REMOTE}/.req.sha 2>/dev/null || echo none")
    if old.strip() != digest:
        nas.put(req_local, f"{REMOTE}/requirements.txt")
        code, out = nas.run(
            f"{REMOTE}/venv/bin/pip install -q -i https://pypi.tuna.tsinghua.edu.cn/simple "
            f"-r {REMOTE}/requirements.txt 2>&1 | tail -5; echo rc=$?",
            timeout=900,
        )
        print(f"[2/5] 装依赖 rc={code} {out[-200:]}")
        nas.run(f"echo {digest} > {REMOTE}/.req.sha")
    else:
        print("[2/5] 依赖未变，跳过")

    # 3. 配置
    code, has = nas.run(f"test -f {REMOTE}/config.json && echo yes || echo no")
    if "yes" not in has:
        cfg = default_config(nas)
        body = json.dumps(cfg, ensure_ascii=False, indent=2)
        with nas.s.open(f"{REMOTE}/config.json", "w") as fh:
            fh.write(body)
        nas.s.chmod(f"{REMOTE}/config.json", 0o600)
        print(f"[3/5] 生成 config.json（源：{', '.join(s['id'] for s in cfg['sources'])}）")
    else:
        print("[3/5] config.json 已存在，保留")

    # 4. procd 服务
    init = INIT_SH.replace("__REMOTE__", REMOTE).replace("__PORT__", str(PORT))
    with nas.s.open("/etc/init.d/yunxia-api", "w") as fh:
        fh.write(init)
    nas.s.chmod("/etc/init.d/yunxia-api", 0o755)
    nas.run("/etc/init.d/yunxia-api enable 2>/dev/null")
    if restart:
        # procd 的 restart 有时不真的杀掉旧进程（表现为新代码不生效、端点 404），
        # 所以按 uptime 验证：没归零就手动 kill 让 procd 拉起来。
        nas.run("/etc/init.d/yunxia-api restart 2>&1 | tail -3")
        import json as _json
        import time as _t

        def uptime() -> float:
            try:
                _, out = nas.run(f"curl -s --max-time 3 http://127.0.0.1:{PORT}/api/v1/healthz")
                return float(_json.loads(out).get("uptime", 999))
            except Exception:  # noqa: BLE001
                return 999.0

        _t.sleep(3)
        if uptime() > 60:
            pid = ""
            _, ps = nas.run("ps w | grep '[y]unxia-api/venv' | awk '{print $1}'")
            pid = (ps or "").strip().split("\n")[0].strip()
            if pid:
                nas.run(f"kill {pid}")
                _t.sleep(4)
            print(f"[4/5] 服务已重启（强杀旧进程 {pid}）")
        else:
            print("[4/5] 服务已重启")
    else:
        print("[4/5] 跳过重启")

    # 5. 自检
    import time
    for _ in range(15):
        time.sleep(1)
        code, out = nas.run(f"curl -s --max-time 3 http://127.0.0.1:{PORT}/api/v1/healthz")
        if '"ok"' in out and "true" in out:
            print(f"[5/5] healthz OK: {out[:200]}")
            return 0
    print(f"[5/5] healthz 失败：{out[:300]}")
    nas.run(f"tail -20 {REMOTE}/logs/*.log 2>/dev/null; logread | grep -i yunxia | tail -10")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())

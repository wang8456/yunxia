#!/usr/bin/env python3
"""云匣前置分流：同一个 5007 端口，/hermes 走对话后端，其余照旧给 dufs。

  client → 0.0.0.0:5007
      ├─ /hermes/*  → 192.168.1.20:8088（直连 WSL 上的网页对话）
      └─ 其它       → 127.0.0.1:15007（dufs，云匣本体）

踩过的坑：
  * 每个请求单独连一次上游（Connection: close），路由不用猜，也不会串到另一个服务
  * **必须**把回给浏览器的响应头里的 Connection 改写成 close。否则浏览器以为连接还能复用，
    接着在同一 socket 上下一个请求，而那条连接已被上游关掉 → 随机「资源加载失败 / 白屏」
  * 响应体不缓冲，原样流式转到 EOF（SSE 才不会卡住）
  * 1xx（100-continue）要先跳过再读真正的响应头，否则上传大文件时头部错位
"""
from __future__ import annotations

import base64
import hashlib
import hmac
import os
import re
import socket
import threading
import time
import urllib.parse

LISTEN = os.environ.get("FRONT_LISTEN", "0.0.0.0:5007")
DUFS = os.environ.get("FRONT_DUFS", "127.0.0.1:15007")
HERMES = os.environ.get("FRONT_HERMES", "192.168.1.20:8088")
API = os.environ.get("FRONT_API", "127.0.0.1:15100")
PREFIX = "/hermes"
API_PREFIX = "/api/v1"      # 云匣统一 API（FastAPI）
WS_PATHS = ("/ws",)         # WebSocket 端点
LINK_PREFIX = "/f/"         # 签名直链：/f/<exp>/<sig>/<source><path>
WEB_PREFIX = "/app"         # 新的 Vue 前端（P7）
LEGACY_PREFIX = "/files"     # 老的 dufs 页面留个备用入口
# 根路径给谁：web=新前端（默认），dufs=老页面。改这一行就能一键回滚
ROOT_TARGET = os.environ.get("FRONT_ROOT", "web")
SECRET_FILE = os.environ.get("FRONT_SECRET", "/mnt/data/home/yunxia-api/token.secret")
SHARE_YAML = os.environ.get("FRONT_SHARE_YAML", "/mnt/data/share-app/share.yaml")
IO_TIMEOUT = 900


def hostport(s: str) -> tuple[str, int]:
    host, _, port = s.rpartition(":")
    return host or "127.0.0.1", int(port)


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def read_head(sock: socket.socket, timeout: int = 30) -> bytes | None:
    """读到 \\r\\n\\r\\n（含）为止；后面多读到的字节一并返回。"""
    buf = b""
    sock.settimeout(timeout)
    while b"\r\n\r\n" not in buf:
        try:
            chunk = sock.recv(65536)
        except (socket.timeout, OSError):
            return None
        if not chunk:
            return None
        buf += chunk
        if len(buf) > 262144:
            return None
    return buf


def split_head(blob: bytes) -> tuple[bytes, bytes]:
    head, _, rest = blob.partition(b"\r\n\r\n")
    return head, rest


def status_code(head: bytes) -> int:
    try:
        return int(head.split(b"\r\n", 1)[0].split(b" ")[1])
    except (IndexError, ValueError):
        return 0


def rewrite_connection(head: bytes) -> bytes:
    lines = head.split(b"\r\n")
    out = [lines[0]]
    for line in lines[1:]:
        low = line.lower()
        if low.startswith(b"connection:") or low.startswith(b"proxy-connection:") \
                or low.startswith(b"keep-alive:"):
            continue
        out.append(line)
    out.append(b"Connection: close")
    return b"\r\n".join(out)


def pump(src: socket.socket, dst: socket.socket) -> None:
    """把客户端剩下的字节（请求体）往上游搬。"""
    try:
        while True:
            data = src.recv(65536)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass


def relay(client: socket.socket, up: socket.socket) -> None:
    """读上游响应头（跳过 1xx）→ 改 Connection → 头和正文原样刷给客户端。"""
    while True:
        blob = read_head(up, timeout=IO_TIMEOUT)
        if blob is None:
            return
        head, rest = split_head(blob)
        code = status_code(head)
        if code == 101:
            # 协议升级：头原样（含 Connection: Upgrade / Upgrade: websocket），
            # 之后这条连接就是纯字节流，交给下面的循环
            try:
                client.sendall(head + b"\r\n\r\n")
                if rest:
                    client.sendall(rest)
            except OSError:
                return
            break
        if 100 <= code < 200:
            try:
                client.sendall(head + b"\r\n\r\n")
                if rest:
                    client.sendall(rest)
            except OSError:
                return
            continue
        try:
            client.sendall(rewrite_connection(head) + b"\r\n\r\n")
            if rest:
                client.sendall(rest)
        except OSError:
            return
        break

    up.settimeout(IO_TIMEOUT)
    while True:
        try:
            data = up.recv(65536)
        except (socket.timeout, OSError):
            return
        if not data:
            return
        try:
            client.sendall(data)
        except OSError:
            return


def handle(client: socket.socket, addr) -> None:
    up = None
    try:
        blob = read_head(client)
        if blob is None:
            return
        head, rest = split_head(blob)
        lines = head.split(b"\r\n")
        try:
            method, path, proto = lines[0].decode("latin-1").split(" ")
        except ValueError:
            return

        bare = path.split("?", 1)[0]
        extra_auth = b""
        hermes = bare == PREFIX or bare.startswith(PREFIX + "/")
        webapp = bare == WEB_PREFIX or bare.startswith(WEB_PREFIX + "/")
        legacy = bare == LEGACY_PREFIX or bare.startswith(LEGACY_PREFIX + "/")
        if bare == "/" and ROOT_TARGET == "web":
            webapp = True                      # 首页交给新前端
        elif bare == LEGACY_PREFIX and ROOT_TARGET == "web":
            # /files 补斜杠（老页面的相对链接才不会跑偏）
            client.sendall((f"HTTP/1.1 302 Found\r\nLocation: {LEGACY_PREFIX}/\r\n"
                            "Content-Length: 0\r\nConnection: close\r\n\r\n").encode())
            return
        if webapp and bare in (WEB_PREFIX,) :
            loc = WEB_PREFIX + "/"
            if "?" in path:
                loc += "?" + path.split("?", 1)[1]
            client.sendall((f"HTTP/1.1 302 Found\r\nLocation: {loc}\r\nContent-Length: 0\r\n"
                            "Connection: close\r\n\r\n").encode())
            return
        if hermes and bare == PREFIX:
            # 补斜杠：页面里的相对路径（api/…）才会正确解析
            loc = PREFIX + "/"
            if "?" in path:
                loc += "?" + path.split("?", 1)[1]
            client.sendall((f"HTTP/1.1 302 Found\r\nLocation: {loc}\r\nContent-Length: 0\r\n"
                            "Connection: close\r\n\r\n").encode())
            return

        if webapp:
            new_path = "/" if bare == "/" else (path[len(WEB_PREFIX):] or "/")
            target = hostport(WEB)
        elif legacy:
            new_path = path[len(LEGACY_PREFIX):] or "/"
            target = hostport(DUFS)
        elif hermes:
            new_path = path[len(PREFIX):] or "/"
            target = hostport(HERMES)
        elif bare.startswith(LINK_PREFIX):
            # 签名直链：校验通过后带 Basic 转发给 dufs，客户端手里没有口令
            parts = bare[len(LINK_PREFIX):].split("/", 2)
            if len(parts) < 3:
                return _deny(client, 404, "bad link")
            exp_s, sig, tail = parts     # 注意别叫 rest —— 那是请求体，覆盖了会炸
            source, _, qpath = tail.partition("/")
            path = "/" + urllib.parse.unquote(qpath)
            try:
                exp = int(exp_s)
            except ValueError:
                return _deny(client, 404, "bad link")
            if not check_link(exp, sig, source, path):
                return _deny(client, 403, "link expired or invalid")
            new_path = "/" + qpath
            target = hostport(DUFS)
            extra_auth = DUFS_AUTH
        elif bare == API_PREFIX or bare.startswith(API_PREFIX + "/") or bare in WS_PATHS:
            # API 与 WebSocket：路径原样透传，不剥前缀
            new_path = path
            target = hostport(API)
        else:
            new_path = path
            target = hostport(DUFS)

        lines[0] = f"{method} {new_path} {proto}".encode("latin-1")
        # WebSocket 握手：Upgrade 头必须原样上去，且不能补 Connection: close
        upgrade = any(l.lower().startswith(b"upgrade:") for l in lines[1:])
        up_head = [lines[0]]
        for line in lines[1:]:
            low = line.lower()
            if not upgrade and (low.startswith(b"connection:")
                                or low.startswith(b"proxy-connection:")):
                continue
            up_head.append(line)
        if not upgrade:
            up_head.append(b"Connection: close")
        if extra_auth:
            up_head.append(b"Authorization: " + extra_auth)

        try:
            up = socket.create_connection(target, timeout=15)
        except OSError as exc:
            log(f"上游 {target} 连不上: {exc}")
            client.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 15\r\n"
                           b"Connection: close\r\n\r\nupstream error\n")
            return

        up.sendall(b"\r\n".join(up_head) + b"\r\n\r\n")
        if rest:
            up.sendall(rest)

        # 上传大文件时请求体还在路上，后台继续搬
        threading.Thread(target=pump, args=(client, up), daemon=True).start()
        relay(client, up)
    except OSError:
        pass
    finally:
        for s in (up, client):
            if not s:
                continue
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                s.close()
            except OSError:
                pass


def _deny(client: socket.socket, code: int, msg: str) -> None:
    body = msg.encode()
    try:
        client.sendall(
            f"HTTP/1.1 {code} Denied\r\nContent-Type: text/plain\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode() + body
        )
    except OSError:
        pass


def load_secret() -> bytes:
    try:
        with open(SECRET_FILE, "rb") as f:
            return f.read().strip()
    except OSError:
        log(f"读不到密钥 {SECRET_FILE}，/f/ 直链将全部拒绝")
        return b""


def load_dufs_auth() -> bytes:
    """从 share.yaml 的 auth 行取 user:pass（dufs 本体仍要 Basic）。"""
    try:
        with open(SHARE_YAML, encoding="utf-8", errors="replace") as f:
            txt = f.read()
    except OSError:
        return b""
    m = re.search(r"-\s*([^:@\s]+):([^@\s]+)@/", txt)
    if not m:
        return b""
    return b"Basic " + base64.b64encode(f"{m.group(1)}:{m.group(2)}".encode())


def check_link(exp: int, sig: str, source: str, path: str) -> bool:
    """校验 FastAPI 签的直链凭证（与 auth.sign_path 同算法）。"""
    secret = SECRET
    if not secret:
        return False
    if exp < int(time.time()):
        return False
    msg = f"{path}|{exp}|{source}".encode()
    want = hmac.new(secret, msg, hashlib.sha256).hexdigest()[:32]
    return hmac.compare_digest(want, sig)


SECRET = load_secret()
DUFS_AUTH = load_dufs_auth()
WEB = "127.0.0.1:" + os.environ.get("FRONT_WEB_PORT", "15101")


def main() -> None:
    lh, lp = hostport(LISTEN)
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((lh, lp))
    srv.listen(256)
    log(f"front on {lh}:{lp}  dufs→{DUFS}  {PREFIX}→{HERMES}  {API_PREFIX}→{API}")
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()

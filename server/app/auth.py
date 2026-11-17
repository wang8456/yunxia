"""认证：口令 → 设备令牌（JWT）。

客户端手里只有一个字符串 token，各来源的 Basic 口令全部留在服务端。
没配口令时服务退化成「内网免登录」，只读和写都放行（单人自用场景）；
配了口令则读接口仍可匿名（手机装上就能看），写接口必须带令牌。
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from typing import Annotated

import jwt
from fastapi import Depends, Header, HTTPException, Query, Request, status

from .config import CFG

ALGO = "HS256"
PBKDF2_ROUNDS = 200_000


# ---------------- 口令 ----------------

def hash_password(password: str, salt: str | None = None) -> str:
    """返回 ``pbkdf2$<salt>$<hex>``，可直接写进 config 的 auth.password。"""
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), PBKDF2_ROUNDS)
    return f"pbkdf2${salt}${digest.hex()}"


def verify_password(password: str) -> bool:
    stored = CFG.password or ""
    if not stored:
        return False
    if stored.startswith("pbkdf2$"):
        try:
            _, salt, digest = stored.split("$", 2)
        except ValueError:
            return False
        calc = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), PBKDF2_ROUNDS)
        return hmac.compare_digest(calc.hex(), digest)
    return hmac.compare_digest(password, stored)


def basic_ok(authorization: str | None) -> bool:
    """``Authorization: Basic base64(user:pass)`` —— 对话接口就是这么带口令的。"""
    if not CFG.password:
        return True
    if not authorization or not authorization.lower().startswith("basic "):
        return False
    import base64

    try:
        raw = base64.b64decode(authorization[6:].strip()).decode("utf-8", "replace")
    except Exception:  # noqa: BLE001
        return False
    _, _, pwd = raw.partition(":")
    return verify_password(pwd)


# ---------------- 令牌 ----------------

def make_token(device: str) -> tuple[str, int]:
    now = int(time.time())
    exp = now + CFG.token_days * 86400
    payload = {"sub": device, "iat": now, "exp": exp, "typ": "device"}
    return jwt.encode(payload, CFG.token_secret, algorithm=ALGO), exp


def decode_token(token: str) -> dict:
    try:
        return jwt.decode(token, CFG.token_secret, algorithms=[ALGO])
    except jwt.ExpiredSignatureError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "登录已过期，请重新登录")
    except jwt.InvalidTokenError:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "令牌无效")


def sign_path(path: str, expires: int, extra: str = "") -> str:
    """给直链签一个短期凭证（播放器 / <img> 带不了 Authorization 头）。"""
    msg = f"{path}|{expires}|{extra}".encode()
    return hmac.new(CFG.token_secret.encode(), msg, hashlib.sha256).hexdigest()[:32]


def check_path_sig(path: str, expires: int, sig: str, extra: str = "") -> bool:
    if expires < int(time.time()):
        return False
    return hmac.compare_digest(sign_path(path, expires, extra), sig)


# ---------------- 依赖 ----------------

def current_device(
    request: Request,
    authorization: Annotated[str | None, Header()] = None,
    t: Annotated[str | None, Query(description="令牌（直链/播放器用）")] = None,
) -> str:
    token = t
    if not token and authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:]
    if not token:
        if not CFG.password:
            return "open"                      # 没设口令：内网自用，全部放行
        if request is not None and request.method in ("GET", "HEAD"):
            return "anon"                      # 读接口放开，写接口要登录
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "需要登录")
    return decode_token(token)["sub"]


Device = Annotated[str, Depends(current_device)]


def require_write(device: str) -> None:
    """写操作守卫：口令都没设时也允许（单人内网部署）。"""
    if CFG.password and device == "anon":
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "需要登录")

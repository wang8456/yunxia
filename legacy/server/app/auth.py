"""认证：口令 → 设备令牌（JWT）。口令只存哈希，令牌 30 天。

客户端手里只有一个字符串 token，各来源的 Basic 口令全部留在 NAS 上。
"""

from __future__ import annotations

import hashlib
import hmac
import secrets
import time
from typing import Annotated

import jwt
from fastapi import Depends, Header, HTTPException, Query, status

from .config import CFG

ALGO = "HS256"
PBKDF2_ROUNDS = 200_000


# ---------------- 口令 ----------------

def hash_password(password: str, salt: str | None = None) -> tuple[str, str]:
    salt = salt or secrets.token_hex(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt.encode(), PBKDF2_ROUNDS)
    return digest.hex(), salt


def verify_password(password: str) -> bool:
    stored = getattr(CFG, "password_hash", "") or ""
    salt = getattr(CFG, "password_salt", "") or ""
    if stored and salt:
        digest, _ = hash_password(password, salt)
        return hmac.compare_digest(digest, stored)
    # 没设哈希时退回源口令（首次引导用），只比对第一个可用源
    for s in CFG.sources:
        if s.password and hmac.compare_digest(password, s.password):
            return True
    return False


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
    """给直链签一个短期凭证（播放器/图片标签带不了 Authorization 头）。"""
    msg = f"{path}|{expires}|{extra}".encode()
    return hmac.new(CFG.token_secret.encode(), msg, hashlib.sha256).hexdigest()[:32]


def check_path_sig(path: str, expires: int, sig: str, extra: str = "") -> bool:
    if expires < int(time.time()):
        return False
    return hmac.compare_digest(sign_path(path, expires, extra), sig)


# ---------------- 依赖 ----------------

def current_device(
    authorization: Annotated[str | None, Header()] = None,
    t: Annotated[str | None, Query(description="令牌（直链/播放器用）")] = None,
) -> str:
    token = t
    if not token and authorization and authorization.lower().startswith("bearer "):
        token = authorization[7:]
    if not token:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "需要登录")
    return decode_token(token)["sub"]


Device = Annotated[str, Depends(current_device)]

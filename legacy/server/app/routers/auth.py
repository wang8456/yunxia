"""登录 / 会话。"""

from __future__ import annotations

from fastapi import APIRouter, HTTPException, status
from pydantic import BaseModel, Field

from ..auth import Device, make_token, verify_password

router = APIRouter(prefix="/auth", tags=["auth"])


class LoginIn(BaseModel):
    password: str = Field(min_length=1, max_length=128)
    device: str = Field(default="unknown", max_length=64, description="设备名，方便以后踢设备")


class LoginOut(BaseModel):
    token: str
    expires_at: int
    device: str


@router.post("/login", response_model=LoginOut)
def login(body: LoginIn) -> LoginOut:
    if not verify_password(body.password):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "口令不对")
    token, exp = make_token(body.device)
    return LoginOut(token=token, expires_at=exp, device=body.device)


@router.get("/me")
def me(device: Device) -> dict:
    return {"device": device}

"""对话后端（``/hermes/api/*``）—— 任意 OpenAI 兼容服务的转发层。

客户端（网页 / App）用的是这套约定，所以路径别改：

  POST /chat          {input:[{type:'input_text',text}], previous_response_id?}
                       → SSE（response.created / response.output_text.delta / response.completed），
                         响应头 X-Run-Id 就是这一轮的全局 id
  GET  /cancel?id=    中断一轮（真的断开上游连接）
  GET  /runs?limit=   最近几轮（断线重连时补齐）
  GET/POST /log       多端共享的对话记录（ops 增量同步）
  GET  /log?since=0   全量
  POST /log/clear · /log/del
  POST /upload?name=&kind=   原始字节体，落盘到 data/media/<日期>/
  GET  /dl?path=     取回附件
  GET  /thumb?path=&w=  缩略图

上游配置在 config.json 的 ``chat`` 段（base / api_key / model）。
**默认关闭**：没有 api_key 时这些接口一律 503，前端也就不显示这一页。
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import time
import uuid
from pathlib import Path
from typing import AsyncIterator

import httpx
from fastapi import APIRouter, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, StreamingResponse

from .. import db
from ..auth import basic_ok, decode_token
from ..config import CFG

router = APIRouter(tags=["chat"])

# 正在跑的轮次：rid → {"stop": Event}
LIVE: dict[str, dict] = {}


def _auth(authorization: str | None) -> None:
    """对话接口既认 Basic 口令（网页/App 就是这么带的），也认 Bearer 设备令牌。"""
    if basic_ok(authorization):
        return
    if authorization and authorization.lower().startswith("bearer "):
        decode_token(authorization[7:])
        return
    raise HTTPException(401, "对话口令不对")


def _ensure_enabled() -> None:
    if not (CFG.chat.enabled and CFG.chat.base and CFG.chat.api_key):
        raise HTTPException(
            503,
            "对话功能未启用：在 config.json 的 chat 段填上 base / api_key / model，"
            "并把 enabled 改成 true，然后重启服务。",
        )


def _new_id() -> str:
    return "r" + uuid.uuid4().hex[:24]


def _upstream_url() -> str:
    base = CFG.chat.base.rstrip("/")
    if base.endswith("/chat/completions"):
        return base
    return base + "/chat/completions"


def _sse(payload: dict) -> str:
    return "data: " + json.dumps(payload, ensure_ascii=False) + "\n\n"


# ---------------------------------------------------------------- /chat

@router.post("/chat")
async def chat(request: Request, authorization: str | None = Header(default=None)):
    _auth(authorization)
    _ensure_enabled()

    body = await request.json()
    text = ""
    for item in body.get("input") or []:
        if isinstance(item, dict) and item.get("type") in ("input_text", "text"):
            text += item.get("text") or ""
    text = text.strip()
    if not text:
        raise HTTPException(400, "No user message found in input")

    prev = (body.get("previous_response_id") or "").strip() or None
    if prev and not db.conv_get(prev):
        # 上下文过期（服务重启 / 换了数据库）：让客户端丢掉 id 重开一轮
        raise HTTPException(502, "Previous response not found")

    model = body.get("model") or CFG.chat.model or "gpt-4o-mini"
    rid = _new_id()
    msgs: list[dict] = []
    if CFG.chat.system:
        msgs.append({"role": "system", "content": CFG.chat.system})
    msgs.extend(db.conv_chain(prev, limit=int(CFG.chat.max_turns)))
    msgs.append({"role": "user", "content": text})

    db.conv_new(rid, prev, model, text)
    db.log_push([{"id": rid, "ts": time.time(), "role": "assistant", "text": "",
                  "think": "", "steps": [], "rid": rid, "status": "running"}])
    stop = {"flag": False}
    LIVE[rid] = stop

    async def stream() -> AsyncIterator[str]:
        acc, think = [], []
        status = "done"
        payload = {
            "model": model,
            "messages": msgs,
            "stream": True,
        }
        headers = {"Authorization": f"Bearer {CFG.chat.api_key}",
                   "Content-Type": "application/json"}
        yield _sse({"type": "response.created", "response": {"id": rid, "model": model}})
        try:
            async with httpx.AsyncClient(timeout=CFG.chat.timeout, trust_env=False) as c:
                async with c.stream("POST", _upstream_url(), json=payload,
                                    headers=headers) as r:
                    if r.status_code >= 400:
                        detail = (await r.aread()).decode("utf-8", "replace")[:400]
                        status = "failed"
                        yield _sse({"type": "response.failed", "response": {
                            "id": rid, "status": "failed",
                            "error": f"上游 {r.status_code}：{detail}"}})
                        return
                    async for line in r.aiter_lines():
                        if stop["flag"]:
                            status = "interrupted"
                            break
                        if not line.startswith("data:"):
                            continue
                        data = line[5:].strip()
                        if not data or data == "[DONE]":
                            continue
                        try:
                            ev = json.loads(data)
                        except ValueError:
                            continue
                        choice = (ev.get("choices") or [{}])[0]
                        delta = choice.get("delta") or {}
                        piece = delta.get("content")
                        if piece:
                            acc.append(piece)
                            yield _sse({"type": "response.output_text.delta", "delta": piece})
                        reason = delta.get("reasoning_content") or delta.get("reasoning")
                        if reason:
                            think.append(reason)
                            yield _sse({"type": "response.reasoning_summary_text.delta",
                                        "delta": reason})
        except asyncio.CancelledError:
            status = "interrupted"
            raise
        except Exception as exc:  # noqa: BLE001
            status = "failed"
            yield _sse({"type": "response.failed", "response": {
                "id": rid, "status": "failed", "error": f"{type(exc).__name__}: {exc}"}})
        finally:
            LIVE.pop(rid, None)
            answer = "".join(acc)
            thought = "".join(think)
            if status == "done":
                yield _sse({"type": "response.completed", "response": {
                    "id": rid, "status": "completed", "model": model}})
            db.conv_update(rid, answer, thought, status)
            db.log_push([{"id": rid, "ts": time.time(), "role": "assistant",
                          "text": answer, "think": thought, "steps": [],
                          "rid": rid, "status": status}])
            yield "data: [DONE]\n\n"

    return StreamingResponse(
        stream(), media_type="text/event-stream",
        headers={"X-Run-Id": rid, "Cache-Control": "no-store",
                 "X-Accel-Buffering": "no"},
    )


@router.get("/cancel")
def cancel(id: str = Query(...), authorization: str | None = Header(default=None)):
    _auth(authorization)
    run = LIVE.get(id)
    if not run:
        return {"cancelled": False}
    run["flag"] = True
    return {"cancelled": True}


@router.get("/runs")
def runs(limit: int = Query(default=20, ge=1, le=100),
         authorization: str | None = Header(default=None)) -> dict:
    _auth(authorization)
    out = []
    for row in db.conv_recent(limit):
        out.append({
            "id": row["id"],
            "ts": row["ts"],
            "input": row["user"] or "",
            "text": row["text"] or "",
            "think": row["think"] or "",
            "done": row["status"] != "running",
            "status": row["status"],
        })
    return {"runs": out}


# ---------------------------------------------------------------- 对话记录

@router.get("/log")
def log_get(since: int = 0, authorization: str | None = Header(default=None)) -> dict:
    _auth(authorization)
    ops, cursor = db.log_since(since)
    return {"ops": ops, "cursor": cursor, "seq": cursor}


@router.post("/log")
async def log_post(request: Request, authorization: str | None = Header(default=None)) -> dict:
    _auth(authorization)
    body = await request.json()
    db.log_push(body.get("msgs") or [])
    return {"cursor": db.log_cursor()}


@router.post("/log/clear")
def log_clear(authorization: str | None = Header(default=None)) -> dict:
    _auth(authorization)
    return {"cursor": db.log_clear()}


@router.post("/log/del")
async def log_del(request: Request, authorization: str | None = Header(default=None)) -> dict:
    _auth(authorization)
    body = await request.json()
    ids = body.get("ids") or ([body["id"]] if body.get("id") else [])
    return {"deleted": db.log_del([str(i) for i in ids])}


# ---------------------------------------------------------------- 附件

_SAFE = re.compile(r'[\\/:*?"<>|\x00-\x1f]')


def _media_root() -> Path:
    return CFG.media_dir.resolve()


def _safe_name(name: str) -> str:
    name = _SAFE.sub("_", os.path.basename(name or "")).strip(" .")
    return name[:120] or f"file-{int(time.time())}"


def _allowed(path: Path) -> bool:
    """白名单：只允许取 data/media 下的文件和本地来源根目录里的文件。"""
    p = path.resolve()
    roots = [_media_root()] + [Path(s.resolved_root()).resolve()
                               for s in CFG.sources if s.kind == "local"]
    for root in roots:
        try:
            p.relative_to(root)
            return True
        except ValueError:
            continue
    return False


@router.post("/upload")
async def upload(request: Request, name: str = "", kind: str = "",
                 authorization: str | None = Header(default=None)) -> dict:
    _auth(authorization)
    data = await request.body()
    if not data:
        raise HTTPException(400, "空文件")
    day = time.strftime("%Y-%m-%d")
    target_dir = _media_root() / day
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / _safe_name(name)
    if target.exists():
        target = target_dir / f"{target.stem}-{uuid.uuid4().hex[:4]}{target.suffix}"
    target.write_bytes(data)
    return {"path": str(target), "name": target.name, "size": len(data), "kind": kind}


@router.get("/dl")
def download(path: str = Query(...), authorization: str | None = Header(default=None)):
    _auth(authorization)
    p = Path(path).expanduser()
    if not p.is_file() or not _allowed(p):
        raise HTTPException(404, "文件不存在或不在允许的目录里")
    return FileResponse(p, filename=p.name)


@router.get("/thumb")
def thumb(path: str = Query(...), w: int = 320,
          authorization: str | None = Header(default=None)):
    _auth(authorization)
    p = Path(path).expanduser()
    if not p.is_file() or not _allowed(p):
        raise HTTPException(404, "文件不存在或不在允许的目录里")
    w = max(48, min(1024, w))
    out_dir = CFG.thumb_dir / "chat"
    out_dir.mkdir(parents=True, exist_ok=True)
    key = f"{p}|{w}|{int(p.stat().st_mtime)}"
    import hashlib

    out = out_dir / (hashlib.sha1(key.encode()).hexdigest()[:20] + ".jpg")
    if not out.exists():
        try:
            from PIL import Image, ImageOps
        except Exception:  # noqa: BLE001
            return FileResponse(p)
        try:
            with Image.open(p) as im:
                im = ImageOps.exif_transpose(im)
                if im.mode not in ("RGB", "L"):
                    im = im.convert("RGB")
                im.thumbnail((w, w * 4), Image.LANCZOS)
                im.save(out, "JPEG", quality=82, optimize=True)
        except Exception:  # noqa: BLE001    解码不了就回原图，别让对话裂图
            return FileResponse(p)
    return FileResponse(out, media_type="image/jpeg",
                        headers={"Cache-Control": "private, max-age=604800"})

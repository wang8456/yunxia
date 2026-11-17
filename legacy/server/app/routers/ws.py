"""WebSocket：/ws?t=<token>&since=<seq>

协议（客户端只需实现三件事）：
  * 连上先收 {"type":"hello","seq":N}
  * since>0 时随后收 {"type":"replay","events":[...]}（最多 200 条）
  * 之后收 {"type":"fs.changed",...}；服务端 25s 发一次 ping，客户端回 pong
"""

from __future__ import annotations

import asyncio
import logging

from fastapi import APIRouter, Query, WebSocket, WebSocketDisconnect

from ..auth import decode_token
from ..config import CFG
from ..watch import Bus

log = logging.getLogger("yunxia.ws")
router = APIRouter()

BUS = Bus(CFG.data_root)

PING_EVERY = 25
IDLE_LIMIT = 75


@router.websocket("/ws")
async def ws_endpoint(ws: WebSocket, t: str | None = Query(None), since: int = 0):
    # 先 accept 再关，客户端才读得到 4401（直接 close 只会收到一个 HTTP 403）
    await ws.accept()
    if not t:
        await ws.close(code=4401, reason="need token")
        return
    try:
        device = decode_token(t)["sub"]
    except Exception:  # noqa: BLE001
        await ws.close(code=4401, reason="bad token")
        return

    BUS.attach_loop(asyncio.get_running_loop())
    BUS.start()

    q = BUS.subscribe()
    await ws.send_json({"type": "hello", "seq": BUS.seq, "device": device})
    for ev in BUS.replay(since):
        await ws.send_json(ev)

    last_seen = asyncio.get_running_loop().time()

    async def reader():
        nonlocal last_seen
        while True:
            msg = await ws.receive_text()
            last_seen = asyncio.get_running_loop().time()
            if msg == "pong":
                continue

    read_task = asyncio.create_task(reader())
    try:
        while True:
            try:
                ev = await asyncio.wait_for(q.get(), timeout=PING_EVERY)
                await ws.send_json(ev)
            except asyncio.TimeoutError:
                now = asyncio.get_running_loop().time()
                if now - last_seen > IDLE_LIMIT:
                    log.info("客户端 %s 超时未回 pong，断开", device)
                    break
                await ws.send_json({"type": "ping"})
            if read_task.done():
                break
    except (WebSocketDisconnect, RuntimeError):
        pass
    finally:
        read_task.cancel()
        BUS.unsubscribe(q)
        try:
            await ws.close()
        except Exception:  # noqa: BLE001
            pass

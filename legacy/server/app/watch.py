"""实时事件：inotify 监听共享盘 → 事件总线（带 seq 的环形缓冲）。

为什么自己监听而不是问 dufs：dufs 的 `?search`/`?q` 是坏的，也没有事件推送；
共享盘就是 NAS 本地磁盘，inotify 最直接。

去抖：一个 copy 操作会连发 create/write/write/close，200ms 内同名同路径的
write 合并成一条，避免客户端被刷屏。
"""

from __future__ import annotations

import asyncio
import logging
import os
import threading
import time
from collections import deque
from dataclasses import dataclass, field

from watchdog.events import FileSystemEventHandler
from watchdog.observers import Observer

log = logging.getLogger("yunxia.watch")

RING = 200          # 断线补发最多 200 条
DEBOUNCE = 0.25     # 秒


@dataclass
class Event:
    type: str = "fs.changed"
    source: str = "nas"
    path: str = "/"
    name: str = ""
    op: str = "write"
    is_dir: bool = False
    seq: int = 0
    ts: float = field(default_factory=time.time)

    def as_dict(self) -> dict:
        return {
            "type": self.type, "source": self.source, "path": self.path,
            "name": self.name, "op": self.op, "is_dir": self.is_dir,
            "seq": self.seq, "ts": self.ts,
        }


class Bus:
    """进程内事件总线：环形缓冲 + 订阅者队列。"""

    def __init__(self, root: str):
        self.root = root
        self.seq = 0
        self.ring: deque[Event] = deque(maxlen=RING)
        self._subs: set[asyncio.Queue] = set()
        self._lock = threading.Lock()
        self._loop: asyncio.AbstractEventLoop | None = None
        self._observer: Observer | None = None
        self._recent: dict[tuple[str, str], float] = {}
        self.hooks: list = []       # 非 WebSocket 的订阅者（索引器）

    # ---- 生命周期 ----
    def attach_loop(self, loop: asyncio.AbstractEventLoop) -> None:
        self._loop = loop

    def start(self) -> None:
        if self._observer is not None or not os.path.isdir(self.root):
            return
        handler = _Handler(self)
        obs = Observer()
        obs.schedule(handler, self.root, recursive=True)
        obs.daemon = True
        obs.start()
        self._observer = obs
        log.info("inotify 监听已启动: %s", self.root)

    def stop(self) -> None:
        if self._observer:
            self._observer.stop()
            self._observer.join(timeout=3)
            self._observer = None

    # ---- 订阅 ----
    def subscribe(self) -> asyncio.Queue:
        q: asyncio.Queue = asyncio.Queue(maxsize=256)
        self._subs.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue) -> None:
        self._subs.discard(q)

    def replay(self, since: int) -> list[dict]:
        if not since:
            return []
        return [e.as_dict() for e in self.ring if e.seq > since]

    # ---- 发布 ----
    def publish(self, ev: Event, from_thread: bool = False) -> None:
        with self._lock:
            self.seq += 1
            ev.seq = self.seq
            self.ring.append(ev)
        if from_thread and self._loop:
            self._loop.call_soon_threadsafe(self._fanout, ev)
        else:
            self._fanout(ev)

    def _fanout(self, ev: Event) -> None:
        if self.hooks:
            payload = ev.as_dict()
            for hook in self.hooks:
                try:
                    hook(payload)
                except Exception:      # noqa: BLE001  钩子出错不能拖垮推送
                    log.exception("事件钩子失败")
        dead = []
        for q in self._subs:
            try:
                q.put_nowait(ev.as_dict())
            except asyncio.QueueFull:
                dead.append(q)      # 客户端太慢：丢掉它，让它重连补发
        for q in dead:
            self._subs.discard(q)

    def report(self, abs_src: str, is_dir: bool, op: str) -> None:
        rel = os.path.relpath(abs_src, self.root)
        if rel.startswith(".."):
            return
        raw = "/" if rel == "." else "/" + rel.replace(os.sep, "/")
        directory, name = os.path.split(raw.rstrip("/"))
        if not name:
            return
        key = (raw, op)
        now = time.time()
        if op == "write" and now - self._recent.get(key, 0) < DEBOUNCE:
            return                          # 同一次写盘产生的连发事件，合并
        self._recent[key] = now
        if len(self._recent) > 2000:
            self._recent.clear()
        self.publish(Event(path=directory or "/", name=name,
                           op=op, is_dir=is_dir), from_thread=True)


class _Handler(FileSystemEventHandler):
    def __init__(self, bus: Bus):
        self.bus = bus

    def on_created(self, event):
        self.bus.report(event.src_path, event.is_directory, "create")

    def on_deleted(self, event):
        self.bus.report(event.src_path, event.is_directory, "delete")

    def on_modified(self, event):
        self.bus.report(event.src_path, event.is_directory, "write")

    def on_moved(self, event):
        self.bus.report(event.dest_path, event.is_directory, "move")

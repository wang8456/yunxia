"""听译任务管理：排队 → 子进程转写 → 可选翻译 → 落盘。

状态机：``queued → asr → translating → done``，异常进 ``error``，用户取消进 ``cancelled``。

落盘（``data/subs/``）：

* ``<id>.json``        任务的最终形态（段落、语言、时长、状态）
* ``<id>.part.json``   转写中的中间进度（子进程写，父进程读）
* ``<id>.spec.json``   交给子进程的参数（用完即删）

**父进程只做调度**：真正吃内存的是 ``app.subs_worker`` 那个子进程，
所以 whisper 崩了、卡住了，API 照样能响应，``kill`` 掉再重来即可。
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from collections import deque

from .auth import sign_path
from .config import CFG
from .models import FileEntry  # noqa: F401  (仅类型参考)

log = logging.getLogger("yunxia.subs")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))   # server/
LINK_TTL = 6 * 3600

JOBS: dict[str, dict] = {}
_QUEUE: deque[str] = deque()
_RUN: dict[str, subprocess.Popen] = {}
# RLock：_start_next 持锁调用 _spawn，而 _spawn 自己也要登记进程——
# 用普通 Lock 会在这里自己把自己锁死（调度线程挂着、任务永远停在 asr 0%）
_LOCK = threading.RLock()
_STARTED = False

# 翻译一次送多少行给模型（太大容易整段跑偏，太小又慢）
TR_BATCH = 24


# ---------------------------------------------------------------- 工具

def job_id(source: str, path: str) -> str:
    return hashlib.sha1(f"{source}|{path}".encode()).hexdigest()[:16]


def _path(jid: str) -> str:
    return str(CFG.subs_dir / f"{jid}.json")


def _part_path(jid: str) -> str:
    return str(CFG.subs_dir / f"{jid}.part.json")


def _spec_path(jid: str) -> str:
    return str(CFG.subs_dir / f"{jid}.spec.json")


def _write(path: str, data: dict) -> None:
    tmp = f"{path}.tmp{os.getpid()}.{threading.get_ident()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False)
    os.replace(tmp, path)


def _read(path: str) -> dict | None:
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def _media_target(source: str, path: str) -> str:
    """本地源给磁盘路径；远端源给一条签名 http 直链（子进程直接 av.open 它）。"""
    from .adapters import get_adapter

    ad = get_adapter(source)
    abs_path = ad.abs_path(path)
    if abs_path:
        return abs_path
    exp = int(time.time()) + LINK_TTL
    sig = sign_path(path, exp, extra=source)
    q = urllib.parse.urlencode({"source": source, "path": path, "exp": exp, "sig": sig})
    base = (CFG.public_base or f"http://127.0.0.1:{CFG.port}").rstrip("/")
    return f"{base}/api/v1/fs/raw?{q}"


# ---------------------------------------------------------------- 任务

def _public(job: dict) -> dict:
    segs = job.get("segs") or []
    return {
        "id": job["id"],
        "name": job.get("name") or (job.get("path") or "").rsplit("/", 1)[-1],
        "source": job.get("source") or "",
        "path": job.get("path") or "",
        "state": job.get("state") or "queued",
        "pct": round(float(job.get("pct") or 0), 1),
        "msg": job.get("msg") or "",
        "lang": job.get("lang") or "",
        "dur": round(float(job.get("dur") or 0), 1),
        "segments": len(segs),
        "pending": sum(1 for s in segs if len(s) > 3 and not s[3]),
        "model": job.get("model") or "",
        "created": job.get("created") or 0,
        "error": job.get("error") or "",
    }


def list_jobs() -> list[dict]:
    load_all()
    return sorted((_public(j) for j in JOBS.values()),
                  key=lambda j: -(j.get("created") or 0))


def get(jid: str) -> dict | None:
    load_all()
    j = JOBS.get(jid)
    return _public(j) if j else None


def segments(jid: str, since: int = 0) -> tuple[list, dict] | None:
    load_all()
    j = JOBS.get(jid)
    if not j:
        return None
    segs = j.get("segs") or []
    return (segs[since:] if since else segs), _public(j)


def load_all() -> None:
    """启动/首次访问时把磁盘上的任务读回来（转写中的一律标成已停止）。"""
    if JOBS:
        return
    with _LOCK:
        if JOBS:
            return
        try:
            names = [n for n in os.listdir(CFG.subs_dir) if n.endswith(".json")]
        except OSError:
            return
        for name in names:
            if name.endswith((".part.json", ".spec.json")):
                continue
            data = _read(str(CFG.subs_dir / name))
            if not data or "id" not in data:
                continue
            jid = data["id"]
            if data.get("state") in ("queued", "asr", "translating"):
                data["state"] = "cancelled"
                data["msg"] = "服务重启过，这条转写已中断"
            JOBS[jid] = data


def add(source: str, path: str, name: str = "", lang: str = "") -> dict:
    """建任务（同一条视频重复提交就是复用；跑着一律拒绝重来）。"""
    load_all()
    jid = job_id(source, path)
    with _LOCK:
        cur = JOBS.get(jid)
        if cur and cur.get("state") in ("queued", "asr", "translating"):
            return _public(cur)
        if cur and cur.get("state") == "done" and (cur.get("segs") or []):
            return _public(cur)
    job = {
        "id": jid,
        "source": source,
        "path": path,
        "name": name or path.rsplit("/", 1)[-1],
        "state": "queued",
        "pct": 0.0,
        "msg": "排队中",
        "lang": "",
        "dur": 0.0,
        "segs": [],
        "model": CFG.subs.model,
        "created": time.time(),
        "lang_hint": lang,
    }
    with _LOCK:
        JOBS[jid] = job
        _QUEUE.append(jid)
    _write(_path(jid), job)
    _ensure_started()
    return _public(job)


def cancel(jid: str) -> bool:
    load_all()
    with _LOCK:
        proc = _RUN.pop(jid, None)
        j = JOBS.get(jid)
        if j is None:
            return False
        if proc is not None:
            try:
                proc.kill()
            except OSError:
                pass
        j["state"] = "cancelled"
        j["msg"] = "已停止"
    _write(_path(jid), j)
    return True


def delete(jid: str) -> bool:
    cancel(jid)
    with _LOCK:
        JOBS.pop(jid, None)
    for p in (_path(jid), _part_path(jid), _spec_path(jid)):
        try:
            os.unlink(p)
        except OSError:
            pass
    return True


def set_max_active(n: int) -> int:
    CFG.subs.max_active = max(1, min(4, int(n)))
    return CFG.subs.max_active


# ---------------------------------------------------------------- 调度

def _ensure_started() -> None:
    global _STARTED
    if _STARTED:
        return
    with _LOCK:
        if _STARTED:
            return
        _STARTED = True
    threading.Thread(target=_loop, name="subs-sched", daemon=True).start()


def _running() -> int:
    return len(_RUN)


def _loop() -> None:
    while True:
        time.sleep(0.5)
        try:
            _poll_running()
            _start_next()
        except Exception:  # noqa: BLE001
            log.exception("听译调度出错")


def _start_next() -> None:
    with _LOCK:
        while _QUEUE and _running() < int(CFG.subs.max_active or 1):
            jid = _QUEUE.popleft()
            job = JOBS.get(jid)
            if not job or job.get("state") != "queued":
                continue
            try:
                _spawn(job)
            except Exception as exc:  # noqa: BLE001
                job["state"] = "error"
                job["error"] = f"{type(exc).__name__}: {exc}"
                job["msg"] = "启动转写失败"
                _write(_path(jid), job)


def _spawn(job: dict) -> None:
    jid = job["id"]
    spec = {
        "id": jid,
        "target": _media_target(job["source"], job["path"]),
        "model": CFG.subs.model,
        "device": CFG.subs.device,
        "compute_type": CFG.subs.compute_type,
        "language": job.get("lang_hint") or CFG.subs.language,
        "beam_size": CFG.subs.beam_size,
        "vad": CFG.subs.vad,
        "model_dir": CFG.subs.model_path,
        "out_dir": str(CFG.subs_dir),
    }
    _write(_spec_path(jid), spec)
    for p in (_part_path(jid),):       # 上一轮的残留进度别污染这一轮
        try:
            os.unlink(p)
        except OSError:
            pass
    job["state"] = "asr"
    job["msg"] = "转写中…"
    job["pct"] = 0.0
    _write(_path(jid), job)

    env = dict(os.environ)
    env.setdefault("PYTHONUNBUFFERED", "1")
    # 模型默认从 HF 拉；国内拉不动时在服务端设 HF_ENDPOINT=https://hf-mirror.com
    proc = subprocess.Popen(
        [sys.executable, "-m", "app.subs_worker", _spec_path(jid)],
        cwd=ROOT, env=env,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    with _LOCK:
        _RUN[jid] = proc


def _poll_running() -> None:
    with _LOCK:
        items = list(_RUN.items())
    for jid, proc in items:
        job = JOBS.get(jid)
        if job is None:
            continue
        part = _read(_part_path(jid))
        if part and part.get("state") == "asr":
            job["pct"] = float(part.get("pct") or 0)
            job["msg"] = part.get("msg") or job.get("msg")
            job["dur"] = float(part.get("dur") or job.get("dur") or 0)
            job["segs"] = job.get("segs") or []      # 段落只在收尾时一次性读入
        code = proc.poll()
        if code is None:
            continue
        out = b""
        try:
            out = proc.stdout.read() if proc.stdout else b""
        except Exception:  # noqa: BLE001
            pass
        with _LOCK:
            _RUN.pop(jid, None)
        final = _read(_path(jid))
        if final and final.get("state") == "done":
            job.update({
                "segs": final.get("segs") or [],
                "dur": float(final.get("dur") or job.get("dur") or 0),
                "lang": final.get("lang") or "",
                "state": "done", "pct": 100.0,
                "msg": final.get("msg") or "听译完成",
                "elapsed": final.get("elapsed"),
            })
            _write(_path(jid), job)
            _maybe_translate(job)
        elif final and final.get("state") == "error":
            job["state"] = "error"
            job["error"] = final.get("error") or "转写失败"
            job["msg"] = "转写失败"
            _write(_path(jid), job)
        elif job.get("state") != "cancelled":
            tail = out.decode("utf-8", "replace").strip().splitlines()[-3:]
            job["state"] = "error"
            job["error"] = "转写进程异常退出" + (f"：{' / '.join(tail)}" if tail else "")
            job["msg"] = "转写失败"
            _write(_path(jid), job)
        # 收尾：清掉中间文件
        for p in (_part_path(jid), _spec_path(jid)):
            try:
                os.unlink(p)
            except OSError:
                pass


# ---------------------------------------------------------------- 翻译

def _chat(messages: list[dict], cfg: dict) -> str:
    body = json.dumps({"model": cfg["model"], "messages": messages,
                       "temperature": 0.2}, ensure_ascii=False).encode()
    req = urllib.request.Request(
        cfg["base"].rstrip("/") + "/chat/completions", data=body,
        headers={"Authorization": f"Bearer {cfg['api_key']}",
                 "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=120) as r:   # noqa: S310
        data = json.loads(r.read())
    return (data.get("choices") or [{}])[0].get("message", {}).get("content", "") or ""


_REFUSE = ("无法翻译", "无法提供", "不能翻译", "无法完成", "抱歉，我不能", "I can't", "I cannot")


def _translate_block(lines: list[str], cfg: dict) -> list[str]:
    """一次一段，要求原样按行返回；条数不对或拒翻就整段当没翻到。"""
    prompt = (
        f"把下面 {len(lines)} 行字幕逐行翻译成{'简体中文' if cfg['to'] == 'zh' else cfg['to']}。\n"
        "规则：只输出译文，一行对应一行，行数必须完全一致；不要编号、不要解释、不要合并。"
    )
    content = _chat([
        {"role": "system", "content": prompt},
        {"role": "user", "content": "\n".join(lines)},
    ], cfg)
    out = [ln.strip() for ln in content.replace("\r", "").split("\n") if ln.strip()]
    if len(out) != len(lines):
        return ["" for _ in lines]
    if any(out[0].startswith(r) for r in _REFUSE):
        return ["" for _ in lines]
    return out


def translate(jid: str, to: str = "") -> dict:
    """整片翻译（后台线程跑，接口立刻返回）。"""
    load_all()
    job = JOBS.get(jid)
    if job is None:
        raise KeyError(jid)
    if job.get("state") != "done":
        raise RuntimeError("先转写完再翻译")
    cfg = CFG.subs.tr()
    if to:
        cfg["to"] = to
    if not (cfg["base"] and cfg["api_key"] and cfg["model"]):
        raise RuntimeError("没配翻译服务：在 config.json 里填 subs.translate 或 chat 段")

    def work() -> None:
        job["state"] = "translating"
        _write(_path(jid), job)
        segs = job.get("segs") or []
        todo = [i for i, s in enumerate(segs) if len(s) > 3 and not s[3]]
        done = 0
        for start in range(0, len(todo), TR_BATCH):
            idx = todo[start:start + TR_BATCH]
            lines = [segs[i][2] for i in idx]
            try:
                outs = _translate_block(lines, cfg)
            except Exception as exc:  # noqa: BLE001
                log.warning("翻译失败：%s", exc)
                outs = ["" for _ in idx]
            for i, text in zip(idx, outs):
                if text:
                    segs[i][3] = text
                    done += 1
            job["pct"] = round(100.0 * (start + len(idx)) / max(1, len(todo)), 1)
            job["msg"] = f"翻译中… {job['pct']}%"
            _write(_path(jid), job)
        job["state"] = "done"
        job["msg"] = f"听译完成 · {len(segs)} 句 · 译文 {sum(1 for s in segs if s[3])} 句"
        job["pct"] = 100.0
        _write(_path(jid), job)

    threading.Thread(target=work, name=f"subs-tr-{jid}", daemon=True).start()
    return _public(job)


def _maybe_translate(job: dict) -> None:
    """有翻译配置就顺手整片译掉（没配就只有原文）。"""
    cfg = CFG.subs.tr()
    if not (cfg["base"] and cfg["api_key"] and cfg["model"]):
        return
    if (job.get("lang") or "") in (cfg["to"], "zh") and cfg["to"] == "zh":
        # 本来就是中文，翻一遍只会得到原文
        return
    try:
        translate(job["id"])
    except Exception as exc:  # noqa: BLE001
        log.info("自动翻译跳过：%s", exc)


# ---------------------------------------------------------------- 导出

def srt(jid: str, trans: bool = True) -> str:
    load_all()
    job = JOBS.get(jid)
    if not job:
        raise KeyError(jid)
    segs = job.get("segs") or []

    def ts(sec: float) -> str:
        ms = int(round(float(sec) * 1000))
        h, ms = divmod(ms, 3600_000)
        m, ms = divmod(ms, 60_000)
        s, ms = divmod(ms, 1000)
        return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

    out = []
    for i, s in enumerate(segs, 1):
        orig = s[2] if len(s) > 2 else ""
        tr = s[3] if len(s) > 3 else ""
        out.append(str(i))
        out.append(f"{ts(s[0])} --> {ts(s[1])}")
        if trans and tr and tr != orig:
            out.append(tr)
            out.append(orig)       # 第二行放原文，播放器里就是双语字幕
        else:
            out.append(orig)
        out.append("")
    return "\n".join(out)


def for_path(source: str, path: str) -> dict:
    """播放器用：按 来源+路径 找字幕（没有返回 found=false）。"""
    load_all()
    jid = job_id(source, path)
    job = JOBS.get(jid)
    if not job or not job.get("segs"):
        return {"found": False}
    segs, pub = segments(jid, 0) or ([], {})
    return {"found": True, "id": jid, "lang": pub.get("lang") or "",
            "dur": pub.get("dur") or 0, "segments": segs}

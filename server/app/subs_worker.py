"""转写子进程（faster-whisper）。

为什么是子进程而不是线程：
whisper 吃内存（base int8 峰值 300–450MB，small 要 1GB+），模型加载失败、解码卡住
都会把宿主拖死。放子进程里，父进程只管看进度、超时可 kill，API 永远不会被拖垮。

父进程调用：``python -m app.subs_worker <spec.json>``
spec 里带 id / target(路径或 http 直链) / 模型参数 / 输出目录。

写文件节奏：
* 转写中 → ``<id>.part.json``（父进程每 0.5 秒读一次，算出百分比）
* 转写完 → ``<id>.json``（state=done，段落全在里面），父进程据此收尾
任何失败都往 ``<id>.json`` 写 state=error + 原因，父进程不用猜 stderr。
"""

from __future__ import annotations

import json
import os
import sys
import time
import traceback


def _write(path: str, data: dict) -> None:
    tmp = f"{path}.tmp{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(data, fh, ensure_ascii=False)
    os.replace(tmp, path)


def _duration(target: str) -> float:
    """拿时长：只解容器头，不 decode。失败就返回 0（进度改成按段落数估）。"""
    try:
        import av

        with av.open(target) as c:
            if c.duration:
                return float(c.duration / av.time_base)
            for s in c.streams:
                if s.type == "audio" and s.duration and s.time_base:
                    return float(s.duration * s.time_base)
    except Exception:  # noqa: BLE001
        pass
    return 0.0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("用法: python -m app.subs_worker <spec.json>", file=sys.stderr)
        return 2
    spec = json.loads(open(argv[1], encoding="utf-8").read())
    jid = spec["id"]
    out_dir = spec["out_dir"]
    final = os.path.join(out_dir, f"{jid}.json")
    part = os.path.join(out_dir, f"{jid}.part.json")

    try:
        from faster_whisper import WhisperModel
    except Exception as exc:  # noqa: BLE001
        _write(final, {"state": "error", "error":
                       f"没装 faster-whisper（{type(exc).__name__}）："
                       "在服务端执行 pip install -r requirements-subs.txt 再重启"})
        return 3

    target = spec["target"]
    try:
        # 先落一条进度：加载模型可能要十几秒（首次还要下 145MB），界面不能一直 0% 没动静
        _write(part, {"state": "asr", "pct": 0.0, "segs": 0,
                      "msg": "加载模型…", "dur": 0.0})
        dur = _duration(target)
        t0 = time.time()
        model = WhisperModel(
            spec.get("model") or "base",
            device=spec.get("device") or "auto",
            compute_type=spec.get("compute_type") or "int8",
            download_root=spec.get("model_dir") or None,
        )
        lang = (spec.get("language") or "auto").strip()
        segments, info = model.transcribe(
            target,
            language=None if lang in ("", "auto") else lang,
            beam_size=int(spec.get("beam_size") or 1),
            vad_filter=bool(spec.get("vad", True)),
            condition_on_previous_text=False,   # 长片里它能少重复，但会放大跑偏
        )
        segs: list[list] = []
        last_flush = 0.0
        for s in segments:
            text = (s.text or "").strip()
            if text:
                segs.append([round(float(s.start), 2), round(float(s.end), 2), text, ""])
            now = time.time()
            if now - last_flush > 1.0:      # 每秒落一次盘，父进程据此显示百分比
                last_flush = now
                end = segs[-1][1] if segs else 0.0
                pct = (end / dur * 100) if dur > 0 else min(95.0, len(segs) * 0.2)
                _write(part, {"state": "asr", "pct": round(min(99.0, pct), 1),
                              "segs": len(segs), "msg": f"转写中… 已到 {int(end // 60)} 分",
                              "dur": dur, "elapsed": round(now - t0, 1)})
        _write(final, {
            "state": "done", "segs": segs, "dur": dur,
            "lang": getattr(info, "language", "") or "",
            "elapsed": round(time.time() - t0, 1),
            "msg": f"听译完成 · {len(segs)} 句",
        })
        return 0
    except Exception as exc:  # noqa: BLE001
        _write(final, {"state": "error",
                       "error": f"{type(exc).__name__}: {exc}",
                       "trace": traceback.format_exc()[-1200:]})
        return 4


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

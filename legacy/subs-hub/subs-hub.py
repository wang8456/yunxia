#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""subs-hub.py —— NAS 上的听译中枢（任务表 + 字幕缓存 + DeepSeek 翻译）

分工：
  NAS（这台）= 存任务、存字幕、调 DeepSeek 翻译。轻活，一直开着。
  电脑       = 真正吃 CPU 的转写（ffmpeg 抽音 + whisper）。
连接方式：电脑主动来 NAS 拉活（出站 HTTP，局域网内），所以不用改 Windows 防火墙，也不走 Tailscale。

对手机（浏览器）：
  POST /job  {url,name,model}  → {id,state,reused}
  GET  /job/<id>               → {state,lang,done_until,msg,segments:[[起,止,原文,中文]]}
对电脑（asr-worker.py）：
  GET  /work?wait=25           → {id,url,model} 或 204
  POST /cue    {id,segs:[[s,e,text]],done_until,lang}
  POST /finish {id,lang,dur}
  POST /fail   {id,msg}
  GET  /health
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
JOBS = os.path.join(HERE, "jobs")
PORT = int(os.environ.get("HUB_PORT", "5092"))
DEEPSEEK_URL = "https://api.deepseek.com/chat/completions"
BIN = os.path.join(HERE, "bin")                       # 放静态 ffmpeg/ffprobe（ARM64）
AUDIO = os.path.join(HERE, "audio")                   # 抽好的音频缓存（16k 单声道 flac）
# dufs 的 /data 下面有几个独立 bind mount（影音库、Jav 是另外挂进来的），
# 所以本地路径要按挂载表挨个试，不能假设都在共享根里
SHARE_ROOTS = [
    ("影音库/", "/mnt/data/media/library/"),
    ("Jav/", "/mnt/data/media/movies/"),
    ("", "/mnt/data/share/"),
]
os.makedirs(AUDIO, exist_ok=True)
LANG_PREF = ["zho", "chi", "cmn", "yue", "kor", "jpn", "eng"]
W2L = {"zho": "zh", "chi": "zh", "cmn": "zh", "yue": "zh", "kor": "ko", "jpn": "ja",
       "eng": "en", "spa": "es", "ita": "it", "fra": "fr", "fre": "fr", "deu": "de", "rus": "ru"}
BATCH = 12
os.makedirs(JOBS, exist_ok=True)

CONF = os.path.join(HERE, "hub-config.json")
CFG = {"max_active": 3}          # 同时在管线里（排队+转写+翻译）的任务上限


def load_conf():
    try:
        d = json.load(open(CONF, encoding="utf-8"))
        if isinstance(d.get("max_active"), int) and d["max_active"] > 0:
            CFG["max_active"] = d["max_active"]
    except Exception:
        pass


def save_conf():
    try:
        tmp = CONF + ".tmp"
        json.dump(CFG, open(tmp, "w", encoding="utf-8"))
        os.replace(tmp, CONF)
    except Exception:
        pass


def active_count():
    return sum(1 for j in T.values() if j["state"] in ("queued", "asr", "translating"))


CORS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Expose-Headers": "Content-Type",
}


def load_key():
    for p in (os.path.join(HERE, ".env"), os.path.expanduser("~/.hermes/.env")):
        try:
            for line in open(p, encoding="utf-8", errors="ignore"):
                m = re.match(r"\s*DEEPSEEK_API_KEY\s*=\s*(.+)", line)
                if m:
                    return m.group(1).strip().strip("\"'")
        except FileNotFoundError:
            pass
    return os.environ.get("DEEPSEEK_API_KEY", "")


API_KEY = load_key()

SYS_PROMPT = (
    "你是专业影视字幕翻译。用户会给你若干行字幕（按顺序编号），你要把它们逐行翻译成简体中文。"
    "要求：口语化、简洁、符合字幕长度；不添加解释、不合并也不拆分句子；"
    "如果原文已经是中文，就转成简体中文并保留原意，不要改写；专有名词保留原文。"
    "只输出 JSON：{\"zh\":[\"第1行译文\",\"第2行译文\", ...]}，数组长度必须与输入行数相同。"
)


def deepseek_translate(lines):
    if not API_KEY:
        raise RuntimeError("没有找到 DEEPSEEK_API_KEY")
    payload = {
        "model": "deepseek-chat",
        "temperature": 0,
        "response_format": {"type": "json_object"},
        "messages": [
            {"role": "system", "content": SYS_PROMPT},
            {"role": "user", "content": json.dumps({"lines": lines}, ensure_ascii=False)},
        ],
    }
    req = urllib.request.Request(
        DEEPSEEK_URL, data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + API_KEY})
    with urllib.request.urlopen(req, timeout=120) as r:
        data = json.loads(r.read().decode("utf-8"))
    obj = json.loads(data["choices"][0]["message"]["content"])
    zh = obj.get("zh") or obj.get("translations") or []
    if not isinstance(zh, list) or len(zh) != len(lines):
        raise RuntimeError("译文条数不对：%s vs %s" % (len(zh), len(lines)))
    return [str(x).strip() for x in zh]


# ---------------- 任务存储（内存 + 每任务一个 json 文件） ----------------
LOCK = threading.RLock()
T = {}          # id -> job dict


def key_of(url):
    return hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]


def save(j):
    p = os.path.join(JOBS, j["id"] + ".json")
    tmp = p + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(j, f, ensure_ascii=False)
    os.replace(tmp, p)


def load_all():
    for fn in os.listdir(JOBS):
        if not fn.endswith(".json"):
            continue
        try:
            j = json.load(open(os.path.join(JOBS, fn), encoding="utf-8"))
            st = j.get("state")
            if st in ("queued", "asr", "translating"):
                # asr 且最近还有心跳 → 保留（worker 还在推），否则打回队列
                if st == "asr" and time.time() - j.get("touch", 0) < 300:
                    pass
                else:
                    j["state"] = "queued" if not j.get("segs") else "translating"
                    j["claimed"] = 0
            # live_keep_segs：没字幕的实时空记录删掉；有字幕的留下（去掉 live 标记，
            # 变成正常记录，下次拖回去直接读，不再重转）
            if j.get("live") and j.get("state") in ("done", "error", "cancel", "cancelled"):
                if j.get("segs"):
                    j["live"] = 0
                else:
                    try:
                        os.remove(os.path.join(JOBS, fn))
                    except OSError:
                        pass
                    continue
            T[j["id"]] = j
        except Exception:
            pass


def new_job(url, name, model, hot=False, eph=False):
    jid = key_of(url)
    with LOCK:
        j = T.get(jid)
        if j:
            j["reused"] = True
            if hot:
                j["hot"] = time.time()
            if j["state"] in ("cancelled", "error"):
                j["state"] = "queued"
                j["claimed"] = 0
                j["msg"] = ""
                j["audio_fail"] = False
                j["touch"] = time.time()
                save(j)
            return j
        lp = local_path(url)
        size, sig = sig_of(url, name, lp)
        if sig:
            twin = pick_by_sig(sig, jid)
            if twin:
                # 同一集换了个入口（本机 CloudFS 挂载 ↔ 115 网盘 ↔ 电脑共享）：
                # 直接把它交给前端，别开第二个任务白转一遍。
                twin["reused"] = True
                twin["sig_hit"] = time.time()
                if hot:
                    twin["hot"] = time.time()
                if twin["state"] in ("cancelled", "error"):
                    twin["state"] = "queued"
                    twin["claimed"] = 0
                    twin["msg"] = ""
                    twin["audio_fail"] = False
                    twin["touch"] = time.time()
                alts = [u for u in (twin.get("alt_urls") or []) if u != url]
                twin["alt_urls"] = ([url] + alts)[:6]
                save(twin)
                return twin
        # 小文件直接流式读更快（几百 MB 的片子抽音频省不了多少，反而让用户多等）
        # 用户正在看的那一集也一律流式：让他等 30 秒抽完音才出第一条字幕最蠢，
        # 流式大约 10 秒就有第一块。预抽只留给“后台排队/夜里预生成”这种没人等的任务。
        big = False
        try:
            big = bool(lp) and os.path.getsize(lp) > 700 * 1024 * 1024
        except OSError:
            big = False
        if hot:
            big = False
        j = {"id": jid, "url": url, "name": name or "", "model": model if model in ("turbo", "small") else "turbo",
             "local_path": lp, "want_audio": big, "audio_ready": None if big else False,
             "state": "queued", "lang": "", "done_until": 0.0, "msg": "", "segs": [],
             "created": time.time(), "claimed": 0, "touch": time.time(), "dur": 0, "reused": False,
             "sig": sig, "size": size, "alt_urls": [],
             "segs_at": None,                 # segs_at：现有 segs 出自哪条流（ffmpeg 全局流序号）；None = 未定
             "eph": 1 if eph else 0,          # 在线播放的临时任务：不进队列、不上监控、用完就丢
             "hot": time.time() if hot else 0}
        T[jid] = j
        save(j)
        return j


def srt_ts(sec):
    ms = int(round((float(sec) - int(float(sec))) * 1000))
    t = int(float(sec))
    return "%02d:%02d:%02d,%03d" % (t // 3600, (t % 3600) // 60, t % 60, ms)


def srt_of(j):
    """双语 SRT：第一行原文、第二行中文（译文和原文一样时只留一行）。"""
    out = []
    for n, sg in enumerate(j.get("segs") or [], 1):
        or_txt, zh = (sg[2] or "").strip(), (sg[3] or "").strip()
        if not or_txt and not zh:
            continue
        text = or_txt if (not zh or zh == or_txt) else (or_txt + "\n" + zh)
        out.append("%d\n%s --> %s\n%s\n" % (n, srt_ts(sg[0]), srt_ts(sg[1]), text))
    return "\n".join(out)


def folder_of(url):
    """从视频地址里取出"所在文件夹"和主机，给监控列表显示用。"""
    try:
        u = urllib.parse.urlparse(url or "")
        parts = [x for x in urllib.parse.unquote(u.path or "").split("/") if x]
        return "/".join(parts[:-1]), (u.netloc or "")
    except Exception:
        return "", ""


SIG_CACHE = {}


def _http_len_head(url, timeout=8):
    req = urllib.request.Request(url, method="HEAD")
    req.add_header("User-Agent", "subs-hub")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        n = r.headers.get("Content-Length")
        return int(n) if n and str(n).isdigit() else 0


def _http_len_range(url, timeout=8):
    """有些服务不支持 HEAD：用 Range: bytes=0-0 从 Content-Range 里拿总长。"""
    req = urllib.request.Request(url)
    req.add_header("Range", "bytes=0-0")
    req.add_header("User-Agent", "subs-hub")
    with urllib.request.urlopen(req, timeout=timeout) as r:
        cr = r.headers.get("Content-Range") or ""
        if "/" in cr:
            t = cr.rsplit("/", 1)[1].strip()
            if t.isdigit():
                return int(t)
    return 0


def probe_size(url, lp=None):
    """字节数：本地挂载直接 stat，否则 HTTP 问一次。"""
    if lp:
        try:
            return os.path.getsize(lp)
        except OSError:
            pass
    for fn in (_http_len_head, _http_len_range):
        try:
            n = fn(url)
            if n:
                return n
        except Exception:
            pass
    return 0


def norm_name(n):
    return re.sub(r"[^0-9a-z]+", "", (n or "").lower())


def sig_of(url, name, lp=None):
    """返回 (size, sig)。拿不到大小时 sig 为空 = 不做去重（宁可重转，也不能张冠李戴）。"""
    if url in SIG_CACHE:
        return SIG_CACHE[url]
    base = (name or urllib.parse.unquote(url.rsplit("/", 1)[-1]) or "").strip()
    size = probe_size(url, lp)
    sig = ""
    if size:
        sig = hashlib.sha1(("%d|%s" % (size, norm_name(base))).encode()).hexdigest()[:16]
    SIG_CACHE[url] = (size, sig)
    return size, sig


def pick_by_sig(sig, jid):
    """同一个指纹下挑一个最该复用的：转好了 > 正在转 > 排队 > 停过但已经出了字幕。"""
    RANK = {"done": 0, "translating": 1, "asr": 2, "queued": 3}
    best, rank = None, 9
    for o in T.values():
        if not sig or o.get("sig") != sig or o["id"] == jid:
            continue
        r = RANK.get(o["state"], 4)
        if r < rank or (r == rank and best is not None and
                        len(o.get("segs") or []) > len(best.get("segs") or [])):
            best, rank = o, r
    return best


def backfill_sigs():
    """旧任务没有指纹：开机后慢慢补上，这样它们也能被“同一个文件”认出来。"""
    time.sleep(3)
    for j in list(T.values()):
        if j.get("sig"):
            continue
        try:
            size, sig = sig_of(j.get("url", ""), j.get("name", ""), j.get("local_path"))
            if sig:
                with LOCK:
                    j["sig"], j["size"] = sig, size
                    save(j)
        except Exception:
            pass
        time.sleep(1)


# ffprobe 报的是 ISO 639-2（kor/jpn/zho），whisper 只认 ISO 639-1（ko/ja/zh）。
# 老版本转写工把 track_lang 原样塞给 whisper，韩语片直接 "invalid language code" 整单失败，
# 所以这里就翻译好再下发（顺带老进程也不用重启）。
L2L = {"zho": "zh", "chi": "zh", "cmn": "zh", "yue": "zh", "kor": "ko", "jpn": "ja",
       "eng": "en", "spa": "es", "ita": "it", "fra": "fr", "fre": "fr", "deu": "de",
       "ger": "de", "rus": "ru", "por": "pt", "ara": "ar", "hin": "hi", "tha": "th",
       "vie": "vi", "tur": "tr", "nld": "nl", "dut": "nl", "pol": "pl", "swe": "sv",
       "dan": "da", "nor": "no", "fin": "fi", "ell": "el", "heb": "he", "ind": "id",
       "msa": "ms", "may": "ms", "ces": "cs", "cze": "cs", "ukr": "uk", "ron": "ro",
       "rum": "ro", "hun": "hu", "fas": "fa", "per": "fa", "tam": "ta", "tel": "te",
       "mal": "ml", "kan": "kn", "ben": "bn", "urd": "ur", "fil": "tl", "tgl": "tl"}
VALID_L2 = set("""af am ar as az ba be bg bn bo br bs ca cs cy da de el en es et eu fa fi fo fr gl gu ha
haw he hi hr ht hu hy id is it ja jw ka kk km kn ko la lb ln lo lt lv mg mi mk ml mn mr ms mt my ne nl
nn no oc pa pl ps pt ro ru sa sd si sk sl sn so sq sr su sv sw ta te tg th tk tl tr tt uk ur uz vi yi
yo zh""".split())


def lang2(t):
    """任何语言标识 → whisper 认的两位码；认不出就返回空（交给自动识别）。"""
    t = (t or "").strip().lower()
    if not t:
        return ""
    if len(t) == 3:
        t = L2L.get(t, t)
    t = t.split("-")[0].split("_")[0]
    return t if t in VALID_L2 else ""


def drop_audio(jid):
    """任务结束后音频就没用了：让 NAS 少存几十上百 MB。"""
    for ext in (".flac", ".flac.part", ".wav"):
        try:
            os.remove(os.path.join(AUDIO, jid + ext))
        except OSError:
            pass


def sweep_audio():
    """定期清理：.part 超过 30 分钟、任务已结束/已不存在的音频都删掉。"""
    while True:
        try:
            now = time.time()
            with LOCK:
                states = {k: (v.get("state"), v.get("done_at") or v.get("touch") or 0) for k, v in T.items()}
            for fn in os.listdir(AUDIO):
                fp = os.path.join(AUDIO, fn)
                jid = fn.split(".")[0]
                try:
                    age = now - os.path.getmtime(fp)
                except OSError:
                    continue
                if fn.endswith(".part"):
                    if age > 1800:
                        os.remove(fp)
                    continue
                st, ts = states.get(jid, (None, 0))
                if st is None:                      # 任务没了
                    if age > 1800:
                        os.remove(fp)
                elif st in ("done", "error", "cancelled") and (now - ts) > 600:
                    os.remove(fp)                   # 结束 10 分钟后删（留点余地给导出/重跑）
        except Exception:
            pass
        try:
            sweep_acache()                       # 外挂音轨缓存（7 天 / 4G）
            sweep_hls()                          # HLS 分片目录（2 小时 / 8G）
            sweep_pcache()                       # 转码视频缓存（5 天 / 6G）
        except Exception:
            pass
        time.sleep(600)


def mark_hot(j):
    """播放器每次轮询 /job 就是一次"我正在看"的打卡。"""
    if j and j.get("state") in ("queued", "asr", "translating"):
        j["hot"] = time.time()


def hot_of(j, now=None):
    """hot 只在 10 分钟内算数，避免很久以前看过的片子一直插队。"""
    now = now or time.time()
    h = float(j.get("hot") or 0)
    return h if (h and now - h < 600) else 0.0


def pick_next():
    """下一个该干谁：实时听译 > 在线播放 > 正在看的 > 先来后到。"""
    live_busy = any(x.get("live") and x["state"] == "asr" for x in T.values())
    q = [x for x in T.values() if x["state"] == "queued"]
    if live_busy:
        # 实时任务在跑：别把 CPU 分给批量任务，不然两边都卡
        q = [x for x in q if x.get("live")]
    q.sort(key=lambda x: (-int(x.get("live") or 0), -int(x.get("eph") or 0),
                          -hot_of(x), float(x.get("created") or 0)))
    return q[0] if q else None


def queue_pos(j):
    """排队中时，前面还有几个任务：正在转的 + 比我早排的。"""
    if j["state"] != "queued":
        return 0
    order = sorted([x for x in T.values() if x["state"] == "queued"],
                   key=lambda x: (-hot_of(x), float(x.get("created") or 0)))
    # 正在被一个"非本人正在看"的任务占着，才算前面还有 1 个
    cur = [x for x in T.values() if x["state"] in ("asr", "translating")]
    ahead = 0
    for x in cur:
        if hot_of(j) and not hot_of(x):
            ahead += 0          # 我在看，转写工马上会让路给我
        else:
            ahead += 1
    for i, x in enumerate(order):
        if x["id"] == j["id"]:
            return ahead + i
    return ahead


def covered_by(segs, t, pad=1.5):
    """这个时间点是不是已经转过了（live_keep_segs）。"""
    try:
        t = float(t)
    except Exception:
        return False
    for s in segs or []:
        try:
            if float(s[0]) - pad <= t <= float(s[1]) + pad:
                return True
        except Exception:
            continue
    return False


def view(j):
    now = time.time()
    sp = 0.0
    if j.get("asr_t0"):
        moved = float(j.get("done_until") or 0) - float(j.get("asr_p0") or 0)
        if moved > 0:
            # 用至少 20 秒的窗口算，否则第一块字幕"爆发式"到达时速度会显示成几十倍
            sp = round(moved / max(20.0, now - float(j["asr_t0"])), 2)
    folder, host = folder_of(j.get("url"))
    return {"id": j["id"], "state": j["state"], "lang": j.get("lang", ""),
            "folder": folder, "host": host, "sig": j.get("sig", ""),
            "size": j.get("size", 0), "alt": len(j.get("alt_urls") or []),
            "speed": sp, "touch_age": int(now - j.get("touch", now)),
            "dur_total": round(float(j.get("dur") or 0), 1),
            "created_age": int(now - j.get("created", now)),
            "queue": queue_pos(j), "audio_ready": bool(j.get("audio_ready")),
            "done_until": j.get("done_until", 0), "msg": j.get("msg", ""),
            "name": j.get("name", ""), "reused": j.get("reused", False),
            "pending": sum(1 for s in j["segs"] if not s[3]),
            "segments": j["segs"]}


# ---------------- 翻译线程（2 条并发） ----------------
STOP = threading.Event()
TR_THREADS = 2
INFLIGHT = {}          # jid -> set(段索引)，正在翻的段（不落盘，不能塞进 job 里）


def _finish_if_ready(j):
    if j.get("asr_done") and j["state"] not in ("done", "error", "cancelled") \
            and all(s[3] for s in j["segs"]):
        j["state"] = "done"
        save(j)


def pick_work():
    """挑一批待翻的段并标记 in-flight，避免两条线程翻同一批。"""
    with LOCK:
        for j in T.values():
            if j["state"] not in ("asr", "translating"):
                continue
            busy = INFLIGHT.setdefault(j["id"], set())
            idx = [i for i, s in enumerate(j["segs"]) if not s[3] and i not in busy]
            if not idx:
                _finish_if_ready(j)
                continue
            part = idx[:BATCH]
            busy.update(part)
            return j, part, [j["segs"][i][2] for i in part]
    return None, None, None


def translator():
    while not STOP.is_set():
        j, part, lines = pick_work()
        if not j:
            time.sleep(0.8)
            continue
        try:
            zh = deepseek_translate(lines)
        except Exception as e:
            with LOCK:
                INFLIGHT.setdefault(j["id"], set()).difference_update(part)
                j["tr_fail"] = j.get("tr_fail", 0) + 1
                j["msg"] = "翻译出错：%s" % str(e)[:120]
                if j["tr_fail"] >= 3 or j.get("asr_done"):
                    # 翻译连不上时别卡住：先用原文顶上，前端至少能看原文
                    for i in part:
                        if i < len(j["segs"]) and not j["segs"][i][3]:
                            j["segs"][i][3] = j["segs"][i][2]
                    _finish_if_ready(j)
                save(j)
            time.sleep(1.5)
            continue
        with LOCK:
            INFLIGHT.setdefault(j["id"], set()).difference_update(part)
            for i, z in zip(part, zh):
                if i < len(j["segs"]) and not j["segs"][i][3]:
                    j["segs"][i][3] = z
            j["tr_fail"] = 0
            j["msg"] = ""
            _finish_if_ready(j)
            save(j)


# ---------------- NAS 本地抽音频（不过网络，比让电脑拉整个 4K 视频快得多） ----------------
def local_path(url):
    """dufs 共享里的文件在 NAS 上是本地路径，直接读，不经过网络。"""
    try:
        u = urllib.parse.urlparse(url)
    except Exception:
        return None
    rel = urllib.parse.unquote(u.path).lstrip("/")
    if not rel:
        return None
    for prefix, root in SHARE_ROOTS:
        if prefix and not rel.startswith(prefix):
            continue
        full = os.path.join(root, rel[len(prefix):])
        if os.path.isfile(full):
            return full
    return None


def audio_file(jid):
    return os.path.join(AUDIO, jid + ".flac")


# ---------------- 音轨补丁（浏览器解不了 AC3/DTS 时用） ----------------
ACACHE = os.path.join(HERE, "acache")        # 转好的 AAC 音轨缓存
PCACHE = os.path.join(HERE, "playcache")     # 给 iOS 换封装/转码后的视频
os.makedirs(ACACHE, exist_ok=True)
os.makedirs(PCACHE, exist_ok=True)
# 浏览器自己能解的音频编码；不在表里的（ac3/eac3/dts/truehd/...）就得补一条 AAC
A_OK = {"aac", "mp3", "opus", "vorbis", "flac"}
PROBE_C = {}
AC_LOCK = threading.Lock()
AC_RUN = {}                                   # 正在转的音轨：key -> 线程
AC_FAIL = {}                                  # key -> 失败原因（别无限重试）


def ac_key(url):
    """地址要归一化再算 key：前端发的是 %E7%94%A8… 编码版，脚本调用是中文原样，两种得是同一个任务。"""
    u = url or ""
    for _ in range(4):                     # 有的页面地址是双重编码的（%255D），一路解到底
        try:
            v = urllib.parse.unquote(u)
        except Exception:
            break
        if v == u:
            break
        u = v
    return hashlib.sha1(u.encode("utf-8")).hexdigest()[:16]


def ac_file(url):
    return os.path.join(ACACHE, ac_key(url) + ".m4a")


def probe_media(path):
    """ffprobe 一个文件，结果按 (路径, mtime, 大小) 缓存。"""
    try:
        st = os.stat(path)
        ck = (path, int(st.st_mtime), st.st_size)
    except OSError:
        return None
    if ck in PROBE_C:
        return PROBE_C[ck]
    try:
        out = subprocess.run(
            [os.path.join(BIN, "ffprobe"), "-v", "error", "-print_format", "json",
             "-show_streams", "-show_format", path],
            capture_output=True, timeout=90).stdout
        d = json.loads(out or b"{}")
    except Exception as e:
        return {"error": str(e)[:120]}
    v = next((x for x in d.get("streams", []) if x.get("codec_type") == "video"), {}) or {}
    auds = [x for x in d.get("streams", []) if x.get("codec_type") == "audio"]
    a = (auds[0] if auds else {}) or {}
    vc = (v.get("codec_name") or "").lower()
    ac = (a.get("codec_name") or "").lower()
    pf = (v.get("pix_fmt") or "").lower()
    res = {
        "dur": float(d.get("format", {}).get("duration") or 0),
        "container": (d.get("format", {}).get("format_name") or ""),
        "v": {"codec": vc, "profile": v.get("profile") or "", "pix": pf,
              "w": v.get("width") or 0, "h": v.get("height") or 0, "hdr": "10" in pf or "12" in pf},
        "a": {"codec": ac, "ch": a.get("channels") or 0, "lang": (a.get("tags") or {}).get("language") or "",
              "idx": a.get("index")},
        "tracks": [{"i": x.get("index"), "codec": (x.get("codec_name") or "").lower(),
                   "ch": x.get("channels") or 0,
                   "lang": (x.get("tags") or {}).get("language") or "",
                   "title": (x.get("tags") or {}).get("title") or ""} for x in auds],
        "afix": bool(ac) and ac not in A_OK,     # 需要补音轨
        "vok": vc in ("h264", "vp8", "vp9", "av1") and not ("10" in pf or "12" in pf),
    }
    PROBE_C[ck] = res
    return res



# ---------- 远程文件（网盘转发 5008 等）：中枢拿不到本地路径，但 ffmpeg 能直接读 http ----------
PROBE_U = {}


def is_http(url):
    return bool(re.match(r"^https?://", url or ""))


def _summ(d):
    """把 ffprobe 的 json 压成前端要的形状。"""
    v = next((x for x in d.get("streams", []) if x.get("codec_type") == "video"), {}) or {}
    auds = [x for x in d.get("streams", []) if x.get("codec_type") == "audio"]
    a = (auds[0] if auds else {}) or {}
    vc = (v.get("codec_name") or "").lower()
    ac = (a.get("codec_name") or "").lower()
    pf = (v.get("pix_fmt") or "").lower()
    return {
        "dur": float(d.get("format", {}).get("duration") or 0),
        "container": (d.get("format", {}).get("format_name") or ""),
        "v": {"codec": vc, "profile": v.get("profile") or "", "pix": pf,
              "w": v.get("width") or 0, "h": v.get("height") or 0, "hdr": "10" in pf or "12" in pf},
        "a": {"codec": ac, "ch": a.get("channels") or 0, "lang": (a.get("tags") or {}).get("language") or "",
              "idx": a.get("index")},
        "tracks": [{"i": x.get("index"), "codec": (x.get("codec_name") or "").lower(),
                    "ch": x.get("channels") or 0,
                    "lang": (x.get("tags") or {}).get("language") or "",
                    "title": (x.get("tags") or {}).get("title") or ""} for x in auds],
        "afix": bool(ac) and ac not in A_OK,
        "vok": vc in ("h264", "vp8", "vp9", "av1") and not ("10" in pf or "12" in pf),
    }


def probe_url(url):
    """远程文件只读文件头，短缓存。"""
    now = time.time()
    c = PROBE_U.get(url)
    if c and now - c[0] < 180:
        return c[1]
    try:
        out = subprocess.run(
            [os.path.join(BIN, "ffprobe"), "-v", "error", "-print_format", "json",
             "-show_streams", "-show_format", "-rw_timeout", "15000000", url],
            capture_output=True, timeout=45).stdout
        d = json.loads(out or b"{}")
        res = _summ(d)
        if not d.get("streams"):
            res = {"error": "probe empty"}
    except Exception as e:
        res = {"error": str(e)[:120]}
    PROBE_U[url] = (now, res)
    return res


PROD = {}             # key -> {"p": Popen, "path": .part, "dst": 成品}
def play_key(url, ss, mode, at=None):
    return "pl" + ac_key(url + ("#at%d" % at if at is not None else "")) + "_" + ("r" if mode == "remux" else "t") + "_%d" % int(ss or 0)
# ---------------- HLS 分片（Jellyfin 的「换封装直通」方式） ----------------
HLS_DIR = os.path.join(HERE, "hls")
HLS_PROD = {}          # key -> Popen
os.makedirs(HLS_DIR, exist_ok=True)


def hls_key(url, ss, at=None):
    return "h" + ac_key(url + ("#at%d" % at if at is not None else "")) + "_%d" % int(ss or 0)


def hls_start(url, ss, hevc=False, at=None):
    """起一个只换封装的 HLS 输出；返回 key。已在跑就直接复用。"""
    key = hls_key(url, ss, at)
    d = os.path.join(HLS_DIR, key)
    os.makedirs(d, exist_ok=True)
    pl = os.path.join(d, "index.m3u8")
    ent = HLS_PROD.get(key)
    if ent and ent.poll() is None:
        return key
    src = local_path(url) or url
    # 上次跑挂了留下的半截产物：清掉重来，免得播放列表跟分片对不上
    try:
        for f in os.listdir(d):
            os.remove(os.path.join(d, f))
    except Exception:
        pass
    args = [os.path.join(BIN, "ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error",
            "-ss", str(max(0.0, float(ss or 0))), "-i", src, "-sn",
            "-map", "0:v:0", "-map", ("0:%d?" % at) if (at is not None and at >= 0) else "0:a:0?",
            "-c:v", "copy"] + (["-tag:v", "hvc1"] if hevc else []) + [
            "-c:a", "aac", "-b:a", "160k", "-ac", "2",
            "-f", "hls", "-hls_time", "4", "-hls_playlist_type", "event",
            "-hls_segment_type", "fmp4", "-hls_flags", "temp_file",
            "-hls_segment_filename", os.path.join(d, "s%05d.m4s"), pl]
    pr = subprocess.Popen(args, stdin=subprocess.DEVNULL,
                          stdout=subprocess.DEVNULL,
                          stderr=open(os.path.join(HERE, "hls.err"), "ab"))
    HLS_PROD[key] = pr
    return key


def hls_wait(key, timeout=20.0):
    """等到 init.mp4 和第一个分片都真的落盘再回给前端。
       只等播放列表不够：列表里出现 s00000 时文件可能还没写完，客户端会解析失败。"""
    d = os.path.join(HLS_DIR, key)
    pl = os.path.join(d, "index.m3u8")
    init = os.path.join(d, "init.mp4")
    seg0 = os.path.join(d, "s00000.m4s")
    t0 = time.time()
    while time.time() - t0 < timeout:
        ok_pl = os.path.exists(pl) and os.path.getsize(pl) > 32
        ok_init = os.path.exists(init) and os.path.getsize(init) > 512
        ok_seg = os.path.exists(seg0) and os.path.getsize(seg0) > 4096
        if ok_pl and ok_init and ok_seg:
            time.sleep(0.2)
            return True
        ent = HLS_PROD.get(key)
        if ent and ent.poll() is not None:
            return ok_pl and ok_init and ok_seg
        time.sleep(0.15)
    return False


def sweep_hls(hours=2, max_bytes=8 << 30):
    now = time.time()
    try:
        items = []
        for k in list(HLS_DIR and os.listdir(HLS_DIR) or []):
            d = os.path.join(HLS_DIR, k)
            if not os.path.isdir(d):
                continue
            sz = sum(os.path.getsize(os.path.join(d, f)) for f in os.listdir(d) if os.path.isfile(os.path.join(d, f)))
            items.append((os.path.getmtime(d), sz, k, d))
        items.sort()
        total = sum(x[1] for x in items)
        for mt, sz, k, d in items:
            if now - mt > hours * 3600 or total > max_bytes:
                ent = HLS_PROD.pop(k, None)
                if ent and ent.poll() is None:
                    try:
                        ent.kill()
                    except Exception:
                        pass
                try:
                    for f in os.listdir(d):
                        os.remove(os.path.join(d, f))
                    os.rmdir(d)
                    total -= sz
                except Exception:
                    pass
    except Exception:
        pass




def stream_part(self, key, args, ctype, cache_dir=None):
    """跑一条 ffmpeg，把它的输出文件边写边发给浏览器（chunked）。
    args 里文件名位置用 {out} 占位；转完的成品留在缓存里，下次直接按 Range 发。"""
    cache_dir = cache_dir or PCACHE
    ent = PROD.get(key)
    dst = os.path.join(cache_dir, key + ".mp4")
    if os.path.exists(dst) and os.path.getsize(dst) > 4096:
        return self.send_media(dst, ctype)
    part = os.path.join(cache_dir, key + ".part")
    if not (ent and ent["p"].poll() is None):
        try:
            if os.path.exists(part):
                os.remove(part)
        except OSError:
            pass
        cmd = [a.replace("{out}", part) for a in args]
        sys.stderr.write("[%s] play: %s\n" % (time.strftime("%H:%M:%S"), " ".join(cmd[1:])))
        pr = subprocess.Popen(cmd, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                              stderr=open(os.path.join(HERE, "play.err"), "ab"))
        ent = {"p": pr, "path": part, "dst": dst}
        PROD[key] = ent
    pr = ent["p"]
    self.send_response(200)
    for k, v in CORS.items():
        self.send_header(k, v)
    self.send_header("Content-Type", ctype)
    self.send_header("Cache-Control", "no-store")
    self.send_header("Transfer-Encoding", "chunked")
    self.end_headers()
    pos, idle = 0, 0
    try:
        while True:
            chunk = b""
            try:
                with open(part, "rb") as fh:
                    fh.seek(pos)
                    chunk = fh.read(1 << 16)
            except OSError:
                chunk = b""
            if chunk:
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
                pos += len(chunk)
                idle = 0
                continue
            if pr.poll() is not None:
                break
            idle += 1
            if idle > 1200:
                break
            time.sleep(0.05)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
        try:
            pr.kill()
        except Exception:
            pass
    finally:
        try:
            if pr.poll() is None:
                pr.kill()
        except Exception:
            pass
        try:
            if os.path.exists(part) and pr.poll() is not None and pr.returncode == 0:
                os.replace(part, dst)          # 只有正常转完才顶掉成品
            elif os.path.exists(part):
                os.remove(part)                # 半截的丢
            PROD.pop(key, None)
        except Exception:
            pass



def qs_at(qs):
    """从查询串里取音轨序号（绝对流序号），没有就 None。"""
    v = (qs.get("at") or [""])[0]
    if v == "":
        return None
    try:
        return max(0, int(v))
    except ValueError:
        return None

def play_args(url, ss, mode, hevc, at=None):
    """给 /play 拼 ffmpeg 参数。at = 指定音轨的绝对流序号（None 用第一条）。"""
    src = local_path(url) or url
    amap = ("0:%d?" % at) if (at is not None and at >= 0) else "0:a:0?"
    args = [os.path.join(BIN, "ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error"]
    if ss and float(ss) > 0:
        args += ["-ss", str(ss)]
    args += ["-i", src, "-sn", "-map", "0:v:0", "-map", amap]
    if mode == "remux":
        args += ["-c:v", "copy"]
        if hevc:
            args += ["-tag:v", "hvc1"]
    else:
        args += ["-c:v", "libx264", "-preset", "veryfast", "-crf", "23",
                 "-pix_fmt", "yuv420p", "-vf", "scale='min(1280,iw)':-2"]
    args += ["-c:a", "aac", "-b:a", "160k", "-ac", "2",
             "-f", "mp4", "-movflags", "frag_keyframe+empty_moov+default_base_moof",
             "-frag_duration", "500000", "{out}"]
    return args


def play_mode(info):
    """能不能只换封装？iOS 只认 H.264 8bit 和 HEVC（10bit HEVC 也能硬解）。"""
    v = (info or {}).get("v") or {}
    vc = (v.get("codec") or "").lower()
    pix = (v.get("pix") or "").lower()
    if vc == "h264" and "10" not in pix and "12" not in pix:
        return "remux", False
    if vc in ("hevc", "h265"):
        return "remux", True
    return "transcode", False


AC_PROD = {}          # key -> {"p": Popen, "path": 文件}  正在生成的音轨


def _ac_ensure(url, ss, at=None):
    """确保有 ffmpeg 在把 (url, ss, 音轨) 的音轨写进 .part 文件，返回 (进程, 文件路径)。"""
    key = ac_key(url + ("#at%d" % at if at is not None else "")) + "_%d" % int(ss or 0)
    dst = os.path.join(ACACHE, key + ".m4a")
    if os.path.exists(dst) and os.path.getsize(dst) > 1024:
        return None, dst
    ent = AC_PROD.get(key)
    if ent and ent["p"].poll() is None:
        return ent["p"], ent["path"]
    part = os.path.join(ACACHE, key + ".part")
    try:
        if os.path.exists(part):
            os.remove(part)
    except OSError:
        pass
    src = local_path(url) or url
    args = [os.path.join(BIN, "ffmpeg"), "-nostdin", "-hide_banner", "-loglevel", "error"]
    if ss and float(ss) > 0:
        args += ["-ss", str(ss)]
    args += ["-i", src, "-vn", "-map", ("0:%d" % at) if (at is not None and at >= 0) else "0:a:0",
             "-c:a", "aac", "-b:a", "160k", "-ac", "2",
             "-f", "mp4", "-movflags", "frag_keyframe+empty_moov+default_base_moof",
             "-frag_duration", "500000",   # 关键：只有音频时没有关键帧，不加这个 mp4 要等到结尾才落盘
             part]
    pr = subprocess.Popen(args, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL)
    AC_PROD[key] = {"p": pr, "path": part, "dst": dst, "key": key}
    return pr, part


def stream_audio(self, url, ss, at=None):
    """把音轨边转边推给浏览器。整条转完会缓存成 .m4a，下次直接发（支持 Range 拖动）。"""
    pr, path = _ac_ensure(url, ss, at)
    if pr is None:                       # 已经转好了，直接按文件发（能拖进度）
        return self.send_media(path)
    self.send_response(200)
    for k, v in CORS.items():
        self.send_header(k, v)
    self.send_header("Content-Type", "audio/mp4")
    self.send_header("Cache-Control", "no-store")
    self.send_header("Transfer-Encoding", "chunked")
    self.end_headers()
    pos = 0
    idle = 0
    try:
        while True:
            chunk = b""
            try:
                with open(path, "rb") as fh:
                    fh.seek(pos)
                    chunk = fh.read(1 << 15)
            except OSError:
                chunk = b""
            if chunk:
                self.wfile.write(b"%x\r\n" % len(chunk) + chunk + b"\r\n")
                self.wfile.flush()
                pos += len(chunk)
                idle = 0
                continue
            if pr.poll() is not None:
                break                     # 转完了，且已发完
            idle += 1
            if idle > 1200:               # 60 秒没动静，收工
                break
            time.sleep(0.05)
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()
    except (BrokenPipeError, ConnectionResetError):
        try:
            pr.kill()
        except Exception:
            pass
    finally:
        # 客户端走了 / 长时间没数据：别让 ffmpeg 在后台接着转（ARM 上白烧 CPU）
        try:
            if pr.poll() is None:
                pr.kill()
        except Exception:
            pass
        try:
            ent = AC_PROD.get(ac_key(url) + "_%d" % int(ss or 0))
            if ent and ent["p"].poll() is not None and os.path.exists(ent["path"]):
                os.replace(ent["path"], ent["dst"])
                AC_PROD.pop(ent["key"], None)
        except Exception:
            pass


def sweep_pcache(days=5, max_bytes=6 << 30):
    """转好的视频缓存：5 天没用 / 超 6G 就删。"""
    try:
        items = []
        for n in os.listdir(PCACHE):
            p = os.path.join(PCACHE, n)
            if not os.path.isfile(p):
                continue
            if n.endswith(".part"):
                if time.time() - os.path.getmtime(p) > 1800:
                    try:
                        os.remove(p)
                    except OSError:
                        pass
                continue
            items.append((os.path.getmtime(p), os.path.getsize(p), p))
        items.sort()
        now, total = time.time(), sum(x[1] for x in items)
        for mt, sz, p in items:
            if now - mt > days * 86400 or total > max_bytes:
                try:
                    os.remove(p)
                    total -= sz
                except OSError:
                    pass
    except Exception:
        pass


def sweep_acache(days=7, max_bytes=4 << 30):
    """清掉久不用的音轨缓存，别把 NAS 撑爆。"""
    try:
        items = []
        for n in os.listdir(ACACHE):
            p = os.path.join(ACACHE, n)
            if not os.path.isfile(p):
                continue
            if n.endswith(".part"):
                if time.time() - os.path.getmtime(p) > 1800:   # 半截的：30 分钟后清掉
                    try:
                        os.remove(p)
                    except OSError:
                        pass
                continue
            items.append((os.path.getmtime(p), os.path.getsize(p), p))
        items.sort()
        now = time.time()
        total = sum(x[1] for x in items)
        for mt, sz, p in items:
            if now - mt > days * 86400 or total > max_bytes:
                try:
                    os.remove(p)
                    total -= sz
                except OSError:
                    pass
    except Exception:
        pass


def pick_audio_stream(path):
    """选转字幕用的音轨。

    不变式：字幕轨必须跟耳朵对齐。/play 在 at 缺失时 map 的就是 0:a:0（文件里第一条音轨），
    所以这里也优先 disposition.default==1 的音轨，没有 default 标记才取第一条。
    LANG_PREF 不再参与选轨（常量留着只作语言标注）：按语言偏好挑会挑到中文配音轨，
    而画面里放的是法语/英语原声 —— 火山挚恋就是这样把 chi(3) 的字幕配给 fre(1) 的声音。
    """
    try:
        out = subprocess.run([os.path.join(BIN, "ffprobe"), "-v", "error", "-show_entries",
                              "stream=index,codec_type:stream_tags=language"
                              ":stream_disposition=default", "-of", "json", path],
                             capture_output=True, text=True, timeout=120).stdout
        d = json.loads(out or "{}")
    except Exception:
        return None, ""
    auds = [x for x in d.get("streams", []) if x.get("codec_type") == "audio"]
    if not auds:
        return None, ""
    pick = auds[0]
    for a in auds:
        try:
            if int((a.get("disposition") or {}).get("default") or 0) == 1:
                pick = a
                break
        except (TypeError, ValueError):
            continue
    return pick.get("index"), W2L.get(((pick.get("tags") or {}).get("language") or "").lower(), "")


def segs_source_at(j):
    """现有 segs 的真实出处（ffmpeg 全局流序号）。

    segs_at 没写的老记录用 audio_track 回填 —— prep_worker 抽音频抽的就是这条流，
    它才是字幕的出处。两者都缺 = 出处真未知，返回 None；调用方不许拿 _at 顶上
    （拿 _at 顶会把错轨字幕钉死，以后再也分不出真假）。
    """
    sa = j.get("segs_at")
    if sa is None and j.get("audio_track") is not None:
        sa = j["audio_track"]
        j["segs_at"] = sa
    return sa


def apply_player_track(j, _at):
    """播放器报来的音轨落到记录上：现成 segs 留还是清。只改 j，不落盘。

    - 出处已知且 == _at        → 保留（adopt）
    - 出处已知且 != _at        → 清 segs 重转（唯一清空条件）
    - 出处未知（segs_at/audio_track 都 None）→ 永不自动清，只提示
    返回 adopt / kept_unknown / cleared / reset。
    """
    if _at is None:
        # 自保：_at 缺省＝调用方没报音轨，这条函数什么都不许动。
        # 从前没有这道闸，全靠 /job 的 `_at is not None` 挡着，函数自己对 None 是会走到
        # 「sa 非 None 且 != None 且 state=done」→ 直接清光的（4e3bb1fb 实测 1025 段）。
        # 任何别的调用路径（重构 /live、调试脚本）传一次 None 就是静默毁字幕。
        return "adopt"
    j["at"] = _at
    sa = segs_source_at(j)
    if j.get("segs") and sa is None:
        j["msg"] = "音轨不一致：保留原字幕"
        return "kept_unknown"
    if sa is not None and sa != _at and j.get("segs") \
            and j.get("state") in ("done", "translating"):
        j["segs"] = []
        j["state"] = "queued"
        j["claimed"] = 0
        j["done_until"] = 0.0      # 不清会让 /work 发片尾 resume，worker 从片尾开转
        j["segs_at"] = _at
        j["msg"] = "换了音轨，重新听译"
        return "cleared"
    if sa != _at and not j.get("segs"):
        j["segs_at"] = _at         # 没有字幕可误标，记下以后这批 segs 的出处
        return "reset"
    return "adopt"


def prep_worker():
    """串行把排队任务的音频抽出来（NAS 本地读盘，只写一份 16k flac）。"""
    while True:
        with LOCK:
            job = None
            for j in T.values():
                # 只给"还没人领"的任务预抽音频（预生成场景）；正在播的任务直接流式，
                # 否则抽音频要等几分钟，用户干看着，还和流式读取抢同一块盘
                if j.get("want_audio") and not j.get("audio_ready") and not j.get("audio_fail") \
                        and j["state"] == "queued" and not j.get("claimed"):
                    job = j
                    break
        if not job:
            time.sleep(2)
            continue
        jid, path = job["id"], job.get("local_path")
        out = audio_file(jid)
        try:
            if job.get("at") is not None:          # follow_player_track
                idx, lang = job["at"], ""
            else:
                idx, lang = pick_audio_stream(path)
            if os.path.exists(out) and os.path.getsize(out) > 1024:
                # 缓存命中也得核对音轨：换了轨还复用旧 flac，转出来永远是第一轨
                if job.get("audio_track") not in (None, idx):
                    try:
                        os.remove(out)
                    except OSError:
                        pass
                    print("[prep] %s 音轨变了(%s→%s)，作废旧音频重抽" %
                          (jid, job.get("audio_track"), idx), flush=True)
                else:
                    with LOCK:
                        job["audio_ready"] = True
                        save(job)
                    continue
            args = [os.path.join(BIN, "ffmpeg"), "-hide_banner", "-loglevel", "error", "-y",
                    "-i", path]
            if idx is not None:
                args += ["-map", "0:%s" % idx]
            # 输出名以 .tmp 结尾时 ffmpeg 猜不出容器格式，必须显式 -f flac
            args += ["-vn", "-ac", "1", "-ar", "16000", "-c:a", "flac", "-f", "flac", out + ".part"]
            t0 = time.time()
            r = subprocess.run(args, capture_output=True, text=True, timeout=3600)
            if r.returncode != 0:
                raise RuntimeError((r.stderr or "ffmpeg 失败").strip().splitlines()[-1][:160])
            os.replace(out + ".part", out)
            with LOCK:
                job["audio_ready"] = True
                job["audio_track"] = idx
                if lang:
                    job["lang"] = job.get("lang") or ""
                    job["track_lang"] = lang
                save(job)
            print("[prep] %s 抽好音频 %.1fMB 用时 %.0fs" %
                  (jid, os.path.getsize(out) / 1048576.0, time.time() - t0), flush=True)
        except Exception as e:
            with LOCK:
                job["audio_fail"] = True
                job["msg"] = "NAS 抽音频失败：%s" % str(e)[:100]
                save(job)
            print("[prep] %s 失败 %s" % (jid, str(e)[:120]), flush=True)


# ---------------- HTTP ----------------
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle_one_request(self):
        # 手机切走 / 关标签页时连接被掐断是常态，不必每次打印一串 traceback
        try:
            return BaseHTTPRequestHandler.handle_one_request(self)
        except (ConnectionResetError, BrokenPipeError):
            self.close_connection = True

    def log_message(self, fmt, *a):
        sys.stderr.write("[%s] %s\n" % (time.strftime("%H:%M:%S"), fmt % a))

    def send_json(self, obj, code=200):
        b = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        for k, v in CORS.items():
            self.send_header(k, v)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(b)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(b)

    def do_OPTIONS(self):
        self.send_response(204)
        for k, v in CORS.items():
            self.send_header(k, v)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def send_media(self, path, ctype="audio/mp4"):
        """发文件，支持 Range（拖动进度必需）。"""
        size = os.path.getsize(path)
        rng = self.headers.get("Range") or ""
        start, end = 0, size - 1
        code = 200
        m = re.match(r"bytes=(\d*)-(\d*)", rng)
        if m:
            if m.group(1):
                start = int(m.group(1))
            if m.group(2):
                end = min(int(m.group(2)), size - 1)
            if start >= size:
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            code = 206
        n = end - start + 1
        self.send_response(code)
        for k, v in CORS.items():
            self.send_header(k, v)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(n))
        if code == 206:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()
        with open(path, "rb") as fh:
            fh.seek(start)
            left = n
            while left > 0:
                b = fh.read(min(1 << 16, left))
                if not b:
                    break
                self.wfile.write(b)
                left -= len(b)

    def body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n).decode("utf-8")) if n else {}

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        p = u.path.rstrip("/") or "/"
        if p == "/dupes":
            with LOCK:
                groups = {}
                for j in T.values():
                    sg = j.get("sig") or ""
                    if sg:
                        groups.setdefault(sg, []).append(j)
                out = []
                for sg, js in groups.items():
                    if len(js) > 1:
                        out.append({"sig": sg, "size": js[0].get("size", 0),
                                    "jobs": [{"id": x["id"], "name": x.get("name", ""),
                                              "state": x["state"], "url": x.get("url", ""),
                                              "done_until": x.get("done_until", 0),
                                              "segs": len(x.get("segs") or [])} for x in js]})
            return self.send_json({"dupes": out, "groups": len(groups)})

        if p == "/jobs":
            brief = "brief" in (u.query or "")
            with LOCK:
                items = [view(j) for j in T.values() if not j.get("eph")]
                if brief:                                   # 监控面板只要状态，不要几千条字幕段
                    for _x in items:
                        _x.pop("segments", None)
                act = [x for x in items if x["state"] in ("asr", "translating")]
                que = sorted([x for x in items if x["state"] == "queued"],
                             key=lambda x: (-hot_of(T.get(x["id"], {})), T.get(x["id"], {}).get("created", 0)))
                done = sorted([x for x in items if x["state"] not in ("asr", "translating", "queued")],
                              key=lambda x: -T.get(x["id"], {}).get("created", 0))
                return self.send_json({"jobs": (act + que + done)[:40], "max_active": CFG["max_active"],
                                       "active": active_count(), "ok": True})
        if p == "/health":
            now = time.time()
            with LOCK:
                return self.send_json({
                    "ok": True, "key": bool(API_KEY), "jobs": sum(1 for j in T.values() if not j.get("live")),
                    "queued": sum(1 for j in T.values() if j["state"] == "queued"),
                    "asr": sum(1 for j in T.values() if j["state"] == "asr"),
                    "translating": sum(1 for j in T.values() if j["state"] == "translating"),
                    "active": active_count(), "max_active": CFG["max_active"],
                    "stuck": sum(1 for j in T.values()
                                 if j["state"] == "asr" and now - j.get("touch", 0) > 600),
                })
        if p == "/work":
            qs = urllib.parse.parse_qs(u.query)
            wait = min(30, int((qs.get("wait") or ["0"])[0] or 0))
            end = time.time() + wait
            while True:
                now = time.time()
                with LOCK:
                    # 死掉的 worker 放的活：2 分钟没动静就收回来
                    for j in T.values():
                        if j["state"] == "asr" and now - j.get("touch", 0) > 120:
                            j["state"] = "queued"
                            j["claimed"] = 0
                            save(j)
                    pick = pick_next()   # 正在看的优先，其次先来后到
                    if pick:
                        pick["state"] = "asr"
                        pick["claimed"] = now
                        pick["touch"] = now
                        save(pick)
                        ready = bool(pick.get("audio_ready"))
                        if pick.get("live"):
                            return self.send_json({
                                "id": pick["id"], "url": pick["url"], "model": pick["model"],
                                "name": pick.get("name") or "", "live": 1,
                                "at": pick.get("at"),
                                "ss": float(pick.get("live_from") or 0),
                                "resume": float(pick.get("live_from") or 0),
                                "audio": "", "audio_pending": False,
                            })
                        return self.send_json({
                            "id": pick["id"], "url": pick["url"], "model": pick["model"],
                            "name": pick["name"], "lang_hint": lang2(pick.get("track_lang")),
                            "audio": (("http://%s/audio/%s" % (self.headers.get("Host") or "192.168.1.10:5092", pick["id"]))
                                      if ready else ""),
                            "audio_pending": bool(pick.get("want_audio")) and not ready,
                            "at": pick.get("at"),
                            "resume": float(pick.get("done_until") or 0),
                        })
                if now >= end:
                    return self.send_json({}, 204)
                time.sleep(0.5)
        if p.startswith("/audio/"):
            jid = p.split("/")[-1]
            f = audio_file(jid)
            if not os.path.exists(f):
                return self.send_json({"error": "not ready"}, 404)
            size = os.path.getsize(f)
            self.send_response(200)
            for k, v in CORS.items():
                self.send_header(k, v)
            self.send_header("Content-Type", "audio/flac")
            self.send_header("Content-Length", str(size))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            with open(f, "rb") as fh:
                while True:
                    b = fh.read(1 << 16)
                    if not b:
                        break
                    self.wfile.write(b)
            return

        if p.startswith("/srt/"):
            jid = p.split("/")[-1]
            with LOCK:
                j = T.get(jid)
                if not j:
                    return self.send_json({"error": "no such job"}, 404)
                body = srt_of(j).encode("utf-8")
                name = (j.get("name") or jid)
            name = re.sub(r"[\\/:*?\"<>|]+", "_", name)
            if not name.lower().endswith(".srt"):
                name += ".srt"
            self.send_response(200)
            for k, v in CORS.items():
                self.send_header(k, v)
            self.send_header("Content-Type", "application/x-subrip; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Content-Disposition",
                             "attachment; filename*=UTF-8''" + urllib.parse.quote(name))
            self.end_headers()
            return self.wfile.write(body)

        if p == "/probe":
            qs = urllib.parse.parse_qs(u.query)
            url = (qs.get("url") or [""])[0]
            if not url:
                return self.send_json({"error": "no url"}, 400)
            lp = local_path(url)
            if lp:
                info = probe_media(lp) or {}
            elif is_http(url):
                info = probe_url(url) or {}          # 网盘 / 另一台设备：直接 ffprobe 这个 http 地址
            else:
                return self.send_json({"ok": False, "error": "no local file"}, 404)
            info["ok"] = "error" not in info
            info["acache"] = os.path.exists(ac_file(url))
            return self.send_json(info)

        if p == "/hls":
            qs = urllib.parse.parse_qs(u.query)
            url = (qs.get("url") or [""])[0]
            if not url:
                return self.send_json({"error": "no url"}, 400)
            try:
                ss = max(0.0, float((qs.get("ss") or ["0"])[0] or 0))
            except ValueError:
                ss = 0.0
            lp = local_path(url)
            if not lp and not is_http(url):
                return self.send_json({"error": "no local file"}, 404)
            info = (probe_media(lp) if lp else probe_url(url)) or {}
            mode, hevc = play_mode(info)
            at = qs_at(qs)
            if mode != "remux":
                return self.send_json({"error": "needs_transcode"}, 415)
            key = hls_start(url, ss, hevc, at)
            ok = hls_wait(key)
            if not ok:
                return self.send_json({"error": "hls_start_failed", "key": key}, 500)
            return self.send_json({"key": key, "playlist": "/hlsm/" + key + "/index.m3u8",
                                   "ss": ss, "dur": info.get("dur") or 0})

        if p.startswith("/hlsm/"):
            parts = [x for x in p.split("/") if x]
            if len(parts) != 3:
                return self.send_json({"error": "bad path"}, 400)
            key, name = parts[1], parts[2]
            if not re.match(r"^h[0-9a-f]{16}_\d+$", key) or "/" in name or ".." in name:
                return self.send_json({"error": "bad key"}, 400)
            fp = os.path.join(HLS_DIR, key, name)
            if not os.path.exists(fp):
                return self.send_json({"error": "not found"}, 404)
            if name.endswith(".m3u8"):
                try:
                    with open(fp, "r") as fh:
                        txt = fh.read()
                except Exception:
                    txt = ""
                # 只把"文件真的写完了"的分片列给客户端：ffmpeg 是先写分片、后补列表，
                # 中间那一瞬列表里会出现还没落盘的分片，Safari/Chrome 会直接解析失败。
                lines = txt.splitlines()
                keep, i = [], 0
                while i < len(lines):
                    ln = lines[i]
                    if ln.endswith(".m4s"):
                        fp2 = os.path.join(HLS_DIR, key, ln.strip())
                        if not (os.path.exists(fp2) and os.path.getsize(fp2) > 4096):
                            if keep and keep[-1].startswith("#EXTINF"):
                                keep.pop()
                            i += 1
                            continue
                    keep.append(ln)
                    i += 1
                txt = "\n".join(keep) + "\n"
                ent = HLS_PROD.get(key)
                if "#EXT-X-ENDLIST" not in txt and ent and ent.poll() is not None:
                    txt = txt.rstrip() + "\n#EXT-X-ENDLIST\n"
                body = txt.encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/vnd.apple.mpegurl")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-cache")
                self.send_header("Access-Control-Allow-Origin", "*")
                self.end_headers()
                try:
                    self.wfile.write(body)
                except Exception:
                    pass
                return
            return self.send_media(fp, "video/mp4")

        if p == "/playstat":
            qs = urllib.parse.parse_qs(u.query)
            url = (qs.get("url") or [""])[0]
            if not url:
                return self.send_json({"error": "no url"}, 400)
            lp = local_path(url)
            if not lp:
                return self.send_json({"error": "no local file"}, 404)
            info = probe_media(lp) or {}
            mode, hevc = play_mode(info)
            key = play_key(url, 0, mode)
            done = os.path.join(PCACHE, key + ".mp4")
            if os.path.exists(done) and os.path.getsize(done) > 4096:
                return self.send_json({"ready": True, "pct": 100, "mode": mode})
            return self.send_json({"ready": False, "pct": 0, "mode": mode})

        if p == "/play":
            qs = urllib.parse.parse_qs(u.query)
            url = (qs.get("url") or [""])[0]
            try:
                ss = max(0.0, float((qs.get("ss") or ["0"])[0] or 0))
            except ValueError:
                ss = 0.0
            if not url:
                return self.send_json({"error": "no url"}, 400)
            lp = local_path(url)
            if not lp and not is_http(url):
                return self.send_json({"error": "no local file"}, 404)
            info = (probe_media(lp) if lp else probe_url(url)) or {}
            info["name"] = os.path.basename(lp) if lp else "remote"
            mode, hevc = play_mode(info)
            at = qs_at(qs)
            key = play_key(url, ss, mode, at)
            done = os.path.join(PCACHE, key + ".mp4")
            if os.path.exists(done) and os.path.getsize(done) > 4096:
                return self.send_media(done, "video/mp4")     # 转好的：Range 发，能随便拖
            if mode == "remux":
                return stream_part(self, key, play_args(url, ss, mode, hevc, at), "video/mp4")
            # 要重编码的（H.264 10bit）不接：电脑转码已按用户要求拆掉，NAS 转只有 0.6x 实时会卡
            return self.send_json({"error": "needs_transcode"}, 415)

        if p == "/atrack":
            qs = urllib.parse.parse_qs(u.query)
            url = (qs.get("url") or [""])[0]
            ss = (qs.get("ss") or ["0"])[0]
            if not url:
                return self.send_json({"error": "no url"}, 400)
            if not local_path(url) and not is_http(url):
                return self.send_json({"error": "no local file"}, 404)
            try:
                ss = max(0.0, float(ss or 0))
            except ValueError:
                ss = 0.0
            return stream_audio(self, url, ss, qs_at(qs))

        if p.startswith("/job/"):
            with LOCK:
                jj = T.get(p[5:])
                if jj:
                    mark_hot(jj)
            jid = p.split("/")[-1]
            with LOCK:
                j = T.get(jid)
                if not j:
                    return self.send_json({"error": "no such job"}, 404)
                return self.send_json(view(j))
        return self.send_json({"error": "not found"}, 404)

    def do_POST(self):
        p = urllib.parse.urlparse(self.path).path.rstrip("/")
        try:
            d = self.body()
        except Exception:
            return self.send_json({"error": "bad json"}, 400)

        if p == "/live":
            url = (d.get("url") or "").strip()
            if not url:
                return self.send_json({"error": "缺 url"}, 400)
            try:
                start = max(0.0, float(d.get("start") or 0))
            except Exception:
                start = 0.0
            model = d.get("model") if d.get("model") in ("turbo", "small") else "turbo"
            # follow_player_track：前端带上播放器当前选的音轨（ffmpeg 流序号）
            try:
                _at = int(d.get("at")) if d.get("at") not in (None, "") else None
            except Exception:
                _at = None
            # live_keep_segs：实时也按「文件」存，同一部片子只有一个记录，
            # 已经转好的字幕落在 segs 里，拖回去直接拿来用，不重转。
            jid = key_of(url)
            now = time.time()
            with LOCK:
                cur = T.get(jid)
                # at      = 播放器现在在哪条流（会跟着用户换轨漂）
                # segs_at = 现有 segs 是哪条流转出来的（只在重转/新建时改）
                # 快返只在两条一致时成立；_at 缺省（老前端）不回写、仍可快返。
                # 老记录没有 segs_at 时先用 audio_track 回填再看（出处已知就照常快返），
                # 两者都缺（出处未知）才不快返 —— 宁可落下去走复用分支重判。
                if cur and (_at is None or segs_source_at(cur) == _at) \
                        and covered_by(cur.get("segs") or [], start):
                    cur["hot"] = now
                    cur["touch"] = now
                    if _at is not None and cur.get("at") != _at:
                        cur["at"] = _at            # 只挪播放器位置，不碰 segs_at
                        save(cur)
                    return self.send_json(view(cur))
                if cur and cur["state"] not in ("done", "error", "cancelled") and not cur.get("live"):
                    # 整片任务正在跑：别抢，按它的进度走
                    cur["hot"] = now
                    return self.send_json(view(cur))
                # 同一部片子的其它实时会话（换了位置）：收工，新的一段接着转
                for x in list(T.values()):
                    if x.get("live") and x.get("url") == url and x["id"] != jid \
                            and x["state"] not in ("done", "error", "cancelled"):
                        x["state"] = "cancelled"
                        x["msg"] = "换了播放位置"
                        save(x)
                if cur:
                    # 复用已有记录（可能是整片听译留下的）：字幕只有在「本来就是这条流转的」时才留。
                    # 清空 segs 的唯一条件＝出处已知（segs_at，老记录用 audio_track 回填）且 != _at；
                    # 出处未知时宁可留着（错也比没了强），别拿 _at 顶成 segs_at。
                    _sa = segs_source_at(cur)
                    stale = _at is not None and _sa is not None and _sa != _at
                    # kept_unknown 的保护必须到这一步才算数（M #74 三）：出处未知 + 有现成字幕 +
                    # 播放器报了个音轨 → 连排队都不进。只要落了 state=queued/claimed=0，worker 就按
                    # 新流重转，产出的段经 /cue 按时间区间把旧段逐段顶掉 ——「不清」只是延时，不是保护。
                    # 代价（已知、M 已裁）：这类老任务点实时听译不会出新字幕，要等用户手动切轨再重来。
                    if _at is not None and _sa is None and cur.get("segs"):
                        cur.update({"hot": now, "touch": now, "at": _at,
                                    "msg": "音轨不一致：保留原字幕"})
                        save(cur)
                        return self.send_json(view(cur))
                    cur.update({"live": 1, "live_from": start, "state": "queued",
                                "claimed": 0, "hot": now, "touch": now})
                    if _at is not None and _sa is None and not cur.get("segs"):
                        # 空着重启（cancelled 留空 / 手工清过）且播放器报了音轨：这批新 segs 的出处
                        # 就是 _at，现在写下来。不写的话它永远是「出处未知」，下一次带 at 的 /live
                        # 会被上面那道早退拦住，越转越分不清 —— 与 apply_player_track 的 reset 分支同义。
                        cur["segs_at"] = _at
                    if stale:
                        # 别的流的字幕不许顶上来：segs / 进度 / 抽好的音频一起作废
                        cur.update({"segs": [], "done_until": start, "asr_p0": 0.0,
                                    "audio_ready": False, "audio_track": None,
                                    "segs_at": _at, "at": _at,
                                    "msg": "换了音轨，重新听译"})
                        try:
                            if os.path.exists(audio_file(jid)):
                                os.remove(audio_file(jid))
                        except OSError:
                            pass
                    else:
                        cur["msg"] = "实时听译排队中…"
                        if _at is not None:
                            cur["at"] = _at
                        if start > float(cur.get("done_until") or 0):
                            cur["done_until"] = start
                    j = cur
                else:
                    j = {"id": jid, "url": url, "name": d.get("name") or "", "model": model,
                         "local_path": local_path(url), "want_audio": False, "audio_ready": False,
                         "state": "queued", "lang": "", "done_until": start, "msg": "实时听译排队中…",
                         "segs": [], "created": now, "claimed": 0, "touch": now, "dur": 0,
                         "reused": False, "sig": "", "size": 0, "alt_urls": [],
                         "eph": 1, "hot": now, "live": 1, "live_from": start,
                         "at": _at, "segs_at": _at}
                    T[jid] = j
            save(j)
            return self.send_json(view(j))

        if p == "/job":
            url = (d.get("url") or "").strip()
            if not url:
                return self.send_json({"error": "no url"}, 400)
            watcher = bool(d.get("hot"))     # 播放器发来的 = 用户正在看
            with LOCK:
                exists = key_of(url) in T and T[key_of(url)]["state"] not in ("cancelled", "error", "done")
                n = active_count()
            if not exists and not watcher and n >= CFG["max_active"]:
                return self.send_json({"error": "queue_full", "max": CFG["max_active"],
                                       "active": n}, 429)
            j = new_job(url, d.get("name") or "", d.get("model") or "turbo", watcher)
            # follow_player_track
            try:
                _at = int(d.get("at")) if d.get("at") not in (None, "") else None
            except Exception:
                _at = None
            if _at is not None and j.get("at") != _at:
                # 收养（保留现成字幕）= 这批 segs 确实出自 _at 这条流，判条件见 apply_player_track：
                # 出处只认 segs_at（老记录缺它时用 audio_track 回填，那才是抽音频的流），
                # 不拿 _at 顶上 —— 拿 _at 顶等于把错轨字幕钉死，以后再也分不出真假。
                # 火山挚恋 segs 出自 chi(3)、鬼谜东宫出自 kor(4)，第 1 条是 fre/eng，别按「第 1 条」想当然。
                apply_player_track(j, _at)
                save(j)
            return self.send_json({"id": j["id"], "state": j["state"], "reused": j.get("reused", False),
                                   "via": "sig" if j.get("url") != url else "url",
                                   "sig": j.get("sig", ""), "name": j.get("name", "")})

        if p == "/ol/job":
            # 在线播放用：建一个临时听译任务。不占队列名额、不进监控列表，播完就删。
            url = (d.get("url") or "").strip()
            if not url:
                return self.send_json({"error": "no url"}, 400)
            # 顺手清掉 6 小时前的临时任务
            now = time.time()
            for k, v in list(T.items()):
                if v.get("eph") and now - float(v.get("created") or 0) > 6 * 3600:
                    T.pop(k, None)
                    for f in (os.path.join(JOBS, k + ".json"), audio_file(k)):
                        try:
                            os.remove(f)
                        except OSError:
                            pass
            with LOCK:
                j0 = T.get(key_of(url))
                if j0 and j0["state"] not in ("cancelled", "error", "done"):
                    j0["eph"] = 1
                    j0["hot"] = time.time()
                    save(j0)
                    return self.send_json({"id": j0["id"], "state": j0["state"], "reused": True})
            j = new_job(url, d.get("name") or "", d.get("model") or "turbo", True, eph=True)
            return self.send_json({"id": j["id"], "state": j["state"], "reused": False})

        if p == "/ol/drop":
            # 用完就丢：任务、音频、字幕文件一起删
            jid = (d.get("id") or "").strip()
            if not jid:
                return self.send_json({"ok": False}, 400)
            with LOCK:
                T.pop(jid, None)
            for f in (os.path.join(JOBS, jid + ".json"), audio_file(jid)):
                try:
                    os.remove(f)
                except OSError:
                    pass
            return self.send_json({"ok": True})

        if p == "/find":
            # 只查不建：播放时用来看这集是不是已经听过（或正在听），避免一播放就开新任务
            url = (d.get("url") or "").strip()
            if not url:
                return self.send_json({"found": False})
            with LOCK:
                j = T.get(key_of(url))
            if not j:
                size, sig = sig_of(url, d.get("name") or "")
                if sig:
                    with LOCK:
                        j = pick_by_sig(sig, "")
            if not j:
                return self.send_json({"found": False})
            return self.send_json({"found": True, "id": j["id"], "state": j["state"],
                                   "done_until": j.get("done_until", 0),
                                   "segs": len(j.get("segs") or [])})

        if p == "/cue":
            jid = d.get("id") or ""
            with LOCK:
                j = T.get(jid)
                if not j:
                    # 任务已经被删/重置了：直接回“取消”，让转写工放手。
                    # 不能回 404 —— 老版本 worker 会把它当网络错误无限重试，把整条队列卡死。
                    return self.send_json({"ok": True, "cancel": True, "gone": True, "n": 0})
                got = d.get("segs") or []
                for seg in got:
                    if not isinstance(seg, (list, tuple)) or len(seg) < 3:
                        continue
                    s0, s1 = float(seg[0]), float(seg[1])
                    # live_keep_segs：同一段时间重转（拖回去/重开播放器）时替换掉旧的，别堆重复
                    j["segs"] = [x for x in j["segs"] if not (float(x[0]) < s1 and float(x[1]) > s0)]
                    j["segs"].append([s0, s1, str(seg[2]).strip(), ""])
                j["segs"].sort(key=lambda x: float(x[0]))
                if d.get("lang") and not j.get("lang"):
                    j["lang"] = str(d["lang"])
                if d.get("done_until"):
                    j["done_until"] = float(d["done_until"])
                if d.get("msg") is not None:
                    j["msg"] = str(d["msg"])[:120]
                j["touch"] = time.time()
                if got and not j.get("asr_t0"):
                    j["asr_t0"] = time.time()
                    j["asr_p0"] = float(j.get("done_until") or 0)
                if j["state"] == "queued":
                    j["state"] = "asr"
                # 有"用户正在看"的任务在排队 → 让转写工干完这一块就换人（字幕已经存好了）
                cur = hot_of(j)
                sw = False
                for x in ([] if j.get("live") else T.values()):
                    if x["id"] != jid and x["state"] == "queued":
                        h = hot_of(x)
                        if h and h > cur + 5:
                            sw = True
                            break
                if sw:
                    j["state"] = "queued"
                    j["claimed"] = 0
                snap = dict(j)
                snap["segs"] = list(j["segs"])
                resp = {"ok": True, "n": len(j["segs"]),
                        "cancel": j["state"] == "cancelled", "switch": sw}
            try:
                save(snap)          # 锁外面写盘，别的请求不用等磁盘
            except Exception:
                pass
            return self.send_json(resp)

        if p == "/finish":
            jid = d.get("id") or ""
            with LOCK:
                j = T.get(jid)
                if not j:
                    return self.send_json({"error": "no such job"}, 404)
                j["asr_done"] = True
                j["touch"] = time.time()
                if d.get("dur"):
                    j["dur"] = float(d["dur"])
                if d.get("lang"):
                    j["lang"] = str(d["lang"])
                if not j["segs"]:
                    j["state"] = "done"
                    j["msg"] = "没听到人声"
                elif all(s[3] for s in j["segs"]):
                    j["state"] = "done"
                else:
                    j["state"] = "translating"
                save(j)
            drop_audio(jid)          # 转写已经完了，音频没用了
            return self.send_json(view(j))

        if p == "/cancel":
            jid = (d.get("id") or "")
            if not jid and self.path.split("/")[-1] not in ("", "cancel"):
                jid = self.path.split("/")[-1]
            with LOCK:
                j = T.get(jid)
                if not j:
                    return self.send_json({"error": "no such job"}, 404)
                if j["state"] not in ("done", "error"):
                    j["state"] = "cancelled"
                    j["msg"] = "已停止"
                    save(j)
                return self.send_json({"ok": True, "state": j["state"]})

        if p == "/delete":
            jid = d.get("id") or ""
            with LOCK:
                j = T.get(jid)
                if not j:
                    return self.send_json({"error": "no such job"}, 404)
                if j["state"] in ("queued", "asr", "translating"):
                    return self.send_json({"error": "busy", "state": j["state"],
                                           "msg": "先停止这个任务，才能删除"}, 409)
                name = j.get("name") or jid
                T.pop(jid, None)
            for f in (os.path.join(JOBS, jid + ".json"), os.path.join(AUDIO, jid + ".flac"),
                      os.path.join(AUDIO, jid + ".part")):
                try:
                    os.remove(f)
                except OSError:
                    pass
            return self.send_json({"ok": True, "deleted": jid, "name": name})

        if p == "/config":
            with LOCK:
                if isinstance(d.get("max_active"), int) and d["max_active"] > 0:
                    CFG["max_active"] = max(1, min(50, d["max_active"]))
                    save_conf()
                return self.send_json({"ok": True, "max_active": CFG["max_active"],
                                       "active": active_count()})

        if p == "/reset":
            jid = d.get("id") or ""
            with LOCK:
                j = T.get(jid)
                if not j:
                    return self.send_json({"error": "no such job"}, 404)
                j["segs"] = []
                j["done_until"] = 0.0
                j["state"] = "queued"
                j["claimed"] = 0
                j["msg"] = ""
                j["asr_done"] = False
                j["asr_t0"] = 0
                j["asr_p0"] = 0
                j["lang"] = ""
                j["audio_fail"] = False
                j["touch"] = time.time()
                save(j)
                return self.send_json({"ok": True, "state": "queued"})

        if p == "/fail":
            jid = d.get("id") or ""
            with LOCK:
                j = T.get(jid)
                if not j:
                    return self.send_json({"error": "no such job"}, 404)
                j["state"] = "error"
                j["msg"] = str(d.get("msg") or "转写失败")[:200]
                save(j)
                return self.send_json({"ok": True})
        return self.send_json({"error": "not found"}, 404)


def main():
    load_conf()
    load_all()
    threading.Thread(target=sweep_audio, daemon=True).start()
    threading.Thread(target=backfill_sigs, daemon=True).start()
    threading.Thread(target=prep_worker, daemon=True).start()
    for _ in range(TR_THREADS):
        threading.Thread(target=translator, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", PORT), H)
    srv.daemon_threads = True
    print("听译中枢启动: 0.0.0.0:%d  任务 %d 个  DeepSeek密钥 %s" %
          (PORT, len(T), "已加载" if API_KEY else "缺失"), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()

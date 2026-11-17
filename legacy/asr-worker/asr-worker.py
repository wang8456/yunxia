#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""asr-worker.py —— 电脑上的转写工（唯一需要 CPU 的部分）

流程：向 NAS 中枢要活 → ffprobe 看清时长/音轨 → **分块**边抽边转（首块 45 秒，之后 180 秒一块）
     → 每块转完立刻把带时间轴的段落推回中枢，手机就能边看边长字幕。

为什么分块：4K 一集 7.4GB，从头顺序抽完整片音频要 9-10 分钟，这期间用户只看到"已听译 0 秒"；
切块后首条字幕 30 秒内出现，而且边抽边转能一直跑在播放前头。

为什么按语言挑音轨：MULTi 资源默认轨常常是英语配音，不挑就等于在给配音轨做听写。

用法：
  asr-worker.py                    # 默认 http://192.168.1.10:5092，faster-whisper 引擎
  asr-worker.py --engine cpp       # 退回 whisper.cpp
  asr-worker.py --hub http://127.0.0.1:5092 --once
"""
import argparse
import json
import socket
import urllib.parse
import os
import re
import subprocess
import time
import threading
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
BIN = os.path.join(HOME, ".hermes/tools/ffmpeg-9.0.1-linux-x64/bin")
FFMPEG = os.path.join(BIN, "ffmpeg")
FFPROBE = os.path.join(BIN, "ffprobe")
WC_DIR = os.path.join(HOME, "apps/whisper.cpp")
MODELS = {"turbo": "ggml-large-v3-turbo-q5_0.bin", "small": "ggml-small-q5_1.bin"}
CHUNK_FIRST = 45          # 第一块短：先让首条字幕尽快出来
LIVE_WIN = float(os.environ.get("LIVE_WIN", "12"))    # 实时模式一窗多长（20→12：字幕更跟手，代价是断句略碎）
LIVE_RECON_MAX = 10          # 主流被播放器抢断时，最多重连这么多次
LIVE_OV = float(os.environ.get("LIVE_OV", "2"))       # 相邻窗重叠，防断句（3→2：每窗少重转 1 秒）
LIVE_RATE = 16000
LIVE_BPS = 2 * LIVE_RATE
# 实时听只往播放头前面多转这么多秒：再多就是「偷偷整片转」，会一直占着转写槽，
# 队列任务全排在后面。播到边上了由播放器再续一个窗口。
LIVE_AHEAD = float(os.environ.get("LIVE_AHEAD", "150"))
CHUNK = 60               # 之后每块多长（180→60：实时听要插队时最多等 1 分钟，不是 3 分钟）
# 原声轨优先顺序：**已不参与选轨**（10-28 按 M #74 四 改成 disposition.default 优先，
# 与 /play 的 0:a:0、hub.pick_audio_stream 对齐）。留着只作人工读代码时的语言备注。
LANG_PREF = ["zho", "chi", "cmn", "yue", "kor", "jpn", "eng"]
# ffprobe 给的是 ISO 639-2（kor/zho/eng…），whisper 只认 ISO 639-1（ko/zh/en…），必须翻译一次
W2L = {"zho": "zh", "chi": "zh", "cmn": "zh", "yue": "zh", "kor": "ko", "jpn": "ja",
       "eng": "en", "spa": "es", "ita": "it", "fra": "fr", "fre": "fr", "deu": "de",
       "ger": "de", "rus": "ru", "por": "pt", "ara": "ar", "hin": "hi", "tha": "th",
       "vie": "vi", "tur": "tr", "nld": "nl", "dut": "nl", "pol": "pl", "swe": "sv"}


VALID_L2 = set("""af am ar as az ba be bg bn bo br bs ca cs cy da de el en es et eu fa fi fo fr gl gu ha
haw he hi hr ht hu hy id is it ja jw ka kk km kn ko la lb ln lo lt lv mg mi mk ml mn mr ms mt my ne nl
nn no oc pa pl ps pt ro ru sa sd si sk sl sn so sq sr su sv sw ta te tg th tk tl tr tt uk ur uz vi yi
yo zh""".split())


def w2l(tag):
    t = (tag or "").lower()
    return W2L.get(t) or (t if len(t) == 2 else None)


def safe_lang(tag):
    """给 whisper 的语言码必须是它认识的两位码，认不出就返回 None 让它自动识别。
    （直接用 ffprobe 的 kor/jpn 会让整单失败：'kor' is not a valid language code）"""
    t = w2l(tag)
    if not t:
        return None
    t = t.split("-")[0].split("_")[0]
    return t if t in VALID_L2 else None

SEG_RE = re.compile(r"\[\s*(\d+):(\d+):(\d+)\.(\d+)\s*-->\s*(\d+):(\d+):(\d+)\.(\d+)\s*\]\s*(.*)")
LANG_RE = re.compile(r"auto-detected language:\s*([a-zA-Z]+)")

# whisper 在静音/音乐段会凭空造出来的"经典台词"（尤其中文），必须滤掉，否则字幕里突然多一句广告
HALLUC = re.compile(
    r"(点赞|訂閱|订阅|转发|打赏|明镜|點點欄目|点点栏目|字幕由|字幕提供|谢谢观看|感謝觀看|"
    r"请不吝|Thanks for watching|Subscribe|subscribe|Amara\.org|www\.|"
    # whisper 在静音/片尾名单上最常凭空写出来的几句
    r"Transcription by|Subtitles by|Captions by|CastingWords|"
    r"字幕由|本字幕由|中文字幕|校对[:：])", re.I)

_MODELS = {}


def log(*a):
    print("[%s]" % time.strftime("%H:%M:%S"), *a, flush=True)


def is_halluc(text, dur):
    t = (text or "").strip()
    if not t:
        return True
    if HALLUC.search(t):
        return True
    # 30 秒长的一段字幕但只有几个字，基本是幻听
    if dur > 20 and len(t) < 12:
        return True
    return False


def api(hub, path, data=None, timeout=40):
    url = hub.rstrip("/") + path
    body = json.dumps(data).encode("utf-8") if data is not None else None
    req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return json.loads(raw.decode("utf-8")) if raw else {}
    except urllib.error.HTTPError as e:
        if e.code == 204:
            return None
        raise


def probe(url):
    """→ (时长秒, 用哪个音轨 index, 音轨语言)。"""
    try:
        out = subprocess.run(
            [FFPROBE, "-v", "error", "-show_entries",
             "format=duration:stream=index,codec_type:stream_tags=language"
             ":stream_disposition=default",
             "-of", "json", url], capture_output=True, text=True, timeout=180).stdout
        d = json.loads(out or "{}")
    except Exception as e:
        log("探测失败（按整片处理）:", str(e)[:100])
        return 0.0, None, ""
    dur = float((d.get("format") or {}).get("duration") or 0)
    auds = [s for s in d.get("streams", []) if s.get("codec_type") == "audio"]
    if not auds:
        return dur, None, ""
    # 选轨不变式：字幕必须跟耳朵对齐。/play 在 at 缺失时 map 的是 0:a:0（文件里第一条音轨），
    # 所以这里也优先 disposition.default==1，没有 default 标记才取第一条。
    # LANG_PREF 不再参与选轨（常量留着只作语言标注）：按语言偏好会挑到中配轨，而画面放的是
    # 原声 —— 火山挚恋 chi(3) 的字幕配 fre(1) 的声音就是这么来的。与 hub.pick_audio_stream 同规格。
    pick = auds[0]
    for a in auds:
        try:
            if int((a.get("disposition") or {}).get("default") or 0) == 1:
                pick = a
                break
        except (TypeError, ValueError):
            continue
    lang = w2l((pick.get("tags") or {}).get("language") or "") or ""
    log("音轨 %d 条 → 用 index %s（语言 %s，default=%s）"
        % (len(auds), pick.get("index"), lang or "未标注",
           (pick.get("disposition") or {}).get("default")))
    return dur, pick.get("index"), lang


def extract(url, aidx, start, length, out):
    args = [FFMPEG, "-hide_banner", "-loglevel", "error", "-y"]
    if start:
        args += ["-ss", "%.2f" % start]
    args += ["-i", url]
    if length:
        args += ["-t", "%.2f" % length]
    if aidx is not None:
        args += ["-map", "0:%s" % aidx]
    args += ["-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", "-f", "wav", out]
    r = subprocess.run(args, capture_output=True, text=True, timeout=1800)
    if r.returncode != 0:
        lines = [x for x in (r.stderr or "").strip().splitlines() if x.strip()]
        raise RuntimeError(lines[-1] if lines else "ffmpeg 失败")
    return os.path.getsize(out) / 32000.0 if os.path.exists(out) else 0.0


class Pusher(object):
    """攒几段就推一次，别一段一个请求。"""

    def __init__(self, hub, jid):
        self.hub, self.jid = hub, jid
        self.buf, self.last = [], 0.0
        self.lang, self.pushed, self.until = "", 0, 0.0
        self.tmp = ""
        self.cancelled = False
        self.preempted = False
        self.pos = 0.0        # 中枢回传的播放头（实时听靠它决定要不要继续往前转）
        self.live = False

    def msg(self, m):
        try:
            api(self.hub, "/cue", {"id": self.jid, "segs": [], "msg": m}, timeout=20)
        except Exception:
            pass

    def add(self, s, e, text):
        text = (text or "").strip()
        if not text or is_halluc(text, e - s):
            if text:
                log("滤掉疑似幻听:", text[:24])
            return
        self.buf.append([round(s, 3), round(e, 3), text])
        if len(self.buf) >= 6 or time.time() - self.last > 2.0:
            self.flush(e)

    def flush(self, done_until=None):
        if self.buf:
            self.until = max(self.until, float(self.buf[-1][1]))
        if done_until:
            self.until = max(self.until, float(done_until))
        if not self.buf:
            return
        try:
            r = api(self.hub, "/cue", {"id": self.jid, "segs": self.buf,
                                       "done_until": self.until, "lang": self.lang}, timeout=25)
            if isinstance(r, dict) and r.get("cancel"):
                self.cancelled = True
                log("中枢说这个任务已取消，马上收手")
            if isinstance(r, dict):
                self.pos = float(r.get("pos") or 0)
                self.live = bool(r.get("live"))
            if isinstance(r, dict) and r.get("switch"):
                self.preempted = True
                log("用户正在看别的片子，先让路（进度已存，回头接着转）")
            self.pushed += len(self.buf)
            self.buf, self.last = [], time.time()
        except urllib.error.HTTPError as e:
            if e.code == 404:
                # 中枢上这个任务已经不存在了（被删/被重置）——不能死循环重试，直接放手
                self.cancelled = True
                self.buf, self.last = [], time.time()
                log("中枢上已经没有这个任务了（可能被删或取消），收手")
                return
            log("推字幕失败（随下一批重试）:", str(e)[:80])
        except Exception as e:
            log("推字幕失败（随下一批重试）:", str(e)[:80])


class LiveBuf(object):
    """后台线程不停读 ffmpeg 的 PCM，转写只管从缓冲里取——抽音和转写并行，别串行等。"""

    MAXS = 45 * 32000          # 最多攒 45 秒：够领先画面，又不至于把解码跑飞

    def __init__(self, proc):
        self.p = proc
        self.b = bytearray()
        self.eof = False
        self.lock = threading.Condition()
        self.err = ""
        self.t = threading.Thread(target=self._run, daemon=True)
        self.t.start()

    def _run(self):
        try:
            while True:
                with self.lock:
                    while len(self.b) > self.MAXS and not self.eof:
                        self.lock.wait(0.5)
                c = self.p.stdout.read(1 << 16)
                if not c:
                    break
                with self.lock:
                    self.b.extend(c)
                    self.lock.notify_all()
        except Exception as e:
            self.err = str(e)[:100]
        finally:
            with self.lock:
                self.eof = True
                self.lock.notify_all()

    def wait(self, n):
        """等够 n 字节（或源结束）"""
        with self.lock:
            while len(self.b) < n and not self.eof:
                self.lock.wait(0.7)
            return len(self.b)

    def peek(self, n):
        with self.lock:
            return bytes(self.b[:n])

    def take(self, n):
        with self.lock:
            out = bytes(self.b[:n])
            del self.b[:n]
            self.lock.notify_all()
            return out


class FiltPusher(Pusher):
    """实时模式专用：丢掉落在上一窗重叠区里的段，避免字幕重复。"""

    def __init__(self, hub, jid):
        Pusher.__init__(self, hub, jid)
        self.cover = 0.0

    def add(self, s, e, text):
        if e <= self.cover + 0.2:
            return
        Pusher.add(self, max(s, self.cover), e, text)


def do_live(hub, job, engine):
    """实时听译（常驻会话）。

    一条 ffmpeg 顺序吐 PCM，12 秒一窗转写，边转边推。**追上「播放头 + ahead」
    不再退出**：挂起等播放头前进，ffmpeg 和缓冲保持打开。以前每次续窗都要
    重开 ffmpeg、缓冲从 0 爬到 45 秒，白扔 3-10 秒，用户体感就是「到播放位置
    才开始续」。

    真正收尾只有四种情况：中枢说取消/换位置、读到片尾、中枢 60 秒没响应、
    或者任务被删（/cue 回 gone）。
    """
    jid = job["id"]
    ss_pos = float(job.get("ss") or job.get("resume") or 0)
    model = job.get("model") or "turbo"
    # 热词：片名 / 人名 / 术语，喂给模型当 hotwords，专有名词不容易听错
    words = (job.get("words") or "").strip()[:200]
    # 预转窗口：播放器暂停时中枢会把它放大（600 秒），默认还是 LIVE_AHEAD
    try:
        ahead = float(job.get("ahead") or 0) or float(LIVE_AHEAD)
    except Exception:
        ahead = float(LIVE_AHEAD)
    if words:
        log("热词:", words)
    url = localize(job["url"])
    # 真实片长：只在断流时才问（ffprobe 读头，几秒），缓存住别反复问
    _dur_now = {"v": 0.0}

    def real_total():
        if _dur_now["v"] > 0:
            return _dur_now["v"]
        _d, _t, _l = probe(url)
        _dur_now["v"] = float(_d or 0)
        if _dur_now["v"] > 0:
            log("真实片长 %.0f 秒（断流判断用）" % _dur_now["v"])
        return _dur_now["v"]

    pusher = FiltPusher(hub, jid)
    pusher.msg("实时听译开始…从 %d 分 %02d 秒起" % (int(ss_pos) // 60, int(ss_pos) % 60))
    log("实时任务 %s 从 %.0fs 开始（窗 %.0fs 重叠 %.0fs，常驻）"
        % (jid, ss_pos, LIVE_WIN, LIVE_OV))
    t0 = time.time()
    ff = None
    errf = "/tmp/live-%s.err" % jid
    import tempfile
    import wave
    fd, wav = tempfile.mkstemp(suffix=".wav", dir="/tmp", prefix="live-")
    os.close(fd)

    def hb(base, win_dur=0.0, idle=False):
        """2 秒一次心跳，带回取消、播放头、目标、冷却、降级。"""
        try:
            r = api(hub, "/cue", {"id": jid, "segs": [],
                                  "base": round(base, 1),
                                  "win_dur": round(win_dur, 2),
                                  "idle": 1 if idle else 0,
                                  "pushed": pusher.pushed}, timeout=8)
        except Exception:
            return None
        if not isinstance(r, dict):
            return None
        if r.get("cancel"):
            pusher.cancelled = True
            log("中枢说换位置/取消（心跳），收手")
        pusher.pos = float(r.get("pos") or pusher.pos or 0)
        pusher.live = bool(r.get("live"))
        return r

    def open_stream(start):
        largs = [FFMPEG, "-nostdin", "-v", "error", "-readrate", "4",
                 "-threads", "2", "-ss", str(start), "-i", url]
        if job.get("at") is not None:          # 跟随播放器选的音轨
            largs += ["-map", "0:%d" % job["at"]]
            log("实时按播放器选的音轨：index %d" % job["at"])
        largs += ["-vn", "-ac", "1", "-ar", str(LIVE_RATE), "-f", "s16le", "-"]
        return subprocess.Popen(largs, stdout=subprocess.PIPE,
                                stderr=open(errf, "wb"), bufsize=0,
                                preexec_fn=lambda: os.nice(15))

    def run_win(buf, base, take):
        with wave.open(wav, "wb") as w:
            w.setnchannels(1)
            w.setsampwidth(2)
            w.setframerate(LIVE_RATE)
            w.writeframes(buf.peek(take))
        _t = time.time()
        if engine == "fw":
            transcribe_fw(wav, model, pusher, base, take / float(LIVE_BPS),
                          pusher.lang or None, beam=1, retry=False, hot=words)
        else:
            transcribe_cpp(wav, model, pusher, base, take / float(LIVE_BPS),
                           None, hot=words)
        return time.time() - _t

    def kill_ff():
        try:
            if ff is not None and ff.poll() is None:
                ff.kill()
        except Exception:
            pass

    cuts = 0                              # 断流重连次数
    try:
        while True:                       # 外层：换位置 / 断流重开
            ff = open_stream(ss_pos)
            buf = LiveBuf(ff)
            base = ss_pos
            first = True
            n = 0
            last_hb = 0.0
            next_ss = None                # 非空 = 换位置重开
            drop_stream = False           # 挂起太久，缓冲别一直涨
            while True:                   # 内层：一窗一窗转
                if pusher.cancelled:
                    log("实时任务被叫停，已推 %d 段" % pusher.pushed)
                    break
                # 心跳：静音窗不会走到 flush，靠它把取消/目标带回来
                if time.time() - last_hb > 2.0:
                    last_hb = time.time()
                    r = hb(base)
                    if pusher.cancelled:
                        break
                    if r:
                        if r.get("ahead"):
                            ahead = float(r["ahead"])
                        if r.get("goto") not in (None, "", 0):
                            next_ss = float(r["goto"])
                            log("中枢要求换位置到 %.0fs" % next_ss)
                            break
                        _cool = float(r.get("cool") or 0)
                        if _cool > 0:
                            log("中枢说这段在空转，歇 %.0f 秒" % _cool)
                            _end = time.time() + _cool
                            while time.time() < _end and not pusher.cancelled:
                                time.sleep(2)
                                hb(base, idle=True)
                            continue
                # 真从头播：3 秒首窗；从中间接着听：6 秒；之后 12 秒
                win = 3.0 if (first and ss_pos <= 0.5) else (6.0 if first else LIVE_WIN)
                need = int(win * LIVE_BPS)
                have = buf.wait(need)
                if have < LIVE_BPS:            # 片尾 / 断流
                    if buf.eof:
                        left = buf.wait(LIVE_BPS)
                        if left >= LIVE_BPS and left < need:
                            pusher.cover = base + LIVE_OV
                            _dt = run_win(buf, base, left)
                            pusher.flush(base + left / float(LIVE_BPS))
                            log("片尾补窗 %.0fs，用时 %.1fs" % (left / float(LIVE_BPS), _dt))
                        else:
                            # 缓冲见底 + ffmpeg 退出：可能是真片尾，也可能是
                            # 播放器在读同一个 115 文件、把这条流掐了。
                            # 以前一律当片尾 → 任务变 done，界面上只剩一句字幕。
                            _tot = real_total()
                            if _tot and base < _tot - 45 and cuts < LIVE_RECON_MAX:
                                cuts += 1
                                log("主流在 %.0fs 断了（还剩 %.0f 秒没转，已推 %d 段），"
                                    "从这儿重连第 %d 次"
                                    % (base, _tot - base, pusher.pushed, cuts))
                                pusher.msg("视频流被抢断了，从 %d 分 %02d 秒接着听"
                                           % (int(base) // 60, int(base) % 60))
                                time.sleep(min(2 * cuts, 8))
                                drop_stream = True
                                break
                            if _tot and cuts >= LIVE_RECON_MAX:
                                log("断流重连 %d 次仍未接上，收尾" % LIVE_RECON_MAX)
                    break
                take = min(need, have)
                pusher.cover = base if first else base + LIVE_OV
                _dt = run_win(buf, base, take)
                pusher.flush(base + take / float(LIVE_BPS))
                n += 1
                log("  ↳ 转写 %.1fs（音频 %.0fs，负载 %.1f）"
                    % (_dt, take / float(LIVE_BPS), os.getloadavg()[0]))
                log("实时窗 %d [%.0f-%.0fs] 已推 %d 段 | 缓冲 %.0fs | 处理已走 %.0fs"
                    % (n, base, base + take / float(LIVE_BPS), pusher.pushed,
                       len(buf.b) / float(LIVE_BPS), time.time() - t0))
                # 这一窗转太久（115 读盘慢 / 人声密集，实测最长 23.9 秒）：
                # 下一窗不再重叠，直接切到新音频把时间追回来。
                _ov = 0.0 if _dt > 12.0 else LIVE_OV
                if _ov == 0.0:
                    log("  这一窗 %.1fs 太慢，下一窗丢掉重叠追进度" % _dt)
                step = int((win - _ov) * LIVE_BPS)
                buf.take(step)                 # 重叠的那几秒本就留在缓冲里
                base += step / float(LIVE_BPS)
                first = False
                # 追上「播放头 + ahead」：挂起等播放头，会话不退出
                _cap = max(pusher.pos, ss_pos)
                if pusher.live and base >= _cap + ahead:
                    log("挂起：已领先 %.0fs（上限 %.0fs），等播放头"
                        % (base - _cap, ahead))
                    idle_since = time.time()
                    while True:
                        time.sleep(2)
                        if pusher.cancelled:
                            break
                        r = hb(base, idle=True)
                        if r is None:
                            if time.time() - idle_since > 60:
                                log("中枢 60 秒没回，收尾")
                                break
                            continue
                        idle_since = time.time()
                        if r.get("ahead"):
                            ahead = float(r["ahead"])
                        if r.get("goto") not in (None, "", 0):
                            next_ss = float(r["goto"])
                            log("中枢要求换位置到 %.0fs" % next_ss)
                            break
                        # 挂太久缓冲会一直涨（-readrate 4 还在抽）：超过 5 分钟
                        # 的音频就把流断掉，恢复时从 base 重开，几毫秒的事
                        if len(buf.b) / float(LIVE_BPS) > 300:
                            log("挂起期间缓冲超过 300 秒，先断流，恢复时从 %.0fs 重开" % base)
                            kill_ff()
                            drop_stream = True
                            break
                        _low = float(r.get("low") or 60)
                        _cap2 = max(pusher.pos, ss_pos)
                        if base < _cap2 + min(ahead, _low):
                            log("播放头前进到 %.0fs，接着转" % _cap2)
                            break
                    if pusher.cancelled or next_ss is not None or drop_stream:
                        break
            kill_ff()
            ff = None
            if next_ss is not None:
                ss_pos = max(0.0, next_ss)
                continue
            if drop_stream:
                ss_pos = base
                continue
            break
        pusher.flush()
        # 一条字幕都没出时把 ffmpeg 的报错带回去：不然中枢只知道「没听到人声」
        err_tail = ""
        if pusher.pushed == 0:
            try:
                with open(errf, "rb") as f:
                    raw = f.read()[-2000:].decode("utf-8", "replace")
                err_tail = " ".join([l for l in raw.splitlines() if l.strip()][-3:])[:300]
            except Exception:
                err_tail = ""
        try:
            api(hub, "/finish", {"id": jid, "lang": pusher.lang,
                                 "dur": max(base, real_total()),
                                 "err": err_tail}, timeout=25)
        except Exception:
            pass
        log("实时任务收尾: %d 段，用时 %.0fs" % (pusher.pushed, time.time() - t0))
    except Exception as e:
        m = str(e)[:180]
        log("实时任务出错:", m)
        try:
            api(hub, "/fail", {"id": jid, "msg": m}, timeout=15)
        except Exception:
            pass
    finally:
        kill_ff()
        try:
            os.unlink(wav)
        except OSError:
            pass


def transcribe_fw(wav, model, pusher, offset, limit, lang_hint=None, beam=5, retry=True,
                  hot=None):
    import wave

    import numpy as np
    from faster_whisper import WhisperModel
    name = {"turbo": "deepdml/faster-whisper-large-v3-turbo-ct2",
            "small": "Systran/faster-whisper-small"}.get(model, "deepdml/faster-whisper-large-v3-turbo-ct2")
    kw = dict(device="cpu", compute_type="int8",
              cpu_threads=int(os.environ.get("ASR_THREADS") or min(12, os.cpu_count() or 8)),
              download_root=os.path.join(HOME, "apps/fw/models"))
    if name not in _MODELS:
        try:
            # 先只认本地缓存：否则每次都要问一次 HuggingFace，被墙时能卡到天荒地老
            _MODELS[name] = WhisperModel(name, local_files_only=True, **kw)
        except Exception:
            log("本地没有这个模型，开始下载:", name)
            try:
                _MODELS[name] = WhisperModel(name, **kw)
            except Exception as e:
                # 下载失败（HuggingFace 的 xet 存储常见 401/超时）：退回本地已有的模型，别让整个活报错
                m = str(e)
                if "xethub" in m or "reconstruction" in m or "401" in m:
                    m = "模型下载被 HuggingFace 拒绝（xet 401）"
                log("模型 %s 不可用：%s；改用本地已有模型" % (model, m[:120]))
                alt = None
                for k, v in (("turbo", "deepdml/faster-whisper-large-v3-turbo-ct2"),
                             ("small", "Systran/faster-whisper-small")):
                    if v == name:
                        continue
                    try:
                        _MODELS[v] = _MODELS.get(v) or WhisperModel(v, local_files_only=True, **kw)
                        alt = v
                        break
                    except Exception:
                        continue
                if not alt:
                    raise RuntimeError("模型不可用：" + m + "（本地也没有其它模型，可在设置里换回「高质量」）")
                name = alt
                log("已改用 %s 继续转写" % alt)
    m = _MODELS[name]
    # 自己读 ffmpeg 出来的 wav 喂进去：faster-whisper 内置的 PyAV 解码在 av>=16 上会报
    # TypeError: open() got an unexpected keyword argument 'metadata_errors'
    with wave.open(wav, "rb") as w:
        pcm = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0
    def run(vad):
        base_kw = dict(language=lang_hint, beam_size=beam, vad_filter=vad,
                       condition_on_previous_text=False)
        if not hot:
            it, inf = m.transcribe(pcm, **base_kw)
        else:
            # faster-whisper 1.x 有专门的 hotwords（只做词表偏置，不比 initial_prompt
            # 那样把上一句的语气带进来）；老版本没有就退化到 initial_prompt。
            try:
                it, inf = m.transcribe(pcm, hotwords=hot, **base_kw)
            except TypeError:
                try:
                    it, inf = m.transcribe(pcm, initial_prompt=hot, **base_kw)
                except TypeError:
                    it, inf = m.transcribe(pcm, **base_kw)
        return [(x.start, x.end, x.text, x.avg_logprob, x.no_speech_prob) for x in it], inf

    rows, info = run(True)
    if not pusher.lang:
        # 别第一窗就钉死：片头音乐、冷开场那几秒经常认成别的语言，
        # 一旦钉住，整片都按错的语言转（日语片吐出英文字幕就是这么来的）。
        # 置信度够高才钉，否则下一窗继续认。
        _p = float(getattr(info, "language_probability", 1.0) or 1.0)
        if _p >= 0.85:
            pusher.lang = info.language or ""
            log("识别到语言:", pusher.lang, "(%.2f)" % _p)
    if retry and not rows and len(pcm) > 16000 * 6:
        # VAD 把整段判成非人声（片头音乐、冷开场小声对话都可能），放宽再来一次，
        # 只留置信度够高的句子，避免把配乐听成台词
        log("这段 VAD 没听到人声，放宽再试一次（offset %.0fs）" % offset)
        rows, _ = run(False)
        rows = [r for r in rows if r[4] < 0.6 and r[3] > -1.0 and r[2].strip()]
        log("放宽后得到 %d 段" % len(rows))
    end = 0.0
    for st, en, tx, _lp, _ns in rows:
        if pusher.cancelled or pusher.preempted:
            break
        e = min(en, limit)
        if e - st < 0.15:
            continue
        pusher.add(st + offset, e + offset, tx)
        end = max(end, e)
    return end


def transcribe_cpp(wav, model, pusher, offset, limit, lang_hint=None, hot=None):
    cli = os.path.join(WC_DIR, "build/bin/whisper-cli")
    mf = os.path.join(WC_DIR, "models", MODELS.get(model, MODELS["turbo"]))
    args = [cli, "-m", mf, "-f", wav, "-l", (safe_lang(lang_hint) or "auto"),
            "-t", str(min(16, os.cpu_count() or 8))]
    if hot:
        args += ["--prompt", hot]
    p = subprocess.Popen(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, bufsize=1)
    end = 0.0
    for line in p.stdout:
        m = LANG_RE.search(line)
        if m and not pusher.lang:
            pusher.lang = m.group(1)
        m = SEG_RE.search(line)
        if m:
            s = int(m.group(1)) * 3600 + int(m.group(2)) * 60 + int(m.group(3)) + int(m.group(4)) / 1000.0
            e = int(m.group(5)) * 3600 + int(m.group(6)) * 60 + int(m.group(7)) + int(m.group(8)) / 1000.0
            e = min(e, limit)
            if e - s < 0.15:
                continue
            pusher.add(s + offset, e + offset, m.group(9))
            end = max(end, e)
    p.wait()
    return end


def do_job(hub, job, engine, slot_idx=None):
    # 整片转写和实时听同时跑时，整片会把 CPU 抢走（实测实时窗从 3.5s 拖到 8.7s，
    # 画面就落后了）。整片不着急，把这条线程降优先级，让实时窗先拿到 CPU。
    try:
        os.nice(10)
    except Exception:
        pass
    jid = job["id"]
    log("接到活:", jid, (job.get("name") or job["url"][-40:]), "模型", job.get("model"))
    t0 = time.time()
    model = job.get("model") or "turbo"
    pusher = Pusher(hub, jid)
    import tempfile
    fd, wav = tempfile.mkstemp(suffix=".wav", dir="/tmp", prefix="asr-")
    os.close(fd)
    try:
        vsrc = localize(job["url"])    # 指向本机的地址改走 127.0.0.1（见 localize）
        src = vsrc                     # 默认直接读视频
        dur, aidx, alang = 0.0, None, job.get("lang_hint") or ""
        resume = float(job.get("resume") or 0)
        if job.get("audio_pending"):
            # NAS 就在文件旁边，让它本地抽一份 16k flac（46 分钟的 4K 只需几十 MB 过网）
            pusher.msg("NAS 正在准备音频…")
            ready = False
            for _ in range(8):      # 只等 24 秒：等不到就走流式，别让用户干看
                try:
                    if api(hub, "/job/" + jid, timeout=15).get("audio_ready"):
                        ready = True
                        break
                except Exception:
                    pass
                time.sleep(3)
            if ready:
                try:
                    pusher.msg("正在下载音频…")
                    flac = wav + ".flac"
                    with urllib.request.urlopen(hub.rstrip("/") + "/audio/" + jid, timeout=900) as r, \
                            open(flac, "wb") as fh:
                        while True:
                            b = r.read(1 << 20)
                            if not b:
                                break
                            fh.write(b)
                    log("音频下载完成 %.1fMB" % (os.path.getsize(flac) / 1048576.0))
                    out = subprocess.run([FFPROBE, "-v", "error", "-show_entries", "format=duration",
                                          "-of", "default=nk=1:nw=1", flac],
                                         capture_output=True, text=True, timeout=60).stdout
                    dur = float((out or "0").strip() or 0)
                    src = flac
                except Exception as e:
                    log("拿 NAS 音频失败，退回直接读视频:", str(e)[:80])
            else:
                log("NAS 还没准备好音频（可能不是本机文件），直接读视频")
        if src == vsrc:
            dur, aidx, alang2 = probe(src)
            if job.get("at") is not None:      # 跟随播放器选的音轨（ffmpeg 流序号）
                aidx = job["at"]
                log("按播放器选的音轨抽音：index %d" % aidx)
            alang = alang or alang2
        log("时长 %.1f 秒（%.1f 分钟），从 %.0fs 开始" % (dur, dur / 60.0, resume))
        pusher.msg("正在转写…" if src != vsrc else "正在抽音频…")
        start, first, guard = resume, True, 0
        while True:
            if dur and start >= dur - 0.5:
                break
            n = CHUNK_FIRST if first else CHUNK
            t1 = time.time()
            got = extract(src, aidx, start, n, wav)
            if got < 0.2:
                log("这一块没声音（%.0fs 起），收工" % start)
                break
            t2 = time.time()
            pusher.msg("转写中… 已到 %d 分 %02d 秒" % (int(start) // 60, int(start) % 60))
            if engine == "fw":
                # 语言不再听容器标签的：日语片常有多条音轨（英配），标签一错就整片
                # 按英语转，出来的是「英文字幕」。实时这条路一律让模型自己认，
                # 认出来第一条就钉住（pusher.lang），后面的窗跟着走。
                transcribe_fw(wav, model, pusher, start, got, pusher.lang or None)
            else:
                transcribe_cpp(wav, model, pusher, start, got, pusher.lang or None)
            pusher.flush(start + got)
            log("块 %d-%ds：抽 %.1fs + 转 %.1fs" % (start, start + got, t2 - t1, time.time() - t2))
            # 并发上限被调小了：超出上限的槽要让位。不检查的话，用户把 2 改成 1，
            # 两条还是各转到片尾，「上限」形同虚设。进度留着，轮到它接着转。
            if slot_idx is not None and slot_idx >= WANT[0]:
                log("并发上限收到 %d，第 %d 槽让位 → 回到排队" % (WANT[0], slot_idx + 1))
                try:
                    api(hub, "/requeue", {"id": jid}, timeout=15)
                except Exception as e:
                    log("回排队失败:", str(e)[:60])
                return
            if pusher.cancelled:
                log("让位（实时听来了/用户停了），已完成 %.0f 秒，进度保留" % (start + got))
                return
            if pusher.preempted:
                log("让路给用户正在看的片子，已完成 %.0f 秒，回头接着转" % (start + got))
                return
            start += got
            first = False
            guard += 1
            if guard > 600:
                break
        pusher.flush(start)
        api(hub, "/finish", {"id": jid, "lang": pusher.lang, "dur": start}, timeout=25)
        log("全部完成: %d 段, 到 %.1fs, 用时 %.1fs (%.2fx 实时)" %
            (pusher.pushed, start, time.time() - t0, start / max(1e-6, time.time() - t0)))
    except Exception as e:
        m = str(e)
        if "Connection refused" in m or "Failed to connect" in m:
            m = "视频源连不上（那个共享可能没开）"
        log("这个活失败了:", m[:200])
        try:
            api(hub, "/fail", {"id": jid, "msg": m[:180]}, timeout=15)
        except Exception:
            pass
    finally:
        for f in (wav, wav + ".flac"):
            try:
                os.unlink(f)
            except OSError:
                pass


def _my_ips():
    """本机的所有地址（判断一个链接是不是指向自己）"""
    ips = set()
    try:
        out = subprocess.run(["hostname", "-I"], capture_output=True, text=True, timeout=3).stdout
        ips |= set(out.split())
    except Exception:
        pass
    try:
        s4 = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s4.connect(("192.168.1.1", 80))
        ips.add(s4.getsockname()[0])
        s4.close()
    except Exception:
        pass
    return ips


MY_IPS = _my_ips()


def _tcp_ok(host, port, t=0.6):
    try:
        c = socket.create_connection((host, port), t)
        c.close()
        return True
    except Exception:
        return False


def localize(url):
    """指向本机的共享，改走 127.0.0.1。

    为什么：转写工跑在 WSL 里，Windows 防火墙会把「WSL → 本机 LAN IP」这种访问挡掉
    （192.168.1.21:5007 从 WSL 连不上，从 NAS 却能连），但回环地址一直是通的。
    不改的话，电脑本机的视频听译一定报「视频源连不上」。"""
    try:
        u = urllib.parse.urlparse(url or "")
    except Exception:
        return url
    host = (u.hostname or "").lower()
    if not host or host in ("127.0.0.1", "localhost", "::1"):
        return url
    if host not in MY_IPS:
        return url
    port = u.port or (443 if u.scheme == "https" else 80)
    if not _tcp_ok("127.0.0.1", port):
        return url
    netloc = "127.0.0.1:%d" % port
    new = urllib.parse.urlunparse((u.scheme, netloc, u.path, u.params, u.query, u.fragment))
    try:
        log("本机地址改走回环:", url[:60], "→", new[:60])
    except Exception:
        pass
    return new


# 并发槽：中枢的 max_active 说几个，就同时开几个任务；模型是共享的，不额外占内存
MAX_SLOTS = 3
WANT = [1]


def supervisor(hub):
    """每 8 秒问一次中枢：现在允许同时跑几个"""
    while True:
        try:
            h = api(hub, "/health", timeout=10)
            n = int(h.get("max_active") or 1)
            if n != WANT[0]:
                log("并发上限变成 %d" % max(1, min(MAX_SLOTS, n)))
            WANT[0] = max(1, min(MAX_SLOTS, n))
        except Exception:
            pass
        time.sleep(8)


def slot(i, hub, engine, kind=None):
    """kind=None 的老行为保留；"queue" 只领整片，"live" 只领实时听。

    实时听有自己的槽（见 main）：整片转写跑几个小时也不会把实时听堵住，
    反过来实时听占着的也只是它自己那一个槽。
    """
    while True:
        if kind != "live" and i >= WANT[0]:
            time.sleep(1.0)
            continue
        ep = "/work?wait=20" + ("&kind=" + kind if kind else "")
        try:
            job = api(hub, ep, timeout=35)
        except Exception as e:
            log("槽 %d 连不上中枢（%s），5 秒后重试" % (i + 1, str(e)[:60]))
            time.sleep(5)
            continue
        if not job:
            continue
        _who = "实时槽" if kind == "live" else "槽 %d" % (i + 1)
        log("%s 接到任务 %s" % (_who, str(job.get("id", ""))[:8]))
        if job.get("live"):
            do_live(hub, job, engine)
        else:
            do_job(hub, job, engine, slot_idx=(i if kind == "queue" else None))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--hub", default=os.environ.get("HUB", "http://192.168.1.10:5092"))
    ap.add_argument("--engine", default=os.environ.get("ASR_ENGINE", "fw"), choices=["cpp", "fw"])
    ap.add_argument("--slots", type=int, default=int(os.environ.get("ASR_SLOTS", "3")), help="最多几个并发槽")
    ap.add_argument("--once", action="store_true", help="只跑一个任务就退出（调试用）")
    a = ap.parse_args()
    global MAX_SLOTS
    MAX_SLOTS = max(1, min(3, a.slots))
    log("转写工启动: 中枢 %s  引擎 %s  线程 %s  分块 %d/%d 秒  并发槽 %d" %
        (a.hub, a.engine, min(16, os.cpu_count() or 8), CHUNK_FIRST, CHUNK, MAX_SLOTS))
    if a.once:
        job = api(a.hub, "/work?wait=25", timeout=40)
        if job:
            if job.get("live"):
                do_live(a.hub, job, a.engine)
            else:
                do_job(a.hub, job, a.engine)
        return
    threading.Thread(target=supervisor, args=(a.hub,), daemon=True).start()

    def _warm():
        try:
            time.sleep(1.0)
            import wave, tempfile
            fd, f = tempfile.mkstemp(suffix=".wav", dir="/tmp", prefix="warm-")
            os.close(fd)
            with wave.open(f, "wb") as w:
                w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
                w.writeframes(b"\x00" * 32000)
            p = Pusher("http://127.0.0.1:9", "")
            transcribe_fw(f, "turbo", p, 0, 1.0, None)
            try: os.unlink(f)
            except OSError: pass
            log("模型预热完成，实时听译第一句不用再等加载")
        except Exception as e:
            log("预热失败（不影响使用）:", str(e)[:80])

    threading.Thread(target=_warm, daemon=True).start()
    ts = [threading.Thread(target=slot, args=(i, a.hub, a.engine, "queue"), daemon=True)
          for i in range(MAX_SLOTS)]
    # 实时听专用槽：永远在线，不跟整片抢；整片排满时它照样能立刻开转
    ts.append(threading.Thread(target=slot, args=(-1, a.hub, a.engine, "live"), daemon=True))
    for t in ts:
        t.start()
    while True:
        time.sleep(3600)


if __name__ == "__main__":
    main()

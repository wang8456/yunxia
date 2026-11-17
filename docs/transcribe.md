# 听译（转写 + 双语字幕）

云匣可以在服务端自己把视频**转成字幕**（faster-whisper，本机跑，不上传任何片子），
再用任何 OpenAI 兼容服务把字幕**翻成中文**，两端播放器会自动挂上，还能导出 `.srt`。

默认关闭。开启需要三步：装依赖 → 下模型 → 改配置。

---

## 一、它需要什么

| 项目 | 要求 | 说明 |
|---|---|---|
| Python 包 | `fastapi` 之外多装 `requirements-subs.txt` | 约 250–350MB（faster-whisper + ctranslate2 + av + onnxruntime） |
| 模型 | 首次自动下载到 `data/models` | base 145MB / small 480MB / medium 1.5GB |
| CPU | 4 核可跑 tiny/base | ARM 也行（ctranslate2 有 aarch64 wheel） |
| 内存 | 见下表 | **峰值内存是硬门槛** |
| 磁盘 | 模型体积 + 每部片 1–3MB 字幕 JSON | |
| GPU（可选） | CUDA 12 + cuDNN 9 | `device: "cuda"` + `compute_type: "float16"` |
| 系统 ffmpeg | **不需要** | 音频解码用 PyAV（自带 ffmpeg 库） |
| 外部服务 | 不需要 | 不再需要另外一台机器上的转写 worker |

模型与资源对照（`× 实时` 指比片长快多少倍，4 核 ARM 实测区间）：

| 模型 | 体积 | 峰值内存 | 45 分钟一集大约 |
|---|---|---|---|
| tiny | 75MB | 150–250MB | 6–12 分钟 |
| **base（默认）** | 145MB | 300–450MB | 10–20 分钟 |
| small | 480MB | 0.7–1GB | 30–45 分钟 |
| medium | 1.5GB | 2–3GB | 需要 x86 多核 |
| large-v3 | 3GB | 4GB+ | 建议 GPU |

> 内存不够时**会先看到「转写失败」而不是服务挂掉**：转写跑在独立子进程里，崩了只影响那一条任务。

---

## 二、装依赖

```bash
cd server
.venv/bin/pip install -r requirements-subs.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
```

把模型提前下好（可选，但推荐：让第一次转写不必等下载）：

```bash
# 国内拉 HuggingFace 慢/不通就设镜像
export HF_ENDPOINT=https://hf-mirror.com
.venv/bin/python -c "from faster_whisper import WhisperModel; WhisperModel('base', download_root='./data/models')"
```

> **版本坑**：`av` 16 起删掉了 faster-whisper 依赖的 `metadata_errors` 参数，装到新版会报
> `TypeError: open() got an unexpected keyword argument 'metadata_errors'`。
> `requirements-subs.txt` 已经把它锁在 `av>=12,<16`，别自己升。

---

## 三、改配置

```jsonc
"subs": {
  "enabled": true,
  "model": "base",              // tiny / base / small / medium / large-v3，或本地模型目录
  "device": "auto",             // auto / cpu / cuda
  "compute_type": "int8",       // CPU 用 int8；GPU 用 float16
  "language": "auto",           // auto 会自动识别；也可以写 ja / en / zh
  "beam_size": 1,               // 1 最快；5 更准但慢一倍
  "vad": true,                  // 跳过静音段，长片能快不少
  "max_active": 1,              // 同时转写几部
  "model_dir": "./data/models",
  "translate": {
    "base": "https://api.deepseek.com/v1",   // 留空则复用 chat 段
    "api_key": "",                            // 留空则复用 chat 段的 Key
    "model": "deepseek-chat",
    "to": "zh"
  }
}
```

- **翻译不是必需的**：`translate` 全留空且 `chat` 也没配的话，就只听不译（单语字幕）。
- 语言是中文的片子会自动跳过翻译（翻了也只有原文）。
- 改完重启服务端。

三档预设：

```jsonc
// NAS / 小主机（4 核、2G 内存）
{ "model": "base",  "compute_type": "int8", "beam_size": 1, "max_active": 1, "vad": true }

// 普通 PC（8 核 16G）
{ "model": "small", "compute_type": "int8", "beam_size": 2, "max_active": 2 }

// 有显卡
{ "model": "large-v3", "device": "cuda", "compute_type": "float16", "max_active": 1 }
```

---

## 四、怎么用

1. 网页/App 打开一个视频 → 底栏「字幕」→「生成听译」
2. 任务进入队列，进度实时上涨（子进程每秒落一次进度）
3. 转完自动接翻译（配了翻译时），播放器里出现双语字幕
4. 文件页的 ⋯ 菜单里也能「生成字幕」；「设置 → 听·译 → 听译队列」能看全部任务、取消、删除、重新转写、翻译、导出 SRT

字幕样式：双语时**译文在上（大字）、原文在下（小一号）**，两端一致；字号三档，开关是「关 / 原文 / 双语」。

---

## 五、接口（自己写客户端时用）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/api/v1/subs` | 任务列表 + 能力（`enabled` / `model` / `max_active` / `deps` / `translate.ready`） |
| POST | `/api/v1/subs/add` | `{source,path,name?,lang?}`，同一条视频重复提交是复用 |
| POST | `/api/v1/subs/cancel` | `{id}` |
| POST | `/api/v1/subs/delete` | `{id}`，连段落文件一起删 |
| POST | `/api/v1/subs/translate` | `{id,to?}`，整片翻译（后台跑） |
| POST | `/api/v1/subs/config` | `{max_active:1..4}` |
| GET | `/api/v1/subs/for?source=&path=` | 播放器用：`{found,id,lang,dur,segments:[[起,止,原文,译文]]}` |
| GET | `/api/v1/subs/{id}?since=N` | 详情；`since>0` 时 `segments_list` 只回新增段（边转边显示） |
| GET | `/api/v1/subs/{id}/srt?trans=1` | 导出 SRT（`trans=1` 双语，`trans=0` 只原文） |

状态机：`queued → asr → translating → done`，异常 `error`，用户取消 `cancelled`。
重启服务时正在跑的任务会被标成 `cancelled`（子进程已经不在了，不确定就别假装还在跑）。

---

## 六、验收与排错

造一条已知内容的测试片（11 秒 JFK 演讲，含真实人声）：

```bash
curl -sL -o /tmp/jfk.flac https://github.com/openai/whisper/raw/main/tests/jfk.flac
ffmpeg -y -f lavfi -i color=c=navy:s=640x360 -i /tmp/jfk.flac -t 11 \
  -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest /tmp/jfk.mp4
# 传到某个来源里，然后
T=<设备令牌>; IP=<服务器>
curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d '{"source":"local","path":"/jfk.mp4"}' http://$IP:8686/api/v1/subs/add
curl -s -H "Authorization: Bearer $T" http://$IP:8686/api/v1/subs     # 轮询 state/pct
```

判据：`state=done`、`segments≥1`、`segments_list` 里有正确英文原文（这条样本应出现 “ask not what your country can do for you”），
配了翻译时第 4 列有中文。

常见问题：

| 现象 | 原因 / 办法 |
|---|---|
| 503「没装 faster-whisper」 | `pip install -r requirements-subs.txt` 后重启 |
| 503「听译没开」 | `subs.enabled` 还是 false |
| `TypeError … metadata_errors` | av 太新，`pip install "av>=12,<16"` |
| 卡在「加载模型…」很久 | 正在下模型；国内设 `HF_ENDPOINT=https://hf-mirror.com`，或按第二节提前下载 |
| `state=error` + `转写失败` | 看 `data/subs/<id>.json` 里的 `error`；常见是内存不够、片子没有音轨 |
| 转完 0 段 | 纯音乐/无人声的片子会这样，属正常（`msg` 会写「听译完成 · 0 句」） |
| 译文整段空 | 翻译服务拒翻或返回行数不对——云匣会**留空而不是拿原文顶替**，这是故意的 |
| 进度不动但状态是 asr | 长片开头可能有长时间静音（VAD 在跳），等一会儿；真卡住就取消重来 |

## 七、数据在哪

```
data/subs/<id>.json        任务与段落（[起, 止, 原文, 译文]）
data/subs/<id>.part.json   转写中的临时进度（收尾即删）
data/models/               模型缓存（可以随时删，下次会重下）
```

`data/subs` 里没有视频文件，只有字幕文本，很小；备份时一起拷走即可。

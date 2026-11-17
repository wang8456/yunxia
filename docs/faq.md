# 常见问题与自查

## 服务端

**`/api/v1/healthz` 通，但 `/` 是 404**
没编译网页端。`cd web && npm run build`，产物出现在 `web/dist` 后重启服务端；或者用 nginx 托管 dist。

**所有来源都列表失败、报 500/超时**
先单来源排除：直接把那个来源的地址 curl 一遍（dufs 用 `?json`，WebDAV 用 `PROPFIND`，见各自文档）。
能通再回来看云匣配置里的 `user/password/root`。**curl 200 但云匣 401/403，一律先怀疑口令里带了特殊字符。**

**改了 `config.json` 没生效**
配置文件是启动时读一次，改完必须重启进程。Docker：`docker compose restart`；systemd：`systemctl restart yunxia`。

**读接口不用口令就能看文件，正常吗**
正常，这是设计：手机装上就能浏览，写操作（上传/删除/改名/新建）才要令牌。
不想让别人看就设 `auth.password` —— 但注意：**只要服务能访问到，读是开放的**。要彻底私密，请从网络层限制（内网 / 隧道）。

**「口令都对，就是上传 401」**
上传是写操作，必须带令牌：客户端要先 `POST /api/v1/auth/login` 拿 token 再上传。
用 curl 手工验证时别忘了 `-H "Authorization: Bearer $T"`。

**上传大文件失败 / 中途断开**
- 反代层：`client_max_body_size 0`、`proxy_read_timeout` 调大。
- 客户端：网页端上传走原始字节体（`PUT` 到 `/api/v1/fs/upload`），不要套 FormData。
- 远端来源（dufs/WebDAV）上传会先落到 `data/tmp/`，确认那个目录有空间。

**播放器黑屏 / 一拖进度条就卡**
用直链单独验：`curl -r 0-524287 -o /dev/null -w '%{http_code}\n' "<直链>"` 必须回 **206**。
- 回 200 = 服务端没处理 Range（本机来源要经过 `/api/v1/fs/raw`，别绕开它直接拼文件路径）
- 回 206 但很慢 = 源头慢（网盘/隧道带宽），不是播放器的锅

**搜索搜不到远端来源的文件**
远端来源的索引有预算（每次最多 8000 项 / 60 秒），网盘目录特别大时会一轮轮补。
手动触发一次：`curl -X POST -H "Authorization: Bearer $T" "http://IP:8686/api/v1/search/reindex?blocking=true"`，
返回里 `entries` 是这轮收录了多少。

**中文文件名搜索命中不了**
3 个字以上走 FTS5 trigram，1-2 个字退回 LIKE 扫描（文件多时会慢一点，但能搜到）。索引里没有的文件不会命中，先 reindex。

## 对话

**刷新页面后「对话」入口不见了**
`chat.enabled` 或 `api_key` 是空的。`curl -s http://IP:8686/api/v1/meta/sources | grep chat` 确认 `"enabled":true`。

**一发就 503**
同上：`chat` 段没配全（`base`/`api_key`/`model` 三个都要有），改完要重启。

**回 502 `Previous response not found`**
服务端换过数据库或重启后旧上下文丢了。客户端会自动丢掉 id 重开一轮，属于正常自愈；出现一次不影响使用。

**回答只有半截**
上游断流或者超时（`chat.timeout`）。把 `timeout` 调大；本地小模型（Ollama 7B）本来就慢，建议 `timeout: 300`。

**上不了网但想用本地模型**
`"base": "http://127.0.0.1:11434/v1"`，服务端和 Ollama 同机；Docker 部署时用 `host.docker.internal` 或 host 网络。

## 听译

| 现象 | 原因 / 办法 |
|---|---|
| 503「没装 faster-whisper」 | `pip install -r server/requirements-subs.txt` 后重启 |
| 503「听译没开」 | `subs.enabled` 还是 false |
| `TypeError … metadata_errors` | `av` 装太新，`pip install "av>=12,<16"` |
| 卡在「加载模型…」很久 | 正在下模型；设 `HF_ENDPOINT=https://hf-mirror.com` 或提前下载 |
| 转完 0 段 | 无人声的片子会这样，属正常 |
| 译文整段空 | 翻译服务拒翻 / 行数不对时会**留空**（不拿原文冒充），换模型再试 |

细节与模型、内存对照见 [transcribe.md](transcribe.md)。

## 客户端

**App 里填了地址还是「连不上」**
1. 手机浏览器打开 `http://<IP>:8686/api/v1/healthz` 看有没有 JSON；
2. 没有就是网络/防火墙/端口问题（手机和服务器是不是同一网段？服务端监听的是 `0.0.0.0` 吗？）；
3. 有 JSON 但 App 连不上：地址里别漏 `http://`，也别带结尾斜杠。

**网页端打开是白屏**
十有八九是反代把 `/assets/*.js` 吃掉了，或者 `base` 配错。F12 看 Network 里 JS 是否 404。

**图片/视频不显示，只显示图标**
缩略图接口要 Pillow（`pip install pillow`）。缺 Pillow 时接口回 503，列表本身仍然正常。

## 数据在哪、怎么备份

全在 `data/` 一个目录里：

| 文件 | 是什么 |
|---|---|
| `yunxia.db` | 文件索引、播放进度、对话记录、令牌之外的元数据 |
| `token.secret` | 令牌签名密钥（丢了 = 所有设备重新登录，别的没影响） |
| `thumbs/` | 缩略图缓存（可以随便删） |
| `media/` | 对话里的附件 |
| `tmp/` | 上传中转（可以随便删） |

备份就两步：`cp -a data /备份路径/` + `cp config.json /备份路径/`。
`data/` 里没有你的媒体文件（媒体在各自的来源里），所以它很小。

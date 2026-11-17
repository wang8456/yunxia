# 部署服务端

服务端是一个 FastAPI 应用（`server/`），一个进程就够：控制面 + 文件字节代理。
它自己不存网盘凭证之外的东西，状态全在 `data/` 目录里（SQLite + 缩略图 + 对话附件）。

## 一、环境要求

- Python **3.10+**（3.11/3.12 都行），或者直接用 Docker
- 一个能长期开机的机器：NAS、软路由、树莓派、旧笔记本、小主机都行
- 需要读的磁盘目录（如果是本机储存来源）

## 二、方式 A：Docker（推荐）

```bash
cd deploy
cp ../server/config.example.json config.json
nano config.json                 # 改口令、加来源（见下面的「配置」一节）
docker compose up -d
docker compose logs -f           # 看日志，出现 Application startup complete 就成了
```

`deploy/docker-compose.yml` 把 `data/` 和 `config.json` 映射到了宿主机，容器升级不丢数据。
要接「服务器本机磁盘」来源时，把宿主机目录再挂一个进容器，并把 `config.json` 里的 `root` 写成**容器内路径**：

```yaml
    volumes:
      - ./config.json:/app/config.json:ro
      - ./data:/app/data
      - /volume1/media:/srv/media:ro      # 只读挂载一份媒体目录
```

```jsonc
{ "id": "local", "name": "NAS 影音", "kind": "local", "root": "/srv/media" }
```

## 三、方式 B：直接跑 Python

```bash
cd server
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt -i https://pypi.tuna.tsinghua.edu.cn/simple
cp config.example.json config.json
nano config.json
.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8686
```

放到后台常驻（systemd，Linux）：

```bash
sudo cp deploy/yunxia.service /etc/systemd/system/yunxia.service
sudo nano /etc/systemd/system/yunxia.service     # 改 WorkingDirectory / ExecStart / User
sudo systemctl daemon-reload
sudo systemctl enable --now yunxia
systemctl status yunxia
journalctl -u yunxia -f
```

若用 OpenWrt / busybox 没有 systemd，就用 procd 脚本或 `nohup ... &` + `crontab` 守护。

## 四、配置（`config.json`）

| 字段 | 说明 |
|---|---|
| `server.host` / `server.port` | 监听地址与端口，默认 `0.0.0.0:8686` |
| `server.public_base` | 对外地址（如 `https://匣.example.com`）。只在需要给别的进程签绝对直链时用，留空即可 |
| `auth.password` | 写操作口令。**留空 = 谁都能读写**，只建议纯内网自用 |
| `paths.data` | 数据库 / 令牌密钥 / 缩略图 / 对话附件放哪，默认 `./data` |
| `token_days` | 令牌有效期（天） |
| `sources[]` | 来源列表，见下 |
| `chat` | 对话配置，默认关闭，见 [chat.md](chat.md) |

口令想存哈希而不是明文：

```bash
cd server && .venv/bin/python -m app.cli hash '你的口令'
# 输出 pbkdf2$<salt>$<hash>，整行填进 "auth": {"password": "..."}
```

### 来源（`sources[]`）字段

| 字段 | 适用 | 说明 |
|---|---|---|
| `id` | 全部 | 唯一标识，前端和进度记录都用它，定了别改 |
| `name` | 全部 | 显示名，如「电脑 · 书房」 |
| `subtitle` | 全部 | 首页来源卡的副标题，一句话说明 |
| `kind` | 全部 | `local` / `dufs` / `webdav` |
| `root` | 全部 | `local` 是磁盘绝对路径；远端是**源内起始路径**（通常是 `/`） |
| `base` | 远端 | `dufs`：`http://192.168.1.10:5000`；`webdav`：`http://192.168.1.10:19798/dav` |
| `user` / `password` | 远端 | 那台机器的账号密码 |
| `writable` | 全部 | `false` 时前端隐藏上传/删除（默认 `true`） |
| `enabled` | 全部 | `false` 时不显示这个来源 |

具体怎么加，看：

- 本机磁盘 → [storage-local.md](storage-local.md)
- 电脑 dufs 共享 → [storage-dufs.md](storage-dufs.md)
- CloudDrive2 / Alist 等 WebDAV → [storage-webdav.md](storage-webdav.md)

## 五、验收

```bash
IP=<服务器 IP>
curl -s http://$IP:8686/api/v1/healthz        # {"ok":true,...}
curl -s http://$IP:8686/api/v1/meta/sources   # 看到你的来源；chat.enabled 是否符合预期

T=$(curl -s -X POST http://$IP:8686/api/v1/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"password":"你的口令","device":"cli"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

curl -s -H "Authorization: Bearer $T" "http://$IP:8686/api/v1/fs/list?source=local&path=/" | head -c 300
```

能列出目录就说明服务端和这个来源都通了。上传/播放怎么单独验，见 [faq.md](faq.md)。

## 六、代理与反代

- 服务端默认**不走**环境变量里的 `http_proxy`（内网访问被代理带偏是常见坑），所以它连 dufs / WebDAV 是直连。
- 前面要套 Nginx/Caddy 时，务必把 `Range` 头透传（播放器靠它做断点续播），并关掉对 SSE 的缓冲：

```nginx
location / {
    proxy_pass http://127.0.0.1:8686;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_buffering off;              # 对话是 SSE，不能缓冲
    client_max_body_size 0;           # 上传大文件别卡在 1MB
    proxy_read_timeout 3600s;
}
```

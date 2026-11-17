# server · 云匣服务端

FastAPI。一个进程做四件事：

1. **控制面**：认证、列目录、搜索、播放进度、缩略图
2. **字节流**：`/api/v1/fs/raw` 按 Range 出字节（本机读盘 / 远端流式代理）
3. **对话转发**：`/hermes/api/*` → 任意 OpenAI 兼容服务（默认关闭）
4. **静态托管**：`../web/dist` 存在时顺便把网页端发出去

```
app/
  config.py      配置加载（config.json）
  auth.py        口令 → JWT 令牌、直链签名
  db.py          SQLite：文件索引(FTS5) + 播放进度 + 对话
  models.py      对外数据模型（= API 契约）
  indexer.py     建索引（本地 os.walk / 远端递归 list）
  adapters/      来源适配：local_disk / dufs / webdav
  routers/       auth · fs · search · thumb · play · chat
  cli.py         生成口令哈希 / 调试令牌
tests/           冒烟测试（pytest）
```

## 跑起来

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
cp config.example.json config.json     # 改口令、加来源
.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8686
```

- 接口表：`http://127.0.0.1:8686/api/v1/docs`
- 自检：`curl 127.0.0.1:8686/api/v1/healthz`
- 配置说明见 [../docs/deploy-server.md](../docs/deploy-server.md)

## 测试

```bash
.venv/bin/pip install pytest
.venv/bin/python -m pytest tests/ -q
```

## 几个设计取舍

- **直链一律相对路径**（`/api/v1/fs/raw?...`）：同一个 origin 下，局域网、反代、外网域名都不用改代码。
- **读接口匿名、写接口要令牌**：单用户自用场景，装上就能浏览；上传/删除必须有口令。
- **列表用 stale-while-revalidate**：远端大目录第一次慢，之后先回旧数据后台刷新，切目录不再等 3 秒。
- **上传远端来源先落临时文件**：`request.stream()` 是异步生成器，直接交给同步适配器会崩；
  落盘再流式 PUT（带 Content-Length，dufs 不认 chunked）。
- **对话上下文存服务端**：客户端只发最新一条 + `previous_response_id`，换设备接着聊是同一条线。

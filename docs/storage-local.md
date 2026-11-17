# 储存来源一：服务器本机磁盘（local）

最简单的一种：文件就在跑云匣的这台机器上，服务端直接读写磁盘。
适合 NAS 的系统盘/数据盘、小主机的移动硬盘、树莓派的 USB 硬盘。

## 一、加一个来源

1. 准备目录（服务端进程要有读写权限）：

```bash
sudo mkdir -p /srv/files
sudo chown -R $(id -u):$(id -g) /srv/files
```

2. 编辑 `config.json`，在 `sources` 里加一条：

```jsonc
{
  "id": "local",                 // 定了就别改：进度、收藏、索引都挂在它上面
  "name": "本机储存",
  "subtitle": "服务器本机磁盘",
  "kind": "local",
  "root": "/srv/files",          // 磁盘绝对路径；Docker 部署时写「容器内路径」
  "enabled": true
}
```

3. 重启服务端：

```bash
# systemd
sudo systemctl restart yunxia
# Docker
cd deploy && docker compose restart
# 裸跑
.venv/bin/python -m uvicorn app.main:app --host 0.0.0.0 --port 8686
```

## 二、可以加多个

一个来源对应首页的一张卡，想分区就多写几条：

```jsonc
"sources": [
  { "id": "media",  "name": "影音",   "kind": "local", "root": "/srv/media",  "subtitle": "电影 · 剧集" },
  { "id": "photos", "name": "照片",   "kind": "local", "root": "/srv/photos", "subtitle": "家庭相册" },
  { "id": "ro",     "name": "只读归档", "kind": "local", "root": "/srv/arch", "writable": false }
]
```

`writable: false` 的来源在 App/网页里不会出现上传、新建、改名、删除入口（点不到就不会报错）。

## 三、权限与常见坑

- **权限**：服务端以哪个用户跑，那个用户就要能读这个目录。systemd 用 `User=`，Docker 用 `UID/GID` 环境变量或 `user:` 字段；目录权限不对的表现是列目录 403/500。
- **Docker 里看不到宿主机目录**：忘加 `-v /srv/media:/srv/media` 挂载；容器内 `root` 必须写容器内路径 `/srv/media`，不是宿主机的。
- **外接硬盘没挂载上**：`root` 指向的目录在磁盘拔掉后会变成空目录，云匣只会显示空列表。建议在 `/etc/fstab` 里写死挂载，并在挂载点里放一个占位文件，发现列表里没有那个文件就是没挂上。
- **不列隐藏文件**：以 `.` 开头的文件和目录不会出现在列表里（省得满屏 `.DS_Store`、`.git`）。索引与搜索同样跳过。
- **删除是直接删**（不是回收站）。要保底就给目录开快照，或者把来源设成 `writable: false`。
- **符号链接**：本机来源按真实路径访问，链到别处的文件能读；但索引扫描不会跟随目录符号链接。

## 四、验收

```bash
IP=<服务器 IP>
T=$(curl -s -X POST http://$IP:8686/api/v1/auth/login -H 'Content-Type: application/json' \
      -d '{"password":"你的口令","device":"cli"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# 列目录
curl -s -H "Authorization: Bearer $T" "http://$IP:8686/api/v1/fs/list?source=local&path=/" | head -c 300

# 上传一个探针文件（会真的写进 root 目录）
head -c 100000 /dev/urandom > /tmp/probe.bin
curl -s -X PUT -H "Authorization: Bearer $T" --data-binary @/tmp/probe.bin \
  "http://$IP:8686/api/v1/fs/upload?source=local&path=%2F&name=probe.bin"

# 拿直链，验 Range（播放器靠它拖进度）
U=$(curl -s -H "Authorization: Bearer $T" \
     "http://$IP:8686/api/v1/fs/link?source=local&path=/probe.bin" | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
curl -s -o /dev/null -w '%{http_code} %{size_download}\n' "http://$IP:8686$U"       # 期望 200 100000
curl -s -r 0-99 -o /dev/null -w '%{http_code} %{size_download}\n' "http://$IP:8686$U" # 期望 206 100

# 删掉探针
curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d '{"source":"local","paths":["/probe.bin"]}' http://$IP:8686/api/v1/fs/delete
```

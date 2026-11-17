# 储存来源三：WebDAV（CloudDrive2 / Alist / 群晖 等）

云匣的 `webdav` 来源是一个**标准 WebDAV 客户端**（PROPFIND / MKCOL / MOVE / DELETE / PUT / GET），
所以只要能提供 WebDAV 的东西都能接：

- **CloudDrive2**（把 115、阿里云盘、百度网盘等聚合成一个 WebDAV）—— 下面重点讲
- **Alist / OpenList**（同样的聚合思路，自带 WebDAV）
- 群晖 / 威联通 / Nextcloud / Nginx-dav-ext / rclone serve webdav

---

## 一、CloudDrive2

### 1. 确认 WebDAV 服务开着

CloudDrive2 的 Web 界面（默认 `http://<机器 IP>:19798`）→ **设置 → WebDAV**：

- 打开「WebDAV 服务」开关
- 「账号访问」打开（允许用 CloudDrive2 账号连 WebDAV）
- 需要的话设置「WebDAV 根目录」和「只读」
- 想省事也可以开「匿名访问」，那样云匣里就不填用户名口令

连接信息（官方给的就这三行）：

```
服务器地址：http://<机器 IP>:19798/dav
用户名：CloudDrive2 登录邮箱（也可以只填 @ 前面的部分）
密码：CloudDrive2 登录密码
```

> CloudDrive2 跑在 Docker 里时，`<机器 IP>` 要写**宿主机**的 IP，端口写映射到宿主机的那个（默认 19798）。

### 2. 先用 curl 验一遍（重要）

在跑云匣的机器上执行，别跳这一步，CloudDrive2 的坑基本都在这里暴露：

```bash
DAV=http://192.168.1.10:19798/dav
curl -s -u 'you@mail.com:你的密码' -X PROPFIND "$DAV/" \
  -H 'Depth: 1' -H 'Content-Type: application/xml' \
  --data '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>' \
  -o /tmp/dav.xml -w '%{http_code}\n'
head -c 400 /tmp/dav.xml
```

- 回 **207** 且 XML 里有 `<d:response>` = 通了，继续。
- 回 **401** = 账号口令不对（注意「用户名只填 @ 前面那段」有时更稳）。
- 回 **404** = 路径不对，检查 `/dav` 有没有写、端口是不是 19798。
- 一直转圈/超时 = 防火墙没放 19798，或者 CloudDrive2 的 WebDAV 开关没开。

### 3. 在云匣里添加

```jsonc
{
  "id": "cd2",
  "name": "网盘 · 115",
  "subtitle": "CloudDrive2 WebDAV",
  "kind": "webdav",
  "base": "http://192.168.1.10:19798/dav",
  "user": "you@mail.com",
  "password": "你的密码",
  "root": "/",                 // 想只看某个子目录就写 /115open/电影
  "writable": true,            // CloudDrive2 允许上传就给 true，设了只读就填 false
  "enabled": true
}
```

重启服务端 → 首页会多一张卡。

### 4. CloudDrive2 特有的注意事项

- **`/dav` 是路径的一部分**，`base` 必须带上（`http://IP:19798/dav`）。
- 云盘里的目录/文件名如果带 `#`、`?`、`%`，有些版本会拼错链接；遇到某个文件打不开，先用 curl 确认是 CloudDrive2 的问题还是云匣的问题。
- WebDAV 走的是 HTTP `GET`，**播放高码率片时速度取决于 CloudDrive2 那边的转发能力**，卡是常态，不是云匣的锅；CloudDrive2 自己网页里能播说明源没问题。
- CloudDrive2 的 FUSE 挂载（`/CloudNAS`）和 WebDAV 是两条路。云匣用 WebDAV，**不依赖 FUSE**，所以 FUSE 挂了也不影响云匣。

---

## 二、Alist / OpenList

1. Alist 后台 → **设置 → 用户 → 编辑 → 勾选 WebDAV 读取/管理**
2. 地址：`http://<IP>:5244/dav`，用户名口令就是 Alist 账号
3. 先用 curl 按上面同样的命令验 207
4. 云匣配置：

```jsonc
{ "id": "alist", "name": "Alist", "kind": "webdav",
  "base": "http://192.168.1.10:5244/dav", "user": "admin", "password": "口令", "root": "/" }
```

> Alist 里「本机存储」映射的就是挂载盘，所以 115/阿里/OneDrive 都能这样进云匣。

---

## 三、群晖 / Nextcloud / 其他

- **群晖 WebDAV Server 套件**：地址 `http://<NAS>:5005/<共享名>`，账号是群晖用户；需要在套件里开「启用 WebDAV」与「启用 WebDAV HTTPS」。
- **Nextcloud**：`https://<域名>/remote.php/dav/files/<用户名>/`，用「应用密码」而不是登录密码。
- **rclone**（把任意网盘变成 WebDAV）：`rclone serve webdav remote: --addr :8080 --user u --pass p`，然后 `base` 填 `http://IP:8080/`。
- **Nginx + dav_ext**：`base` 填 `http://IP/`（走根路径时）。

共同要求就三条：支持 `PROPFIND`（Depth 1）、支持 `MKCOL/MOVE/DELETE`（要写的话）、`GET` 支持 `Range`（要拖进度条的话）。

---

## 四、只读还是可写

- 网盘通常允许上传，就给 `"writable": true`；不确定先设 `false`，只读一定能用。
- 只读时前端会把上传/新建/删除入口全部隐藏，不会出现「点了才报错」。
- 云匣不会替你删网盘里的东西 —— 删除是明确的用户操作，且**不可恢复**，用之前想清楚。

---

## 五、验收

```bash
IP=<云匣服务器 IP>
T=$(curl -s -X POST http://$IP:8686/api/v1/auth/login -H 'Content-Type: application/json' \
      -d '{"password":"你的口令","device":"cli"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

curl -s -H "Authorization: Bearer $T" "http://$IP:8686/api/v1/fs/list?source=cd2&path=/" | head -c 400
```

`entries` 里有东西就说明 WebDAV 三个动作（PROPFIND 解析、路径换算、权限判断）都对了。
某一条视频点开黑屏时，用直链单独验一次 Range：

```bash
U=$(curl -s -H "Authorization: Bearer $T" "http://$IP:8686/api/v1/fs/link?source=cd2&path=/影片/x.mkv" \
     | python3 -c 'import sys,json;print(json.load(sys.stdin)["url"])')
curl -s -o /dev/null -w '%{http_code} %{size_download} %{time_starttransfer}s\n' "http://$IP:8686$U"
curl -s -r 0-524287 -o /dev/null -w '%{http_code} %{size_download} %{time_starttransfer}s\n' "http://$IP:8686$U"
```

200 / 206 都对，说明服务端链路没问题，黑屏就是客户端解码的事。

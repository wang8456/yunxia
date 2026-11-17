# 储存来源二：电脑的 dufs 共享文件夹

云匣本身不需要电脑上装什么客户端 —— 电脑上跑一个 [dufs](https://github.com/sigoden/dufs)（单文件、6MB 左右的 Rust 小工具），把某个文件夹以 HTTP 方式共享出来，云匣的 `dufs` 来源就去读它。
电脑关机/断网时这个来源显示为空或报错，其它来源不受影响。

下面 Windows / macOS / Linux 三份教程，任选一台电脑照着做。**全部照抄命令即可，只需要改路径和口令。**

---

## 一、Windows（最常见的场景）

### 1. 下载 dufs

打开 https://github.com/sigoden/dufs/releases ，找最新的
`dufs-vX.Y.Z-x86_64-pc-windows-msvc.zip`（Intel/AMD 电脑）或
`...-aarch64-pc-windows-msvc.zip`（骁龙/ARM 笔记本），解压得到 `dufs.exe`。

把它放到一个固定位置，例如 `C:\dufs\dufs.exe`。

> 国内打不开 GitHub 的话：`winget install sigoden.dufs` 也能装（Win10/11 自带 winget），
> 装完 `where dufs` 能看到路径。

### 2. 先手动跑一次，确认能共享

打开 PowerShell：

```powershell
# 把 D:\共享 换成你要共享的文件夹；-A 表示允许上传/删除
C:\dufs\dufs.exe D:\共享 -A -p 5000 -a "yunxia:换成你的口令@/:rw"
```

浏览器打开 `http://localhost:5000`，输入用户名 `yunxia` 和刚才的口令，能看到文件列表就成了。

几个要点：

- `-p 5000` 是端口，被占用就换 5001、8080 之类。
- `-a "用户名:口令@/:rw"`：账号 `rw` 权限作用于整个共享根。**口令别用中文和 `@`**。
- 只想给只读权限就把 `:rw` 去掉（写 `-a "yunxia:口令@/"`）。
- 只共享一个子目录也行：`-a "yunxia:口令@/视频:rw"`。

先 `Ctrl+C` 停掉，下面让它开机自启。

### 3. 开机自启（两个办法，选一个）

**办法 A：任务计划程序（推荐，简单）**

1. `Win+R` → 输入 `taskschd.msc` → 回车
2. 右侧「创建任务」（不要用「基本任务」）
3. 「常规」页：名称 `dufs`，勾选 **不管用户是否登录都运行**、勾选 **使用最高权限运行**
4. 「触发器」页：新建 → 「登录时」（或「启动时」）
5. 「操作」页：新建 → 程序或脚本填
   `C:\dufs\dufs.exe`
   添加参数填
   `D:\共享 -A -p 5000 -a "yunxia:换成你的口令@/:rw"`
   起始于填 `C:\dufs`
6. 「设置」页：勾选「如果任务失败，每隔 1 分钟重新启动一次」
7. 确定（会要你输 Windows 密码），然后在任务列表里右键 `dufs` → 运行

**办法 B：NSSM 注册成服务**

```powershell
# 先装 NSSM：winget install nssm
nssm install dufs "C:\dufs\dufs.exe"
nssm set dufs AppParameters 'D:\共享 -A -p 5000 -a "yunxia:口令@/:rw"'
nssm set dufs AppDirectory "C:\dufs"
nssm start dufs
```

### 4. 让云匣能连上（两种情况）

- **云匣和电脑在同一个局域网**：直接用电脑的局域网 IP。
  PowerShell 里 `ipconfig` 找「IPv4 地址」，例如 `192.168.1.20`，
  地址就是 `http://192.168.1.20:5000`。
- **第一次连不上**：大概率是 Windows 防火墙。用**管理员** PowerShell 放行端口：

```powershell
New-NetFirewallRule -DisplayName "dufs 5000" -Direction Inbound -Protocol TCP -LocalPort 5000 -Action Allow
```

### 5. 在云匣里添加这个来源

服务端 `config.json` 的 `sources` 里加一条（`base` 用电脑的 IP，别用 `localhost`）：

```jsonc
{
  "id": "pc",
  "name": "电脑 · 书房",
  "subtitle": "同一 WiFi 下的 dufs 共享",
  "kind": "dufs",
  "base": "http://192.168.1.20:5000",
  "user": "yunxia",
  "password": "换成你的口令",
  "root": "/",
  "enabled": true
}
```

重启服务端。回到云匣首页，点「电脑 · 书房」那张卡应该就能看到 `D:\共享` 里的东西，也能上传了。

> **DHCP 换 IP 导致失联？** 在路由器里给这台电脑绑定静态 IP（DHCP 固定分配），一劳永逸。
> 或者电脑上用 `dufs` 的固定端口 + 路由器里给它固定的 IP。

---

## 二、macOS

### 1. 安装

```bash
brew install dufs
# 或者下载 releases 里的 macOS 包，解压后 mv dufs /usr/local/bin/
```

### 2. 手动跑一次

```bash
dufs ~/共享 -A -p 5000 -a "yunxia:你的口令@/:rw"
```

浏览器 `http://localhost:5000` 验证，`Ctrl+C` 停掉。

### 3. 开机自启（launchd）

存成 `~/Library/LaunchAgents/com.yunxia.dufs.plist`：

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.yunxia.dufs</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/local/bin/dufs</string>
    <string>/Users/你的用户名/共享</string>
    <string>-A</string>
    <string>-p</string><string>5000</string>
    <string>-a</string><string>yunxia:你的口令@/:rw</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/tmp/dufs.log</string>
  <key>StandardErrorPath</key><string>/tmp/dufs.err</string>
</dict>
</plist>
```

```bash
launchctl load -w ~/Library/LaunchAgents/com.yunxia.dufs.plist
launchctl list | grep yunxia     # 有输出就是起来了
```

### 4. 连上

`ipconfig getifaddr en0` 拿本机局域网 IP，记下 `http://<IP>:5000`。
macOS 可能会弹「是否允许 dufs 接受传入连接」，点允许；没弹就「系统设置 → 网络 → 防火墙 → 选项」里放行。

配置写法和 Windows 那节第 5 步一样。

---

## 三、Linux（含群晖/威联通等能用 SSH 的机器）

### 1. 安装

```bash
# 方案一：直接下二进制
wget https://github.com/sigoden/dufs/releases/latest/download/dufs-v0.46.0-x86_64-unknown-linux-musl.tar.gz
tar xzf dufs-*.tar.gz && sudo install -m755 dufs-*/dufs /usr/local/bin/dufs

# 方案二：cargo install dufs（有 Rust 环境时）
```

### 2. 手动跑

```bash
dufs /srv/共享 -A -p 5000 -a "yunxia:你的口令@/:rw"
```

### 3. systemd 常驻

```bash
sudo tee /etc/systemd/system/dufs.service >/dev/null <<'EOF'
[Unit]
Description=dufs 文件共享
After=network-online.target

[Service]
ExecStart=/usr/local/bin/dufs /srv/共享 -A -p 5000 -a yunxia:你的口令@/:rw
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl enable --now dufs
systemctl status dufs
```

### 4. 群晖 / 威联通的特殊说明

- 用「Container Manager / Docker」跑最省事：

```bash
docker run -d --name dufs --restart unless-stopped \
  -p 5000:5000 -v /volume1/共享:/data \
  sigoden/dufs /data -A -a "yunxia:你的口令@/:rw"
```

- 群晖的共享目录在 `/volume1/<共享名>`，注意容器里是 `/data`，云匣配置里 `root` 写 `/`。

---

## 四、云匣这边的行为细节

- 列目录走 dufs 的 `?json` 接口；上传是 `PUT`（带 Content-Length，1MB 分块流式转发，不占内存）；建目录 `MKCOL`；改名/移动 `MOVE`；删除 `DELETE`。都是 dufs 的原生接口，不需要额外插件。
- 你那台 dufs 若**没开上传权限**（没加 `-A` 或 `--allow-upload`），云匣会识别到只读，前端直接不显示上传/新建按钮 —— 如果发现「只能看不能传」，先回到 dufs 命令行确认加了 `-A` 或 `--allow-upload --allow-delete`。
- 端口打通但列表报 401：说明云匣配置里的账号口令和 dufs 的 `-a` 不一致（口令里带 `@`、`: `、中文都容易错）。先用 `curl -u 用户名:口令 http://IP:5000/?json` 单独验证一次 dufs。
- 电脑关机时这个来源会报错/空列表，是预期行为。想减少干扰可以给它设 `enabled: false`，用的时候再改回来重启。

---

## 五、验收（在跑云匣的机器上执行）

```bash
IP=<云匣服务器 IP>
PC=http://192.168.1.20:5000     # 你电脑的 dufs 地址
T=$(curl -s -X POST http://$IP:8686/api/v1/auth/login -H 'Content-Type: application/json' \
      -d '{"password":"你的口令","device":"cli"}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["token"])')

# 1) 先确认 dufs 自己能列目录（带 json）
curl -s -u 'yunxia:你的口令' "$PC/?json" | head -c 200

# 2) 再确认云匣能列（source 用你配置里的 id）
curl -s -H "Authorization: Bearer $T" "http://$IP:8686/api/v1/fs/list?source=pc&path=/" | head -c 300
#    "allow_upload": true 才是真的能写

# 3) 上传 3MB 探针，然后到电脑上核对文件真的在
head -c 3000000 /dev/urandom > /tmp/u.bin; md5sum /tmp/u.bin
curl -s -X PUT -H "Authorization: Bearer $T" --data-binary @/tmp/u.bin \
  "http://$IP:8686/api/v1/fs/upload?source=pc&path=%2F&name=probe.bin"
# 回 {"path":"/probe.bin","size":3000000} 后，到电脑共享目录里 md5sum probe.bin 对一次，再删掉
curl -s -X POST -H "Authorization: Bearer $T" -H 'Content-Type: application/json' \
  -d '{"source":"pc","paths":["/probe.bin"]}' http://$IP:8686/api/v1/fs/delete
```

接口 200 不等于成功 —— **上传一定要落到那台电脑的文件上核对一次**（这是踩过坑的地方）。

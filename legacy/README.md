# 云匣 · 原版源码（参考存档）

这里放的是**云匣最初那一版**的源码——单用户、内网自用、只有作者一个人跑的那套。

现在的开源版（仓库根目录）是把同一套东西**重写**出来的，两者不共享代码：

| | 这里（原版） | 根目录（开源版） |
|---|---|---|
| 定位 | 一个人自己家里的私有部署 | 谁都能部署的自托管版本 |
| 服务端 | FastAPI，来源 = 本机 / dufs / **115 网盘(cd2 中转)** | FastAPI，来源 = 本机 / dufs / **通用 WebDAV** |
| 听译 | NAS `subs-hub`(5092) + 电脑 `asr-worker`（两处协作） | 服务端内置 faster-whisper 子进程（一台机器搞定） |
| 对话 | 直接转发到作者 WSL 上的 hermes | 任意 OpenAI 兼容服务，默认关闭 |
| 额外功能 | 磁力下载、云下载、PGS 图形字幕、实时听译 | 全部移除（依赖私有设施或第三方账号） |
| 配置 | 内网地址写死在代码里 | `config.json`，相对路径，可 Docker 部署 |

**留在这里的目的是「看一眼原来是怎么做的」**，不是给人直接跑。它跑不起来是正常的：
115 转发服务、hermes 网页对话、`subs-hub` 的 DeepSeek Key 都在作者自己的机器上。

## 目录

```
app/          Flutter 客户端（lib 源码 + test；android/ 只留清单和 gradle 配置）
web/          Vue 3 网页端（src 源码 + public 图标）
server/       FastAPI 服务端（app/ 路由与适配器 + tests/）
subs-hub/     【原版听译】NAS 上的中枢：任务表 + 字幕缓存 + 翻译
asr-worker/   【原版听译】电脑上的转写工：ffmpeg 抽音 + whisper
deploy/       部署脚本与 NAS 前端反代
docs/         设计文档、实现路径计划、老前端基线快照
docs/听译实现-原版.md   ← 原版听译方案（架构 / 接口 / 坑）
```

## 已做的脱敏

公开仓库里不该出现的东西都处理过了：

- 内网地址统一换成示例值（`192.168.1.10` = NAS、`192.168.1.20` = 电脑）
- 媒体根目录 `/mnt/mmc1-4/...` → `/mnt/data/...`，私人目录名换成 `影音库` / `movies`
- **不包含**：签名用 keystore、`key.properties`、打包好的 APK、`jniLibs` 里的 ffmpeg/mpv 二进制、
  运行期 `data/`（缩略图、索引库、字幕、播放记录）、备份压缩包
- 原版 `subs-hub` 的 DeepSeek Key 本来就不进仓库（从 `hub-config.json` 或环境变量读），这里也没有

## 想跑起来大概要补什么

- `app/android/key.properties`（自己的签名）→ 否则 `flutter build apk` 走 debug 签名
- `web/.env` / `vite.config.ts` 里的后端地址 → 改成你的
- `subs-hub/hub-config.json`（`{"max_active": 3}` 可选）+ 环境变量 `DEEPSEEK_API_KEY`
- `subs-hub/bin/` 下放 ARM64 的 `ffmpeg`/`ffprobe`（NAS 上没有系统 ffmpeg）
- `asr-worker` 需要 Python + `faster-whisper`（或 whisper.cpp 的 `ggml-*` 模型）

许可与根目录一致：MIT。原版代码同样是作者本人所写，可以直接借鉴。

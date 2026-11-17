# 云匣设计令牌（从线上 theme.css 提取，2026-10-30）

Flutter 的 `ThemeData` 和 Vue 的 `:root` 都必须从这里取值，**不要在界面代码里写死颜色**。

## 三套主题

线上网页版有 3 套，用户可切（`localStorage.mfm_theme`），Flutter 端必须同样支持：

| 主题 | 触发 | 特征 |
|---|---|---|
| 默认（蓝） | 无 `data-theme` / 其他值 | 蓝主色 `#1677f8`，底色 `#f4f7fc` |
| 浅（灰） | `data-theme="light"` | 无彩色，主色 `#3a3a3c`，底色 `#f2f3f5` |
| 深 | `data-theme="dark"` | 底 `#121417`，主色 `#4c9aff` |

## 令牌表

| 令牌 | 默认（蓝） | 浅（灰） | 深 |
|---|---|---|---|
| bg | `#f4f7fc` | `#f2f3f5` | `#121417` |
| bg2 | `#f7f9fd` | `#ffffff` | `#0e1013` |
| surface | `#ffffff` | `#ffffff` | `#1a1d21` |
| surface2 | `#f7fafe` | `#f7f8fa` | `#22262b` |
| line | `#e9eef5` | `#e5e7eb` | `#2b3037` |
| line2 | `#f2f5f9` | `#f0f1f3` | `#23272c` |
| ink | `#26364a` | `#2a2a2e` | `#e2e5e9` |
| ink2 | `#5d7391` | `#5c5c63` | `#9ba5b1` |
| ink3 | `#9aa8ba` | `#9a9aa4` | `#6f7782` |
| ac（主色） | `#1677f8` | `#3a3a3c` | `#4c9aff` |
| ac2（按下） | `#0868e9` | `#1d1d1f` | `#3b82f6` |
| acw（主色淡底） | `#e7f1ff` | `#ececee` | `#1b2735` |
| onac | `#ffffff` | `#ffffff` | `#ffffff` |
| nav | `rgba(255,255,255,.93)` | `rgba(255,255,255,.93)` | `rgba(18,20,23,.93)` |
| ov（遮罩） | `rgba(21,38,62,.33)` | `rgba(0,0,0,.34)` | `rgba(0,0,0,.62)` |
| sh（阴影色） | `rgba(53,99,156,.06)` | `rgba(0,0,0,.05)` | `rgba(0,0,0,.45)` |
| icobg | `#eef4ff` | `#f0f1f3` | `#262c34` |

## 文件类型色（图标底色 / 前景）

| 类型 | 默认 | 深 |
|---|---|---|
| 目录 | `#e8f2ff` / `#1677f8` | `#182b41` / `#63a9ff` |
| 图片 | `#e5f8ef` / `#0e9d78` | `#14322a` / `#43d09b` |
| 视频 | `#efeaff` / `#7c5cf0` | `#251f3e` / `#a78bfa` |
| 音频 | `#f2ecfb` / `#8859dc` | `#2a2142` / `#bd9af7` |
| PDF | `#fdecea` / `#c9403a` | `#33201f` / `#f4796c` |
| 文档 | `#edf1f7` / `#3d6396` | `#232a33` / `#9fb3cc` |
| 代码 | `#e6f6fb` / `#0e8ea3` | `#122e34` / `#4ec8d8` |
| 压缩包 | `#f9ebd8` / `#96631f` | `#32261a` / `#e0b072` |

## 形状与节奏

- 圆角档位：`9 / 11 / 12 / 14 / 16`，胶囊用 `999`
- 阴影：`0 2px 10px <sh>`、`0 4px 13px <sh>`、主按钮 `0 6px 16px rgba(22,120,248,.24)`
- 动效：`transform/opacity .22s ease`、`background .12–.15s`、进度条宽度 `.3–.4s ease`
- 毛玻璃：`backdrop-filter: blur(6/10/14/18px)` —— 顶栏、底部导航、浮层都用它

## Flutter 对应关系（P5 落地时照这个映射）

| Web | Flutter |
|---|---|
| `--t-surface` + `border-radius:14px` | `Card` 皮肤：`BoxDecoration(color, borderRadius: 14, boxShadow 极淡)` |
| `backdrop-filter` 导航 | `BackdropFilter(ImageFilter.blur(sigmaX: 18))` + 半透明色 |
| `transition .22s ease` | `AnimatedContainer(duration: 220ms, curve: Curves.easeOut)` |
| `999px` 胶囊 | `BorderRadius.circular(999)` |
| 按下 `background .12s` | `InkWell` 关水波纹，改 `AnimatedContainer` 变 `ac2`/`acw` |

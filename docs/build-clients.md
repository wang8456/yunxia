# 编译两个客户端

## 一、网页端（web/）

```bash
cd web
npm install                     # 国内慢就加 --registry=https://registry.npmmirror.com
npm run dev                     # 开发：http://localhost:5173，/api 与 /hermes 会代理到 127.0.0.1:8686
npm run build                   # 生产：类型检查 + 打包，产物在 web/dist
```

开发时把服务端先跑起来（默认 8686），`vite.config.ts` 里已经配好代理，不用改 CORS。

生产部署两种方式：

1. **服务端直接托管**（最省事）：`npm run build` 后，服务端启动时会自动找 `<仓库>/web/dist` 并发出去，
   访问 `http://<服务器 IP>:8686/` 就是完整应用。
2. **Nginx 托管**：把 `web/dist` 拷到 Nginx 根目录，`/api` 与 `/hermes` 反代到 8686，
   示例见 `deploy/nginx.conf.example`（注意 Range 透传和 SSE 不缓冲）。

## 二、Android（app/）

需要 Flutter **3.24+** 与 JDK 17。

```bash
cd app
flutter pub get
flutter analyze                 # 应零 error
flutter build apk --release     # 产物 build/app/outputs/flutter-apk/app-release.apk
```

安装包在 `app/build/app/outputs/flutter-apk/app-release.apk`，直接装到手机即可。
**第一次打开会让你填服务器地址**（例如 `http://192.168.1.10:8686`），之后可以在「设置 → 账号 → 服务器地址」里改。

想免掉这一步，就在编译时把默认地址打进包里：

```bash
flutter build apk --release --dart-define=YUNXIA_SERVER=http://192.168.1.10:8686
```

> `app/android/app/src/main/jniLibs/` 里带的是 mpv-android 官方构建的 `libmpv.so` 与 ffmpeg 库
>（约 58MB，带 libplacebo / 硬解），所以仓库里会有这些二进制；`build.gradle.kts` 用 `pickFirst`
> 让它们优先于 media_kit 自带的那份。**不要删**，删了播放器会黑屏或掉硬解。

要改包名 / 签名：

- 包名：`android/app/build.gradle.kts` 里的 `applicationId`，以及 `AndroidManifest.xml` / `MainActivity.kt` 的包路径
- 正式签名：在 `android/` 下建 `key.properties`（`storeFile` / `storePassword` / `keyAlias` / `keyPassword`），
  并把 keystore 放在 `android/app/`（**别提交到 git**）

## 三、iOS / 桌面

代码是纯 Flutter，理论上 `flutter build ios` / `macos` / `windows` 都能出，
但本项目只验证过 Android 和网页（播放器用了 `media_kit`，其它平台的配置需要自己补）。

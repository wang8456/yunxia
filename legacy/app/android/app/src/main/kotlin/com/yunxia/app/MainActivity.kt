package com.yunxia.app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.media.AudioManager
import android.provider.MediaStore
import android.provider.Settings
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * 只有原生能做的事，走 MethodChannel（yunxia/native），不引第三方插件：
 *
 *   pickFiles       系统文件选择器（可多选），复制到缓存交给 Dart 上传
 *   saveToDownloads 整个文件写进「下载/云匣」（小文件收尾用）
 *   beginWrite / writeChunk / finishWrite / abortWrite
 *                   大文件边下边写：先占一个 MediaStore 条目，Dart 每收到一块就直接写进去，
 *                   不再落临时文件再复制，省一半空间
 *   openUri         用系统应用打开（文件管理器 / 播放器 / WPS …）
 *   readBytes       读小文件（图片）给应用内查看器
 *   deleteUri       删掉自己下载的文件
 */
class MainActivity : FlutterActivity() {

    private val channelName = "yunxia/native"
    private val io = Executors.newSingleThreadExecutor()
    private var pendingResult: MethodChannel.Result? = null

    private class Writer(
        val uri: Uri?,
        val file: File?,
        val out: OutputStream,
        val name: String,
        val mime: String,
        val pending: Boolean,
    )

    private val writers = ConcurrentHashMap<String, Writer>()

    companion object {
        private const val REQ_PICK = 4001
        private const val SUBDIR = "云匣"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFiles" -> pickFiles(result)
                    "clipboardFiles" -> clipboardFiles(result)
                    "saveToDownloads" -> {
                        val path = call.argument<String>("path") ?: ""
                        val name = call.argument<String>("name") ?: ""
                        val mime = call.argument<String>("mime") ?: "application/octet-stream"
                        saveToDownloads(path, name, mime, result)
                    }
                    "beginWrite" -> beginWrite(
                        call.argument<String>("name") ?: "file",
                        call.argument<String>("mime") ?: "application/octet-stream",
                        call.argument<String>("uri") ?: "",
                        (call.argument<Number>("offset") ?: 0).toLong(),
                        result,
                    )
                    "writeChunk" -> writeChunk(
                        call.argument<String>("token") ?: "",
                        call.argument<ByteArray>("bytes") ?: ByteArray(0),
                        result,
                    )
                    "finishWrite" -> finishWrite(call.argument<String>("token") ?: "", result)
                    "abortWrite" -> abortWrite(call.argument<String>("token") ?: "", result)
                    "closeWrite" -> closeWrite(call.argument<String>("token") ?: "", result)
                    "openUrl" -> openUrl(
                        call.argument<String>("url") ?: "",
                        result,
                    )
                    "openUri" -> openUri(
                        call.argument<String>("uri") ?: "",
                        call.argument<String>("path") ?: "",
                        call.argument<String>("mime") ?: "*/*",
                        result,
                    )
                    "fileSize" -> fileSize(
                        call.argument<String>("uri") ?: "",
                        call.argument<String>("path") ?: "",
                        result,
                    )
                    "readBytes" -> readBytes(
                        call.argument<String>("uri") ?: "",
                        call.argument<String>("path") ?: "",
                        result,
                    )
                    // 系统音量 / 屏幕亮度（不是 App 内部音量，用户要的是系统的）
                    "getVolume" -> result.success(getVolumePercent())
                    "setVolume" -> result.success(
                        setVolumePercent((call.argument<Number>("percent") ?: 0).toInt())
                    )
                    "getBrightness" -> result.success(getBrightnessPercent())
                    "setBrightness" -> setBrightnessPercent(
                        (call.argument<Number>("percent") ?: 50).toInt(), result,
                    )
                    "resetBrightness" -> {
                        resetWindowBrightness()
                        result.success(true)
                    }
                    "writeSettings" -> {
                        openWriteSettings()
                        result.success(true)
                    }
                    // APK 安装：先查「安装未知应用」权限，没有就跳系统授权页
                    "canInstall" -> result.success(canInstallApk())
                    "installPermission" -> {
                        openInstallPermission()
                        result.success(true)
                    }
                    "installApk" -> installApk(
                        call.argument<String>("uri") ?: "",
                        call.argument<String>("path") ?: "",
                        result,
                    )
                    "deleteUri" -> deleteUri(
                        call.argument<String>("uri") ?: "",
                        call.argument<String>("path") ?: "",
                        result,
                    )
                    else -> result.notImplemented()
                }
            }
    }

    // ---------- 选文件 ----------

    private fun pickFiles(result: MethodChannel.Result) {
        if (pendingResult != null) {
            result.error("busy", "已经有选择器在开着", null)
            return
        }
        pendingResult = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
        }
        try {
            startActivityForResult(intent, REQ_PICK)
        } catch (e: Exception) {
            pendingResult = null
            result.error("no_picker", "打不开系统文件选择器：${e.message}", null)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQ_PICK) return
        val result = pendingResult ?: return
        pendingResult = null
        if (resultCode != Activity.RESULT_OK || data == null) {
            result.success(emptyList<Map<String, Any>>())
            return
        }
        val uris = mutableListOf<Uri>()
        data.clipData?.let { clip ->
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        }
        data.data?.let { uris.add(it) }
        if (uris.isEmpty()) {
            result.success(emptyList<Map<String, Any>>())
            return
        }
        io.execute {
            val out = mutableListOf<Map<String, Any>>()
            for (uri in uris) {
                try {
                    val name = displayName(uri)
                    val dir = File(cacheDir, "upload")
                    if (!dir.exists()) dir.mkdirs()
                    val dst = File(dir, name)
                    contentResolver.openInputStream(uri)?.use { input ->
                        dst.outputStream().use { output -> input.copyTo(output, 1 shl 16) }
                    }
                    out.add(mapOf("name" to name, "path" to dst.absolutePath, "size" to dst.length()))
                } catch (e: Exception) {
                    // 单个文件失败不影响其它文件
                }
            }
            runOnUiThread { result.success(out) }
        }
    }

    private fun displayName(uri: Uri): String {
        var name = "file_${System.currentTimeMillis()}"
        contentResolver.query(uri, null, null, null, null)?.use { c ->
            val idx = c.getColumnIndex(OpenableColumns.DISPLAY_NAME)
            if (idx >= 0 && c.moveToFirst()) name = c.getString(idx)
        }
        return name.replace("/", "_")
    }

    // ---------- 整文件保存（小文件） ----------

    private fun saveToDownloads(path: String, name: String, mime: String, result: MethodChannel.Result) {
        io.execute {
            try {
                val src = File(path)
                if (!src.exists()) {
                    runOnUiThread { result.error("missing", "源文件不存在：$path", null) }
                    return@execute
                }
                val (publicPath, _) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val uri = insertPending(name, mime)
                    contentResolver.openOutputStream(uri)?.use { out ->
                        src.inputStream().use { it.copyTo(out, 1 shl 16) }
                    }
                    publish(uri)
                    "${Environment.DIRECTORY_DOWNLOADS}/$SUBDIR/$name" to uri
                } else {
                    val dst = legacyFile(name)
                    src.inputStream().use { input ->
                        dst.outputStream().use { output -> input.copyTo(output, 1 shl 16) }
                    }
                    dst.absolutePath to Uri.fromFile(dst)
                }
                runOnUiThread { result.success(publicPath) }
            } catch (e: Exception) {
                runOnUiThread { result.error("save_failed", e.message ?: "保存失败", null) }
            }
        }
    }

    // ---------- 边下边写 ----------

    private fun insertPending(name: String, mime: String): Uri {
        val values = ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(MediaStore.Downloads.MIME_TYPE, mime)
            put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/$SUBDIR")
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
        return contentResolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IllegalStateException("MediaStore 插入失败")
    }

    private fun publish(uri: Uri) {
        val values = ContentValues().apply { put(MediaStore.Downloads.IS_PENDING, 0) }
        contentResolver.update(uri, values, null, null)
    }

    private fun legacyFile(name: String): File {
        @Suppress("DEPRECATION")
        val dir = File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
            SUBDIR,
        )
        if (!dir.exists()) dir.mkdirs()
        return File(dir, name)
    }

    /** [uri] 非空 = 续传已有条目，[offset] 已经写了多少字节 */
    private fun beginWrite(
        name: String,
        mime: String,
        uriStr: String,
        offset: Long,
        result: MethodChannel.Result,
    ) {
        io.execute {
            try {
                val token = UUID.randomUUID().toString()
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    val uri: Uri
                    val out: OutputStream
                    if (uriStr.isNotEmpty()) {
                        uri = Uri.parse(uriStr)
                        val pfd = contentResolver.openFileDescriptor(uri, "rw")
                            ?: throw IllegalStateException("续传打不开文件")
                        out = java.io.FileOutputStream(pfd.fileDescriptor)
                        if (out is java.io.FileOutputStream) {
                            out.channel.position(offset)
                        }
                    } else {
                        uri = insertPending(name, mime)
                        out = contentResolver.openOutputStream(uri)
                            ?: throw IllegalStateException("拿不到输出流")
                    }
                    writers[token] = Writer(uri, null, out, name, mime, true)
                    runOnUiThread {
                        result.success(mapOf("token" to token, "uri" to uri.toString()))
                    }
                } else {
                    val f = if (uriStr.isNotEmpty() && uriStr.startsWith("file://")) {
                        File(Uri.parse(uriStr).path!!)
                    } else legacyFile(name)
                    val out = java.io.FileOutputStream(f, true)
                    out.channel.position(offset)
                    writers[token] = Writer(null, f, out, name, mime, false)
                    runOnUiThread {
                        result.success(
                            mapOf("token" to token, "uri" to Uri.fromFile(f).toString())
                        )
                    }
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("begin_failed", e.message ?: "建不了下载文件", null) }
            }
        }
    }

    /** 已经写到哪了：续传必须用文件真实长度，不能信上次存进 JSON 的数字 */
    private fun fileSize(uriStr: String, path: String, result: MethodChannel.Result) {
        io.execute {
            try {
                var n = -1L
                if (uriStr.isNotEmpty()) {
                    val uri = Uri.parse(uriStr)
                    contentResolver.openFileDescriptor(uri, "r")?.use { n = it.statSize } ?: run { n = -1L }
                }
                if (n <= 0 && path.isNotEmpty()) {
                    val f = File(path)
                    if (f.exists()) n = f.length()
                }
                runOnUiThread { result.success(if (n < 0) 0 else n) }
            } catch (e: Exception) {
                runOnUiThread { result.success(0) }
            }
        }
    }

    private fun writeChunk(token: String, bytes: ByteArray, result: MethodChannel.Result) {
        val w = writers[token]
        if (w == null) {
            result.error("no_writer", "写入句柄已失效", null)
            return
        }
        try {
            w.out.write(bytes)
            result.success(bytes.size)
        } catch (e: Exception) {
            result.error("write_failed", e.message ?: "写入失败", null)
        }
    }

    private fun finishWrite(token: String, result: MethodChannel.Result) {
        val w = writers.remove(token)
        if (w == null) {
            result.error("no_writer", "写入句柄已失效", null)
            return
        }
        io.execute {
            try {
                w.out.flush()
                w.out.close()
                if (w.uri != null && w.pending) publish(w.uri)
                val path = if (w.file != null) w.file.absolutePath
                else "${Environment.DIRECTORY_DOWNLOADS}/$SUBDIR/${w.name}"
                runOnUiThread {
                    result.success(
                        mapOf(
                            "path" to path,
                            "uri" to (w.uri?.toString() ?: ""),
                        )
                    )
                }
            } catch (e: Exception) {
                runOnUiThread { result.error("finish_failed", e.message ?: "收尾失败", null) }
            }
        }
    }

    /** 关流但保留未完成的条目（下次续传接着写，用户看不到半截文件） */
    private fun closeWrite(token: String, result: MethodChannel.Result) {
        val w = writers.remove(token)
        if (w == null) {
            result.success(true)
            return
        }
        io.execute {
            try {
                w.out.flush()
                w.out.close()
            } catch (_: Exception) {
            }
            runOnUiThread { result.success(true) }
        }
    }

    private fun abortWrite(token: String, result: MethodChannel.Result) {
        val w = writers.remove(token)
        if (w == null) {
            result.success(true)
            return
        }
        io.execute {
            try {
                w.out.close()
            } catch (_: Exception) {
            }
            try {
                if (w.uri != null) contentResolver.delete(w.uri, null, null)
                w.file?.delete()
            } catch (_: Exception) {
            }
            runOnUiThread { result.success(true) }
        }
    }

    // ---------- 打开 / 读 / 删 ----------

    /// 打开网页链接：交给浏览器（openUri 会带 type，某些 ROM 上会解析不到浏览器）
    private fun openUrl(url: String, result: MethodChannel.Result) {
        if (url.isEmpty()) {
            result.error("no_url", "没有链接", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            result.error("open_failed", e.message ?: "打不开链接", null)
        }
    }

    private fun openUri(uri: String, path: String, mime: String, result: MethodChannel.Result) {
        try {
            val target: Uri = when {
                uri.isNotEmpty() -> Uri.parse(uri)
                path.isNotEmpty() -> Uri.fromFile(File(path))
                else -> throw IllegalArgumentException("没有地址")
            }
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(target, mime.ifEmpty { "*/*" })
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(Intent.createChooser(intent, "打开方式"))
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.error("no_app", "没有能打开这种文件的应用", null)
        } catch (e: Exception) {
            result.error("open_failed", e.message ?: "打不开", null)
        }
    }

    private fun readBytes(uri: String, path: String, result: MethodChannel.Result) {
        io.execute {
            try {
                val bytes = when {
                    uri.isNotEmpty() -> contentResolver.openInputStream(Uri.parse(uri))
                        ?.use { it.readBytes() }
                    path.isNotEmpty() -> File(path).readBytes()
                    else -> null
                } ?: throw IllegalStateException("读不到文件")
                runOnUiThread { result.success(bytes) }
            } catch (e: Exception) {
                runOnUiThread { result.error("read_failed", e.message ?: "读取失败", null) }
            }
        }
    }

    private fun deleteUri(uri: String, path: String, result: MethodChannel.Result) {
        io.execute {
            var ok = false
            try {
                if (uri.isNotEmpty()) ok = contentResolver.delete(Uri.parse(uri), null, null) > 0
                if (!ok && path.isNotEmpty()) ok = File(path).delete()
            } catch (_: Exception) {
            }
            runOnUiThread { result.success(ok) }
        }
    }

    // ---------- 安装 APK ----------

    /** 本 App 有没有「安装未知应用」权限（Android 8 起按安装器授权） */
    private fun canInstallApk(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            packageManager.canRequestPackageInstalls()
        else true

    /** 直接跳到本 App 的「安装未知应用」系统开关页 */
    private fun openInstallPermission() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val intents = listOf(
            Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:$packageName")),
            Intent(Settings.ACTION_SECURITY_SETTINGS),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (i in intents) {
            try {
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(i)
                return
            } catch (_: Exception) {
            }
        }
    }

    /** 拉起系统安装器。返回值：ok / need_permission / missing / error:xxx */
    private fun installApk(uri: String, path: String, result: MethodChannel.Result) {
        try {
            if (!canInstallApk()) {
                openInstallPermission()
                result.success("need_permission")
                return
            }
            val target: Uri = if (uri.isNotEmpty()) {
                Uri.parse(uri)
            } else {
                val f = File(path)
                if (!f.exists()) {
                    result.success("missing")
                    return
                }
                androidx.core.content.FileProvider.getUriForFile(
                    this, "$packageName.fileprovider", f
                )
            }
            val i = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(target, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(i)
            result.success("ok")
        } catch (e: Exception) {
            result.success("error:${e.message}")
        }
    }

    // ---------- 系统音量 / 屏幕亮度 ----------

    private fun audioManager(): AudioManager =
        getSystemService(AUDIO_SERVICE) as AudioManager

    /** 当前媒体音量百分比（0-100） */
    private fun getVolumePercent(): Int {
        return try {
            val am = audioManager()
            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            val cur = am.getStreamVolume(AudioManager.STREAM_MUSIC)
            if (max <= 0) 0 else cur * 100 / max
        } catch (e: Exception) {
            50
        }
    }

    /** 直接改系统媒体音量，返回改完的百分比 */
    private fun setVolumePercent(percent: Int): Int {
        return try {
            val am = audioManager()
            val max = am.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
            if (max <= 0) return 0
            val idx = Math.round(percent.coerceIn(0, 100) * max / 100f).coerceIn(0, max)
            am.setStreamVolume(AudioManager.STREAM_MUSIC, idx, 0)
            idx * 100 / max
        } catch (e: Exception) {
            percent
        }
    }

    /** 当前屏幕亮度百分比：有写设置权限读系统值，否则读窗口值 */
    private fun getBrightnessPercent(): Int {
        try {
            if (Settings.System.canWrite(this)) {
                val v = Settings.System.getInt(
                    contentResolver, Settings.System.SCREEN_BRIGHTNESS, 128
                )
                return (v * 100 / 255).coerceIn(1, 100)
            }
        } catch (_: Exception) {
        }
        val w = (window.attributes.screenBrightness * 100).toInt()
        return if (w > 0) w.coerceIn(1, 100) else 50
    }

    /**
     * 改亮度：窗口亮度先立刻生效（无权限也能看见变化），
     * 有 WRITE_SETTINGS 权限时同时写系统亮度，退出播放器也是这个亮度。
     * 返回 "system:<pct>" 或 "window:<pct>"，前端据此决定要不要提示授权。
     */
    private fun setBrightnessPercent(percent: Int, result: MethodChannel.Result) {
        val p = percent.coerceIn(1, 100)
        try {
            val attrs = window.attributes
            attrs.screenBrightness = p / 100f
            window.attributes = attrs
        } catch (_: Exception) {
        }
        if (Settings.System.canWrite(this)) {
            try {
                Settings.System.putInt(
                    contentResolver, Settings.System.SCREEN_BRIGHTNESS, p * 255 / 100
                )
                result.success("system:$p")
                return
            } catch (_: Exception) {
            }
        }
        result.success("window:$p")
    }

    /** 退出播放器：窗口亮度交回系统（不影响系统亮度值） */
    private fun resetWindowBrightness() {
        try {
            val attrs = window.attributes
            attrs.screenBrightness = android.view.WindowManager.LayoutParams.BRIGHTNESS_OVERRIDE_NONE
            window.attributes = attrs
        } catch (_: Exception) {
        }
    }

    /** 跳「修改系统设置」授权页（改系统亮度必需） */
    private fun openWriteSettings() {
        val intents = listOf(
            Intent(Settings.ACTION_MANAGE_WRITE_SETTINGS, Uri.parse("package:$packageName")),
            Intent(Settings.ACTION_SETTINGS),
        )
        for (i in intents) {
            try {
                i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                startActivity(i)
                return
            } catch (_: Exception) {
            }
        }
    }

    /**
     * 读剪贴板里的图片 / 文件（截图、文件管理器复制出来的文件），
     * 复制进缓存目录交给 Flutter 上传。输入框旁的「粘贴」按钮走这里。
     */
    private fun clipboardFiles(result: MethodChannel.Result) {
        io.execute {
            try {
                val cm = getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
                val clip = cm.primaryClip
                val out = mutableListOf<Map<String, Any>>()
                if (clip != null) {
                    val dir = File(cacheDir, "upload")
                    if (!dir.exists()) dir.mkdirs()
                    for (i in 0 until clip.itemCount) {
                        val item = clip.getItemAt(i)
                        val uri = item.uri
                        if (uri != null) {
                            try {
                                val name = displayName(uri)
                                val dst = File(dir, "clip_" + System.currentTimeMillis() + "_" + name)
                                contentResolver.openInputStream(uri)?.use { input ->
                                    dst.outputStream().use { output -> input.copyTo(output, 1 shl 16) }
                                }
                                out.add(mapOf("name" to name, "path" to dst.absolutePath, "size" to dst.length()))
                                continue
                            } catch (e: Exception) {
                                // 读不到这个 uri 就试下一项
                            }
                        }
                        val txt = try {
                            item.coerceToText(this)?.toString()?.trim() ?: ""
                        } catch (e: Exception) {
                            ""
                        }
                        if (txt.isNotEmpty() && !txt.contains("\n")) {
                            val f = File(txt)
                            if (f.exists() && f.isFile && f.canRead()) {
                                out.add(mapOf("name" to f.name, "path" to f.absolutePath, "size" to f.length()))
                            }
                        }
                    }
                }
                runOnUiThread { result.success(out) }
            } catch (e: Exception) {
                runOnUiThread { result.error("clipboard", e.message ?: "读取剪贴板失败", null) }
            }
        }
    }

}

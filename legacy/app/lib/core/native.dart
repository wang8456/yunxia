import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// 原生能力（MainActivity.kt 里的 MethodChannel，"yunxia/native"）：
/// 系统文件选择器、写进系统「下载/云匣」。两条都不引第三方插件。
class Native {
  static const _ch = MethodChannel('yunxia/native');

  /// 打开系统文件选择器，返回已复制到应用缓存的文件
  static Future<List<File>> pickFiles() async {
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('pickFiles');
      if (raw == null) return const [];
      return raw
          .whereType<Map>()
          .map((m) => File(m['path'] as String))
          .where((f) => f.existsSync())
          .toList();
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '打开文件选择器失败');
    } on MissingPluginException {
      throw StateError('这个平台不支持文件选择器');
    }
  }

  /// 读剪贴板里的图片/文件（截图、文件管理器复制出来的文件）。
  /// 返回 [{name, path}]，拿不到就空列表。
  static Future<List<Map<String, String>>> clipboardFiles() async {
    try {
      final raw = await _ch.invokeMethod<List<dynamic>>('clipboardFiles');
      if (raw == null) return const [];
      return raw.whereType<Map>().map((m) {
        return {
          'name': '${m['name'] ?? 'clipboard'}',
          'path': '${m['path'] ?? ''}',
        };
      }).where((m) => m['path']!.isNotEmpty && File(m['path']!).existsSync()).toList();
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '读剪贴板失败');
    } on MissingPluginException {
      throw StateError('这个平台不支持粘贴文件');
    }
  }

  /// 把应用内的文件交给系统「下载/云匣」，返回公开路径
  static Future<String> saveToDownloads(
    File file, {
    String? name,
    String? mime,
  }) async {
    try {
      final p = await _ch.invokeMethod<String>('saveToDownloads', {
        'path': file.path,
        'name': name ?? file.uri.pathSegments.last,
        'mime': mime ?? _mimeOf(name ?? file.path),
      });
      return p ?? '';
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '保存失败');
    } on MissingPluginException {
      throw StateError('这个平台不支持保存到下载目录');
    }
  }

  // ---------- 系统音量 / 屏幕亮度（改的是设备本身，不是 App 内部） ----------

  static Future<int> getVolume() async {
    try {
      return await _ch.invokeMethod<int>('getVolume') ?? 50;
    } catch (_) {
      return 50;
    }
  }

  /// 返回设置后的实际百分比
  static Future<int> setVolume(int percent) async {
    try {
      return await _ch.invokeMethod<int>('setVolume', {'percent': percent}) ??
          percent;
    } catch (_) {
      return percent;
    }
  }

  static Future<int> getBrightness() async {
    try {
      return await _ch.invokeMethod<int>('getBrightness') ?? 50;
    } catch (_) {
      return 50;
    }
  }

  /// 返回 "system:42"（真·系统亮度）或 "window:42"（没授权，只压暗本窗口）
  static Future<String> setBrightness(int percent) async {
    try {
      return await _ch.invokeMethod<String>('setBrightness', {
            'percent': percent,
          }) ??
          'window:$percent';
    } catch (_) {
      return 'window:$percent';
    }
  }

  static Future<void> resetBrightness() async {
    try {
      await _ch.invokeMethod('resetBrightness');
    } catch (_) {}
  }

  /// 跳「修改系统设置」授权页
  static Future<void> openWriteSettings() async {
    try {
      await _ch.invokeMethod('writeSettings');
    } catch (_) {}
  }

  /// 有没有「安装未知应用」权限（Android 8 起按安装器授权，第一次必须用户手动开）
  static Future<bool> canInstall() async {
    try {
      return await _ch.invokeMethod<bool>('canInstall') ?? false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 直接跳到系统的「安装未知应用」开关页（就是这个 App 自己的那一项）
  static Future<void> openInstallPermission() async {
    try {
      await _ch.invokeMethod('installPermission');
    } on MissingPluginException {
      /* 桌面端没有，忽略 */
    }
  }

  /// 拉起系统安装器。返回 ok / need_permission / missing / error:xxx
  static Future<String> installApk({String uri = '', String path = ''}) async {
    try {
      final r = await _ch.invokeMethod<String>('installApk', {
        'uri': uri,
        'path': path,
      });
      return r ?? 'error:null';
    } on MissingPluginException {
      return 'error:unsupported';
    } catch (e) {
      return 'error:$e';
    }
  }

  /// 大文件边下边写：先占一个 MediaStore 条目，拿到写入句柄
  static Future<StreamWriter?> beginWrite(
    String name,
    String mime, {
    String uri = '',
    int offset = 0,
  }) async {
    try {
      final m = await _ch.invokeMethod<Map<dynamic, dynamic>>('beginWrite', {
        'name': name,
        'mime': mime,
        'uri': uri,
        'offset': offset,
      });
      final token = m?['token'] as String?;
      if (token == null || token.isEmpty) return null;
      return StreamWriter(token, (m?['uri'] as String?) ?? '');
    } on MissingPluginException {
      return null; // 桌面/调试环境退回临时文件
    } on PlatformException {
      return null;
    }
  }

  /// 用浏览器打开链接
  static Future<bool> openUrl(String url) async {
    try {
      final ok = await _ch.invokeMethod<bool>('openUrl', {'url': url});
      return ok == true;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '打不开链接');
    } on MissingPluginException {
      throw StateError('这个平台不支持打开链接');
    }
  }

  /// 用系统应用打开（uri 为空就用本地路径）
  static Future<bool> open(String uri, String path, String mime) async {
    try {
      final ok = await _ch.invokeMethod<bool>('openUri', {
        'uri': uri,
        'path': path,
        'mime': mime,
      });
      return ok == true;
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '打不开');
    } on MissingPluginException {
      throw StateError('这个平台不支持外部打开');
    }
  }

  /// 读图片这类小文件给应用内查看器
  /// 文件已经写到多少字节（续传用真实长度，别用上次存的进度）
  static Future<int> fileSize({String uri = '', String path = ''}) async {
    try {
      final n = await _ch.invokeMethod<int>('fileSize', {
        'uri': uri,
        'path': path,
      });
      return n ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static Future<Uint8List> readBytes(String uri, String path) async {
    try {
      final b = await _ch.invokeMethod<Uint8List>('readBytes', {
        'uri': uri,
        'path': path,
      });
      return b ?? Uint8List(0);
    } on PlatformException catch (e) {
      throw StateError(e.message ?? '读取失败');
    } on MissingPluginException {
      throw StateError('这个平台不支持读本地文件');
    }
  }

  /// 删掉自己下载的文件
  static Future<bool> delete(String uri, String path) async {
    try {
      final ok = await _ch.invokeMethod<bool>('deleteUri', {
        'uri': uri,
        'path': path,
      });
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  static String _mimeOf(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    const map = {
      'mp4': 'video/mp4',
      'mkv': 'video/x-matroska',
      'mov': 'video/quicktime',
      'avi': 'video/x-msvideo',
      'mp3': 'audio/mpeg',
      'flac': 'audio/flac',
      'm4a': 'audio/mp4',
      'jpg': 'image/jpeg',
      'jpeg': 'image/jpeg',
      'png': 'image/png',
      'gif': 'image/gif',
      'webp': 'image/webp',
      'pdf': 'application/pdf',
      'zip': 'application/zip',
      'apk': 'application/vnd.android.package-archive',
      'txt': 'text/plain',
    };
    return map[ext] ?? 'application/octet-stream';
  }

  static String mimeOf(String name) => _mimeOf(name);
}

/// 一个「已经打开的下载文件」，write 进去的就是磁盘上的数据（不落临时文件）
class StreamWriter {
  final String token;
  final String uri;
  const StreamWriter(this.token, this.uri);

  Future<void> write(List<int> bytes) async {
    await Native._ch.invokeMethod<int>('writeChunk', {
      'token': token,
      'bytes': Uint8List.fromList(bytes),
    });
  }

  /// 收尾，返回公开路径与 content:// 地址
  Future<({String path, String uri})?> finish() async {
    try {
      final m = await Native._ch.invokeMethod<Map<dynamic, dynamic>>(
        'finishWrite',
        {'token': token},
      );
      return (
        path: (m?['path'] as String?) ?? '',
        uri: (m?['uri'] as String?) ?? uri,
      );
    } catch (_) {
      return null;
    }
  }

  /// 关流但不发布（暂停/出错时留着续传）
  Future<void> closeKeep() async {
    try {
      await Native._ch.invokeMethod<bool>('closeWrite', {'token': token});
    } catch (_) {}
  }

  Future<void> abort() async {
    try {
      await Native._ch.invokeMethod<bool>('abortWrite', {'token': token});
    } catch (_) {}
  }
}

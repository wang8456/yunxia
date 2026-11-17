import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import 'app_icons_data.dart';
import 'tokens.dart';

/// 旧版前端那套 Hugeicons Stroke Rounded 图标。
///
/// 与 `手机共享-图标方案.html` 里的方案 B（分类配色）一致：
/// 线稿粗细和网页一样 1.5，颜色按文件类型走。
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.name, {
    super.key,
    this.size = 22,
    this.color = const Color(0xFF40536D),
    this.strokeWidth,
  });

  final String name;
  final double size;
  final Color color;
  final double? strokeWidth;

  @override
  Widget build(BuildContext context) {
    final raw = kIconSvg[name];
    if (raw == null) {
      // 缺图时不要白屏：退化成圆点，一眼能看出是漏了哪个名字
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Container(
            width: size * 0.4,
            height: size * 0.4,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      );
    }
    final hex =
        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
    var body = raw.replaceAll('currentColor', hex);
    if (strokeWidth != null) {
      body = body
          .replaceAll('stroke-width="1.5"', 'stroke-width="$strokeWidth"')
          .replaceAll('stroke-width="1.8"', 'stroke-width="$strokeWidth"');
    }
    const head =
        '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" '
        'viewBox="0 0 24 24" fill="none" stroke="currentColor" '
        'stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round">';
    return SvgPicture.string(
      '$head$body</svg>',
      width: size,
      height: size,
    );
  }
}

/// 图标方案里的分类配色（背景 + 前景），键是扩展名归类。
class FileTone {
  const FileTone(this.bg, this.fg);
  final Color bg;
  final Color fg;
}

const Map<String, FileTone> kTypeTone = {
  'folder': FileTone(Color(0xFFE8F2FF), Color(0xFF1677F8)),
  'image': FileTone(Color(0xFFE5F8EF), Color(0xFF0E9D78)),
  'video': FileTone(Color(0xFFEFEAFF), Color(0xFF7C5CF0)),
  'audio': FileTone(Color(0xFFF0EAFF), Color(0xFF8859DC)),
  'zip': FileTone(Color(0xFFFFF3DF), Color(0xFFC78218)),
  'code': FileTone(Color(0xFFE6F6FB), Color(0xFF0E8EA3)),
  'pdf': FileTone(Color(0xFFFFF0EE), Color(0xFFE45E53)),
  'doc': FileTone(Color(0xFFE9F2FF), Color(0xFF287BE8)),
  'file': FileTone(Color(0xFFEEF1F6), Color(0xFF5B6B82)),
};

/// 五套主题各自的文件类型配色 —— 逐字照 5020 旧前端 theme.css 的 --k-* 变量。
/// 色相固定八种（文件夹/图片/视频/音频/压缩/代码/PDF/文档），主题只换明度世界：
/// 浅色降饱和、深色提亮、护眼加暖。改色只改这一处。
const Map<String, Map<String, FileTone>> kTypeToneByTheme = {
  'blue': {
    'folder': FileTone(Color(0xFFE8F2FF), Color(0xFF1677F8)),
    'image': FileTone(Color(0xFFE5F8EF), Color(0xFF0E9D78)),
    'video': FileTone(Color(0xFFEFEAFF), Color(0xFF7C5CF0)),
    'audio': FileTone(Color(0xFFF0EAFF), Color(0xFF8859DC)),
    'zip': FileTone(Color(0xFFFFF3DF), Color(0xFFB3720F)),
    'code': FileTone(Color(0xFFE6F6FB), Color(0xFF0E8EA3)),
    'pdf': FileTone(Color(0xFFFFF0EE), Color(0xFFE45E53)),
    'doc': FileTone(Color(0xFFF0F2F5), Color(0xFF4A6B9C)),
  },
  'light': {
    'folder': FileTone(Color(0xFFEEF0F3), Color(0xFF3A3A3C)),
    'image': FileTone(Color(0xFFE9F4EE), Color(0xFF2E7D5B)),
    'video': FileTone(Color(0xFFEFEAF8), Color(0xFF6B4FC0)),
    'audio': FileTone(Color(0xFFF1ECF8), Color(0xFF7A58B8)),
    'zip': FileTone(Color(0xFFF9F0E1), Color(0xFF9C6B17)),
    'code': FileTone(Color(0xFFE7F2F4), Color(0xFF2B7C88)),
    'pdf': FileTone(Color(0xFFFBECEB), Color(0xFFBF4A41)),
    'doc': FileTone(Color(0xFFEDF1F7), Color(0xFF37699F)),
  },
  'dark': {
    'folder': FileTone(Color(0xFF182B41), Color(0xFF63A9FF)),
    'image': FileTone(Color(0xFF14322A), Color(0xFF43D09B)),
    'video': FileTone(Color(0xFF251F3E), Color(0xFFA78BFA)),
    'audio': FileTone(Color(0xFF2A2142), Color(0xFFBD9AF7)),
    'zip': FileTone(Color(0xFF32261A), Color(0xFFDFA845)),
    'code': FileTone(Color(0xFF122E34), Color(0xFF4EC8D8)),
    'pdf': FileTone(Color(0xFF33201F), Color(0xFFF4796C)),
    'doc': FileTone(Color(0xFF232A33), Color(0xFF9FB3CC)),
  },
  'green': {
    'folder': FileTone(Color(0xFFE6F9EF), Color(0xFF0B8A45)),
    'image': FileTone(Color(0xFFE4F5F2), Color(0xFF0D8272)),
    'video': FileTone(Color(0xFFEFE9FB), Color(0xFF6D4FD0)),
    'audio': FileTone(Color(0xFFF2ECFB), Color(0xFF7D54C9)),
    'zip': FileTone(Color(0xFFFDF3E0), Color(0xFFA56A0C)),
    'code': FileTone(Color(0xFFE4F2F5), Color(0xFF0E7F8C)),
    'pdf': FileTone(Color(0xFFFDECEA), Color(0xFFC9403A)),
    'doc': FileTone(Color(0xFFEDF1F7), Color(0xFF3D6396)),
  },
  'sepia': {
    'folder': FileTone(Color(0xFFF6E7CD), Color(0xFF96631F)),
    'image': FileTone(Color(0xFFEAF1E3), Color(0xFF4F7A3A)),
    'video': FileTone(Color(0xFFEFE6F0), Color(0xFF7B4F9B)),
    'audio': FileTone(Color(0xFFF2E9EF), Color(0xFF8A5A86)),
    'zip': FileTone(Color(0xFFF9EBD8), Color(0xFFA8620F)),
    'code': FileTone(Color(0xFFE6EEEA), Color(0xFF3F7A6A)),
    'pdf': FileTone(Color(0xFFF8E6E0), Color(0xFFB2543F)),
    'doc': FileTone(Color(0xFFEAE6F2), Color(0xFF5F5A9C)),
  },
};

/// 取某套主题下某个类型的配色；主题没登记就退回浅色蓝
FileTone typeTone(String kind, String themeId) {
  final m = kTypeToneByTheme[themeId] ?? kTypeToneByTheme['blue']!;
  return m[kind] ?? m['doc']!;
}

const Set<String> kImageExt = {
  'jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp', 'heic', 'heif', 'svg', 'tif',
  'tiff', 'avif', 'ico', 'raw', 'cr2', 'nef',
};
const Set<String> kVideoExt = {
  'mp4', 'mkv', 'avi', 'mov', 'webm', 'flv', 'ts', 'm4v', 'wmv', 'mpg', 'mpeg',
  'rmvb', '3gp',
};
const Set<String> kAudioExt = {
  'mp3', 'flac', 'm4a', 'aac', 'wav', 'ogg', 'opus', 'wma', 'ape', 'aiff',
};
const Set<String> kZipExt = {
  'zip', 'rar', '7z', 'tar', 'gz', 'bz2', 'xz', 'iso', 'apk', 'dmg', 'tgz',
};
const Set<String> kCodeExt = {
  'js', 'ts', 'dart', 'py', 'java', 'kt', 'c', 'h', 'cpp', 'go', 'rs', 'php',
  'rb', 'sh', 'json', 'xml', 'yml', 'yaml', 'html', 'css', 'sql', 'toml', 'ini',
};
const Set<String> kDocExt = {
  'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx', 'csv', 'txt', 'md', 'rtf',
  'epub', 'mobi',
};

/// 扩展名 → 分类键（folder / image / video / audio / zip / code / pdf / doc / file）
String fileKind(String name, {bool isDir = false}) {
  if (isDir) return 'folder';
  final dot = name.lastIndexOf('.');
  final ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  if (ext == 'pdf') return 'pdf';
  if (kImageExt.contains(ext)) return 'image';
  if (kVideoExt.contains(ext)) return 'video';
  if (kAudioExt.contains(ext)) return 'audio';
  if (kZipExt.contains(ext)) return 'zip';
  if (kCodeExt.contains(ext)) return 'code';
  if (kDocExt.contains(ext)) return 'doc';
  return 'file';
}

/// 分类键 → 图标名（和网页里 type-* 一致）
String fileIconName(String kind) => 'type-$kind';

/// 一行文件列表左侧的图标：彩色线稿 + 浅色圆角底
class FileTypeIcon extends StatelessWidget {
  const FileTypeIcon({super.key, required this.name, this.isDir = false, this.size = 40});

  final String name;
  final bool isDir;
  final double size;

  @override
  Widget build(BuildContext context) {
    final kind = fileKind(name, isDir: isDir);
    final t = Theme.of(context).extension<Tone>()!;
    final ft = typeTone(kind == 'folder' ? 'folder' : kind, t.id);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: ft.bg,
        borderRadius: BorderRadius.circular(size * 0.3),
      ),
      alignment: Alignment.center,
      child: AppIcon(fileIconName(kind), size: size * 0.55, color: ft.fg),
    );
  }
}

/// 数据模型 —— 字段名与服务端 pydantic 模型一致（见 /api/v1/openapi.json）。
class Entry {
  final String name;
  final String path;
  final bool isDir;
  final int size;
  final double mtime;
  final String kind;
  final String ext;

  const Entry({
    required this.name,
    required this.path,
    required this.isDir,
    required this.size,
    required this.mtime,
    required this.kind,
    required this.ext,
  });

  factory Entry.fromJson(Map<String, dynamic> j) => Entry(
        name: j['name'] as String? ?? '',
        path: j['path'] as String? ?? '/',
        isDir: j['is_dir'] as bool? ?? false,
        size: (j['size'] as num?)?.toInt() ?? 0,
        mtime: (j['mtime'] as num?)?.toDouble() ?? 0,
        kind: j['kind'] as String? ?? 'file',
        ext: j['ext'] as String? ?? '',
      );

  DateTime get when => DateTime.fromMillisecondsSinceEpoch((mtime * 1000).round());
}

class Listing {
  final String source;
  final String path;
  final String? parent;
  final List<Entry> entries;
  final bool allowUpload;
  final bool allowDelete;

  const Listing({
    required this.source,
    required this.path,
    required this.parent,
    required this.entries,
    required this.allowUpload,
    required this.allowDelete,
  });

  factory Listing.fromJson(Map<String, dynamic> j) => Listing(
        source: j['source'] as String? ?? 'nas',
        path: j['path'] as String? ?? '/',
        parent: j['parent'] as String?,
        entries: ((j['entries'] as List?) ?? const [])
            .map((e) => Entry.fromJson(e as Map<String, dynamic>))
            .toList(growable: false),
        allowUpload: j['allow_upload'] as bool? ?? false,
        allowDelete: j['allow_delete'] as bool? ?? false,
      );
}

class FsEvent {
  final String type;
  final String source;
  final String path;
  final String name;
  final String op;
  final bool isDir;
  final int seq;

  const FsEvent({
    required this.type,
    required this.source,
    required this.path,
    required this.name,
    required this.op,
    required this.isDir,
    required this.seq,
  });

  factory FsEvent.fromJson(Map<String, dynamic> j) => FsEvent(
        type: j['type'] as String? ?? '',
        source: j['source'] as String? ?? 'nas',
        path: j['path'] as String? ?? '/',
        name: j['name'] as String? ?? '',
        op: j['op'] as String? ?? '',
        isDir: j['is_dir'] as bool? ?? false,
        seq: (j['seq'] as num?)?.toInt() ?? 0,
      );

  /// 这个事件是否影响正在看的目录
}

/// 人类可读大小，与网页版一致（1024 进制，保留 1 位）
String humanSize(int bytes) {
  if (bytes <= 0) return '0 B';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  final s = v >= 100 || i == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return '$s ${units[i]}';
}

String humanTime(DateTime t) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final diff = today.difference(day).inDays;
  final hm = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  if (diff == 0) return '今天 $hm';
  if (diff == 1) return '昨天 $hm';
  if (diff < 7) return '$diff 天前';
  if (t.year == now.year) return '${t.month}月${t.day}日';
  return '${t.year}/${t.month}/${t.day}';
}

/// SRT / VTT 解析：把字幕文件变成旧版播放器用的那套 cues。
///
/// cue 结构固定为 `[start秒, end秒, 原文, 译文]`，和听译任务返回的 segments 一致，
/// 上层只认这一种，两种字幕源（同名字幕文件 / 听译）可以互换。
library;

double _sec(String t) {
  // 00:01:23,456 或 01:23.456
  final s = t.trim().replaceAll(',', '.');
  final parts = s.split(':');
  double total = 0;
  for (final p in parts) {
    total = total * 60 + (double.tryParse(p) ?? 0);
  }
  return total;
}

final _timeRe = RegExp(
  r'(\d{1,2}:\d{2}(?::\d{2})?[,.]\d{1,3})\s*-->\s*(\d{1,2}:\d{2}(?::\d{2})?[,.]\d{1,3})',
);

/// 解析成 cues。双语文件按「第一行原文、其余行译文」拆；单语文件译文留空。
///
/// 三种格式都认：SRT、WebVTT、ASS/SSA（外挂 `.ass` 和内封抽出来的都走这里）。
List<List<dynamic>> parseSubtitle(String text) {
  if (_looksAss(text)) return parseAss(text);
  final out = <List<dynamic>>[];
  final clean = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
  final blocks = clean.split(RegExp(r'\n\s*\n'));
  for (final b in blocks) {
    final lines = b
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty && !l.startsWith('WEBVTT') && !l.startsWith('NOTE'))
        .toList();
    if (lines.isEmpty) continue;
    var i = 0;
    if (int.tryParse(lines[0]) != null && lines.length > 1) i = 1;
    final m = _timeRe.firstMatch(lines[i]);
    if (m == null) continue;
    final a = _sec(m.group(1)!);
    final z = _sec(m.group(2)!);
    final body = lines.sublist(i + 1);
    if (body.isEmpty) continue;
    // 去掉 {\\an8} 这类样式标签
    final text2 = body
        .map((l) => l.replaceAll(RegExp(r'\{[^}]*\}'), '').trim())
        .where((l) => l.isNotEmpty)
        .toList();
    if (text2.isEmpty) continue;
    final orig = text2.first;
    final zh = text2.length > 1 ? text2.sublist(1).join(' ') : '';
    out.add([a, z, orig, zh]);
  }
  out.sort((x, y) => (x[0] as double).compareTo(y[0] as double));
  return out;
}

/// 目录里跟这个视频同名的字幕文件（内封之外的「外挂同名」）。
///
/// 认的写法：
///   movie.srt / movie.ass / movie.ssa / movie.vtt
///   movie.zh.srt / movie.chs.ass / movie.cht.ass / movie.zho.vtt / movie.sc.srt
/// 中文优先：有 chs/cht/zh/chi/zho/sc/tc 就用它，其次无标签的，最后是别的语言。
const _subExts = ['srt', 'ass', 'ssa', 'vtt'];

bool zhSubTag(String t) => RegExp(
  r'^(zh|zho|chi|chs|cht|sc|tc|cn|chinese|zh-hans|zh-hant|简|繁|中)',
).hasMatch(t);

String? sameNameSubtitle(String videoPath, List<String> names) {
  final base = videoPath.split('/').last;
  final dot = base.lastIndexOf('.');
  final stem = (dot > 0 ? base.substring(0, dot) : base).toLowerCase();
  String? best;
  var bestScore = -1;
  for (final n in names) {
    final ln = n.toLowerCase();
    final m = RegExp(r'\.([a-z0-9]{2,4})$').firstMatch(ln);
    if (m == null || !_subExts.contains(m.group(1))) continue;
    final body = ln.substring(0, ln.length - m.group(1)!.length - 1);
    if (body != stem && !body.startsWith('$stem.')) continue;
    final tag = body == stem ? '' : body.substring(stem.length + 1);
    final score = zhSubTag(tag) ? 30 : (tag.isEmpty ? 20 : 10);
    if (score > bestScore) {
      bestScore = score;
      best = n;
    }
  }
  return best;
}

bool _looksAss(String t) =>
    t.contains('[Script Info]') ||
    t.contains('[Events]') ||
    RegExp(r'^Dialogue\s*:', multiLine: true).hasMatch(t);

double _assSec(String v) {
  final p = v.trim().replaceAll(',', '.').split(':');
  if (p.length < 3) return 0;
  final h = double.tryParse(p[0]) ?? 0;
  final m = double.tryParse(p[1]) ?? 0;
  final sec = double.tryParse(p[2]) ?? 0;
  return h * 3600 + m * 60 + sec;
}

/// ASS/SSA：`Dialogue: 层,起,止,样式,说话人,左,右,下,效果,文本…`
List<List<dynamic>> parseAss(String text) {
  final out = <List<dynamic>>[];
  for (final raw in text.split('\n')) {
    final line = raw.trim();
    if (!line.startsWith('Dialogue:')) continue;
    final parts = line.substring(9).split(',');
    if (parts.length < 10) continue;
    final a = _assSec(parts[1]);
    final b = _assSec(parts[2]);
    var txt = parts.sublist(9).join(',');
    txt = txt
        .replaceAll(RegExp(r'\{[^}]*\}'), '')
        .replaceAll(RegExp(r'\\[Nnh]'), ' ')
        .trim();
    if (txt.isEmpty || b <= a) continue;
    out.add([a, b, txt, '']);
  }
  out.sort((x, y) => (x[0] as double).compareTo(y[0] as double));
  return out;
}

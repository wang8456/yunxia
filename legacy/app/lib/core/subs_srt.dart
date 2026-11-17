/// srt 解析：查看页和「队列里直接翻译」共用同一份，别各写一份
/// （两边解析出的句数/顺序不一致，译文就会错位到别的句子上）。
library;

/// srt 里的一句
class Cue {
  final double start;
  final double end;
  final String text;
  const Cue(this.start, this.end, this.text);

  String get stamp {
    String t(double sec) {
      final d = Duration(milliseconds: (sec * 1000).round());
      final h = d.inHours;
      final m = d.inMinutes % 60;
      final s = d.inSeconds % 60;
      return h > 0
          ? '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}'
          : '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }

    return t(start);
  }
}

/// 解析 srt：按空行切块，第二行是 `00:00:01,000 --> 00:00:03,500`
List<Cue> parseSrt(String raw) {
  final out = <Cue>[];
  final blocks = raw
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split(RegExp(r'\n\s*\n'));
  final re = RegExp(
    r'(\d+):(\d{2}):(\d{2})[,.](\d{1,3})\s*-->\s*(\d+):(\d{2}):(\d{2})[,.](\d{1,3})',
  );
  for (final b in blocks) {
    final lines = b.split('\n').where((l) => l.trim().isNotEmpty).toList();
    if (lines.isEmpty) continue;
    var ti = lines.indexWhere(re.hasMatch);
    if (ti < 0) continue;
    final m = re.firstMatch(lines[ti])!;
    double sec(int h, int mi, int s, int ms) =>
        h * 3600 + mi * 60 + s + ms / (m.group(4)!.length == 3 ? 1000 : 100);
    final st = sec(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!),
      int.parse(m.group(3)!),
      int.parse(m.group(4)!),
    );
    final en = sec(
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
      int.parse(m.group(7)!),
      int.parse(m.group(8)!),
    );
    final text = lines.sublist(ti + 1).join(' ').trim();
    if (text.isNotEmpty) out.add(Cue(st, en, text));
  }
  return out;
}

/// 字幕段的纯逻辑：合并、找当前句、挑要翻的句子、覆盖判断。
///
/// 单独放在 core 里（不引 flutter），这样能直接用单元测试跑，
/// 也能保证「拖动进度条之后字幕还对不对」这种问题有断言兜着。
///
/// 段格式和 hub 一致：`[start, end, 原文, 译文]`，start/end 是秒。
library;

typedef Cue = List<dynamic>;

double cueStart(Cue c) => (c[0] as num).toDouble();
double cueEnd(Cue c) => (c[1] as num).toDouble();
String cueText(Cue c) => (c[2] as String?) ?? '';
String cueTr(Cue c) => (c[3] as String?) ?? '';

/// 合并字幕段：同一 start（±0.01s）只留一条，优先保留带译文的、
/// 其次保留后到的（窗口重叠写回时后到的更新）。
///
/// 为什么要合并而不是替换：实时听每换一次位置就在 hub 里新开一个任务，
/// 每个任务只有自己那一段。直接替换会让「拖回去」之后前面的字幕全没了。
List<Cue> mergeCues(List<Cue> old, List<Cue> add) {
  final map = <String, Cue>{};
  void put(Cue c, {required bool newer}) {
    final key = cueStart(c).toStringAsFixed(2);
    final cur = map[key];
    if (cur == null) {
      map[key] = List<dynamic>.from(c);
      return;
    }
    final curTr = cueTr(cur).trim();
    final newTr = cueTr(c).trim();
    if (curTr.isEmpty && newTr.isNotEmpty) {
      map[key] = List<dynamic>.from(c);
      return;
    }
    if (curTr.isNotEmpty && newTr.isEmpty) return; // 别把译好的覆盖成没译的
    if (newer) map[key] = List<dynamic>.from(c);
  }

  for (final c in old) {
    put(c, newer: false);
  }
  for (final c in add) {
    put(c, newer: true);
  }
  final out = map.values.toList()
    ..sort((a, b) => cueStart(a).compareTo(cueStart(b)));
  return out;
}

/// 播放头 t 处该显示的那句（原文/译文都可能有）
Cue? cueAt(List<Cue> cues, double t, {double delay = 0}) {
  final x = t - delay;
  // 先按时间找；没命中再找「刚好在你脚下」的那句（转写有抖动时很常见）
  for (final c in cues) {
    if (x >= cueStart(c) && x < cueEnd(c)) return c;
  }
  return null;
}

/// 已经转过的区域是否覆盖 t（前后各留 pad 秒容差）
bool cuesCover(List<Cue> cues, double t, {double pad = 1.5}) {
  for (final c in cues) {
    if (t >= cueStart(c) - pad && t <= cueEnd(c) + pad) return true;
  }
  return false;
}

/// 整份重拉时把旧译文搬回新段落（按起点配对）。
///
/// 译在 App 里做，服务端的段落永远只有原文；拖动后游标归零 → 整份重拉 →
/// 直接替换会把这条任务已翻好的译文全部擦掉，用户回到前面就只看到原文。
List<Cue> keepTrByStart(List<Cue> prev, List<Cue> rows) {
  final keep = <String, String>{};
  for (final c in prev) {
    final tr = cueTr(c).trim();
    if (tr.isNotEmpty) keep[cueStart(c).toStringAsFixed(2)] = tr;
  }
  if (keep.isEmpty) return rows;
  return [
    for (final r in rows)
      if (cueTr(r).trim().isEmpty &&
          (keep[cueStart(r).toStringAsFixed(2)] ?? '').isNotEmpty)
        <dynamic>[r[0], r[1], r[2], keep[cueStart(r).toStringAsFixed(2)]]
      else
        r,
  ];
}

/// 现有字幕里最靠后的结束时间（判断「拖到没转过的地方」用）
double cuesUntil(List<Cue> cues) {
  var until = 0.0;
  for (final c in cues) {
    final b = cueEnd(c);
    if (b > until) until = b;
  }
  return until;
}

/// 拖动之后要翻哪些句子：播放头附近、还没译文的那几句。
///
/// 以前这里假设 cue 是有序的、遇到 `a > t+150` 就 break；一旦拖回去、
/// 或者两段任务的段拼在一起，break 就会漏掉真正该翻的句子。现在用
/// 排序 + continue，并且按「离播放头近」优先，回来第一句就能看到译文。
List<Cue> pickTrCandidates(
  List<Cue> cues,
  double t, {
  int max = 20,
  double back = 60,
  double fwd = 150,
}) {
  final want = <Cue>[];
  for (final c in cues) {
    final a = cueStart(c);
    if (a < t - back || a > t + fwd) continue;
    if (cueText(c).isEmpty) continue;
    if (cueTr(c).isNotEmpty) continue;
    want.add(c);
  }
  want.sort((a, b) {
    final da = (cueStart(a) - t).abs();
    final db = (cueStart(b) - t).abs();
    return da.compareTo(db);
  });
  return want.length <= max ? want : want.sublist(0, max);
}

/// 拖动之后要不要「重新开一个实时窗口」，纯判断，方便测。
///
/// - covered：当前位置已经有字幕 → 什么都不用做
/// - running：有实时任务正在转。转写工是从播放头往后推的，
///   离它当前推进点不远就等它推过来，别抢（抢一次要重排，字幕反而更慢）
/// - else：没在转（转完了/停了/根本没有）→ 位置又没覆盖，就得重开
bool shouldRestartLive({
  required double t,
  required bool covered,
  required bool running,
  required double anchor,
  required Duration since,
  Duration minGap = const Duration(seconds: 8),
  double window = 20,
  double far = 240,
}) {
  if (covered) return false;
  if (t <= 1) return false;
  if (since < minGap) return false;
  if (!running) return true;
  // 只认两种情况：播放头已经跑过转写前沿（真落后），或者拖到了很远、
  // 且那里没有字幕。**不能**用绝对值差 —— 常驻会话的正常领先就是 150 秒，
  // 绝对值差一超过 120 就把「缓冲填满」误判成「该换位置」：客户端 relocate →
  // 任务被 cancel → 状态闪「排队中」、句子被清空、画面明明有字幕还喊等字幕。
  if (t - anchor > window) return true;
  return (anchor - t) > far;
}

/// 拖到 [t] 之后，第一段「没有字幕」的位置。
///
/// 用户定的语义：落点已经有字幕就跳过，接在后面第一段空缺上，
/// 不重复转已经有的内容。句子有重叠/相接时一路往后顶。
double nextUncovered(List<List<dynamic>> cues, double t, {double tol = 1.0}) {
  if (cues.isEmpty) return t < 0 ? 0 : t;
  var cur = t < 0 ? 0.0 : t;
  final sorted = [...cues]..sort((a, b) => cueStart(a).compareTo(cueStart(b)));
  for (final c in sorted) {
    final s = cueStart(c);
    final e = cueEnd(c);
    if (e <= cur + 0.01) continue; // 这条在落点之前，跳过
    if (s > cur + tol) break; // 落点后有真实空档 → 从 cur 开始
    if (e > cur) cur = e; // 被覆盖 → 顶到句尾
  }
  return cur;
}

/// 热词：目录名 + 文件名，去掉规格标记（1080p / x265 / WEB-DL …），喂给模型当提示。
///
/// 为什么要有：研究里 B 站、夸克都做热词注入 —— 专有名词、人名、术语最容易被
/// whisper 听成别的字；把片名当提示能明显减少这类错。
String hotWordsFor(String path, String name) {
  String clean(String v) {
    var t = v.replaceAll(RegExp(r'\.[A-Za-z0-9]{2,4}$'), '');
    t = t.replaceAll(RegExp(r'[._]+'), ' ');
    t = t.replaceAll(
      RegExp(
        r'\b(1080p|720p|2160p|4k|web-?dl|webrip|bluray|bdrip|hdtv|x264|x265|h\.?264|h\.?265|hevc|avc|aac|ddp?\s?\d\.\d|10bit|8bit|remux)\b',
        caseSensitive: false,
      ),
      ' ',
    );
    t = t.replaceAll(RegExp(r'\((19|20)\d\d\)'), ' ');
    t = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t;
  }

  final nm = clean(name);
  final cut = path.lastIndexOf('/');
  final dir = cut > 0 ? clean(path.substring(0, cut).split('/').last) : '';
  final out = '${dir.isEmpty ? '' : '$dir, '}$nm';
  // 太长反而干扰（whisper 的提示词大约吃 224 token）
  return out.length > 180 ? out.substring(0, 180) : out;
}

/// 音轨语言码与音轨标签：播放设置和文件列表共用一套写法。
/// 音轨语言码（ffprobe 给的是 ISO 639-2：eng/jpn/kor/zho…）→ 中文名
const Map<String, String> kAudioLangZh = {
  'eng': '英语',
  'en': '英语',
  'chi': '国语',
  'zho': '国语',
  'cmn': '国语',
  'yue': '粤语',
  'can': '粤语',
  'kor': '韩语',
  'ko': '韩语',
  'jpn': '日语',
  'ja': '日语',
  'spa': '西语',
  'ita': '意语',
  'fre': '法语',
  'fra': '法语',
  'ger': '德语',
  'deu': '德语',
  'rus': '俄语',
  'por': '葡语',
  'tha': '泰语',
  'ara': '阿语',
  'hin': '印地语',
  'vie': '越语',
};

/// 「音轨1 · 英语 5.1」：播放设置和文件列表的队列听共用一套写法
String audioTrackLabel(Map<String, dynamic> t, int i) {
  final lang = (t['lang'] as String? ?? '').toLowerCase();
  final title = (t['title'] as String? ?? '');
  final ch = (t['ch'] as num?)?.toInt() ?? 0;
  final known = title.isNotEmpty ? title : kAudioLangZh[lang];
  final sfx = ch >= 6 ? ' 5.1' : (ch == 2 ? ' 立体声' : '');
  // 认出语言就直接写「英语 5.1」，只剩数字没法分辨（用户明确要求过）
  if (known == null || known.isEmpty) return '音轨${i + 1}$sfx';
  return '$known$sfx';
}

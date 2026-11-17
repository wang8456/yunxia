/// 听译译文语言：最常用的几种，够覆盖绝大多数片子。
/// code 和 NAS 上 hub.py 的 LANGS 保持一致。
class SubLang {
  final String code;
  final String name;
  const SubLang(this.code, this.name);
}

const List<SubLang> kSubLangs = [
  SubLang('zh', '简体中文'),
  SubLang('zh-TW', '繁體中文'),
  SubLang('en', 'English'),
  SubLang('ja', '日本語'),
  SubLang('ko', '한국어'),
  SubLang('es', 'Español'),
  SubLang('fr', 'Français'),
  SubLang('de', 'Deutsch'),
  SubLang('ru', 'Русский'),
  SubLang('pt', 'Português'),
  SubLang('it', 'Italiano'),
  SubLang('ar', 'العربية'),
  SubLang('th', 'ไทย'),
  SubLang('vi', 'Tiếng Việt'),
];

String subLangName(String code) {
  for (final l in kSubLangs) {
    if (l.code == code) return l.name;
  }
  return '简体中文';
}

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

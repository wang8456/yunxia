import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/app_state.dart';
import 'package:yunxia_app/core/session.dart';
import 'package:yunxia_app/ui/chat_page.dart';

/// 回复里的文件/图片识别：真跑一遍，不靠肉眼读正则
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  App mkApp() {
    final s = Session(server: '192.168.1.10:5007', chatBasic: 'aGVybWVzOng=');
    return App(s);
  }

  test('识别本地文件、本地图片、图片 URL、Windows 路径', () {
    final app = mkApp();
    final text = '''
报告写在 /mnt/g/hermes/云匣文件/2026-10-24/分析报告.md
截图 在 /home/administrator/.hermes/image_cache/ab12.png 
还有 https://example.com/pics/cover.jpg 这张
另外 G:\\hermes\\tools\\ffmpeg\\ffmpeg.exe 和 /tmp/a b/c.srt
连不上服务器，检查一下网络（这句里没有文件）
''';
    final f = chatAttachments(text, app);
    for (final x in f) {
      // ignore: avoid_print
      print('${x.isImage ? "IMG " : "FILE"} ${x.name}  <-  ${x.path}');
    }
    expect(f.where((x) => x.isImage).length, 2);
    expect(f.where((x) => !x.isImage).length, 3);
    final md = f.firstWhere((x) => x.name == '分析报告.md');
    expect(md.url.contains('/hermes/api/dl?path='), isTrue);
    expect(md.path, startsWith('/mnt/g/hermes/'));
    final exe = f.firstWhere((x) => x.name == 'ffmpeg.exe');
    expect(exe.path, '/mnt/g/hermes/tools/ffmpeg/ffmpeg.exe');
  });

  test('纯聊天文本不产生附件', () {
    final app = mkApp();
    final f = chatAttachments('今天几点？我在 /home/administrator 里找不到东西', app);
    expect(f, isEmpty);
  });

  test('带空格和中文的歌名能被识别成音频附件', () {
    final app = mkApp();
    const text =
        '找到了，已经放好：\n'
        'MEDIA:/mnt/g/hermes/云匣文件/2026-11-05/Being in Love - Synth Monsters 川岛三离.mp3\n'
        '直接点就能听。';
    final f = chatAttachments(text, app);
    expect(f.length, 1);
    expect(f.first.isAudio, isTrue);
    expect(f.first.isImage, isFalse);
    expect(f.first.name, 'Being in Love - Synth Monsters 川岛三离.mp3');
    expect(f.first.url.contains('/hermes/api/dl?path='), isTrue);
  });

  test('正文里只给 Windows 路径（带空格中文）也能出音频卡片', () {
    final app = mkApp();
    const text =
        '文件已经下好了，mp3 带 ID3 标签和内嵌封面，时长 3:38，242kbps，6.6MB。\n\n'
        '电脑本地：G:\\hermes\\云匣文件\\2026-11-05\\Being in Love - Synth Monsters 川岛三离.mp3\n\n'
        'NAS 云匣 5007 的「下载」目录也放了一份同名的。';
    final f = chatAttachments(text, app);
    final audio = f.where((x) => x.isAudio).toList();
    // ignore: avoid_print
    print('AUDIO ${audio.length}: ${audio.isEmpty ? "-" : audio.first.path}');
    expect(audio.length, 1);
    expect(audio.first.name, 'Being in Love - Synth Monsters 川岛三离.mp3');
    expect(audio.first.path, startsWith('/mnt/g/hermes/'));
  });
}

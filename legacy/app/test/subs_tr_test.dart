import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/subs_tr.dart';

/// 造一份 n 句的 srt
String srtOf(int n) {
  final b = StringBuffer();
  for (var i = 0; i < n; i++) {
    final s = i;
    String ts(int sec) =>
        '00:${(sec ~/ 60).toString().padLeft(2, '0')}:${(sec % 60).toString().padLeft(2, '0')},000';
    b.writeln('${i + 1}');
    b.writeln('${ts(s)} --> ${ts(s + 1)}');
    b.writeln('line $i');
    b.writeln();
  }
  return b.toString();
}

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('subs_tr_test');
  });

  tearDown(() async {
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  SubTranslator make(int n, {int batchDelayMs = 0}) => SubTranslator(
    jobId: 'job1',
    dirOverride: tmp,
    loadSrtFn: () async => srtOf(n),
    trFn: (lines, to) async {
      if (batchDelayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: batchDelayMs));
      }
      return [for (final l in lines) '[$to] $l'];
    },
  );

  test('整片翻完：逐批推进、最后绿、缓存落盘且长度对齐', () async {
    final t = make(100);
    final seen = <int>[];
    t.addListener(() {
      if (t.active) seen.add(t.pct);
    });
    await t.start('zh');
    expect(t.cues.length, 100);
    expect(t.done, isTrue);
    expect(t.busy, isFalse);
    expect(t.paused, isFalse);
    expect(t.doneCount, 100);
    expect(t.out.length, 100);
    expect(t.out.first, '[zh] line 0');
    expect(t.out.last, '[zh] line 99');
    // 100 句按 40 一批 → 40 / 80 / 100
    expect(seen, contains(40));
    expect(seen, contains(80));
    final f = File('${tmp.path}/job1_zh.json');
    expect(await f.exists(), isTrue);
    expect((await f.readAsString()).length > 10, isTrue);
  });

  test('暂停停在两批之间，恢复后接着翻，不重翻已好的', () async {
    final calls = <int>[];
    final t = SubTranslator(
      jobId: 'job2',
      dirOverride: tmp,
      loadSrtFn: () async => srtOf(120),
      trFn: (lines, to) async {
        calls.add(lines.length);
        await Future<void>.delayed(const Duration(milliseconds: 60));
        return [for (final l in lines) 'x$l'];
      },
    );
    final fut = t.start('en');
    // 等第一批开始后暂停
    await Future<void>.delayed(const Duration(milliseconds: 90));
    if (t.busy) t.pause();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(t.paused, isTrue);
    expect(t.busy, isFalse);
    expect(t.done, isFalse);
    final atPause = t.pct;
    expect(atPause, lessThan(100));

    // 暂停期间不应该继续发请求
    final before = calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(calls.length, before);

    t.resume();
    await fut;
    expect(t.done, isTrue);
    expect(t.out.where((s) => s.isEmpty).isEmpty, isTrue);
  });

  test('已有完整缓存：再次进入直接是完成态，不发请求', () async {
    var calls = 0;
    final t = SubTranslator(
      jobId: 'job3',
      dirOverride: tmp,
      loadSrtFn: () async => srtOf(10),
      trFn: (lines, to) async {
        calls++;
        return [for (final l in lines) 'y$l'];
      },
    );
    await t.start('zh');
    expect(calls, 1);
    expect(t.done, isTrue);

    final again = SubTranslator(
      jobId: 'job3',
      dirOverride: tmp,
      loadSrtFn: () async => srtOf(10),
      trFn: (lines, to) async {
        calls++;
        return [for (final l in lines) 'y$l'];
      },
    );
    expect(await again.loadCache('zh'), isTrue);
    expect(again.done, isTrue);
    expect(calls, 1); // 没有第二次请求
  });

  test('缓存长度和句数对不上就作废（换过 srt）', () async {
    await tmp.create(recursive: true);
    await File('${tmp.path}/job4_zh.json').writeAsString('["a","b"]');
    final t = SubTranslator(
      jobId: 'job4',
      dirOverride: tmp,
      loadSrtFn: () async => srtOf(5),
    );
    // 先拿到句数，再验缓存
    await t.loadCache('zh'); // cues 还没加载，长度无从比较 → 先接受
    final t2 = SubTranslator(
      jobId: 'job4',
      dirOverride: tmp,
      loadSrtFn: () async => srtOf(5),
      trFn: (lines, to) async => [for (final l in lines) 'z$l'],
    );
    await t2.start('zh'); // 加载 cues(5 句) 后跑
    expect(t2.done, isTrue);
    expect(t2.out.length, 5);
  });

  test('翻译整批失败：不拿原文冒充译文，留空并提示', () async {
    final t = SubTranslator(
      jobId: 'job5',
      dirOverride: tmp,
      loadSrtFn: () async => srtOf(45),
      trFn: (lines, to) async => throw StateError('hub 挂了'),
    );
    await t.start('zh');
    // 没翻到就是没翻到：不能写原文冒充，否则界面显示「已译完」其实全是日文
    expect(t.out.first, '');
    expect(t.done, isFalse);
    expect(t.err.isNotEmpty, isTrue);
    expect(t.audit().missing.length, 45);
  });

  test('模型拒翻（成人内容）不当译文存', () async {
    final t = SubTranslator(
      jobId: 'refuse1',
      dirOverride: tmp,
      loadSrtFn: () async => srtOf(4),
      // 按行返回：这些句子重发多少次模型都还是拒
      trFn: (lines, to) async => [
        for (final l in lines)
          l == 'line 1'
              ? '无法翻译此内容。'
              : (l == 'line 2' ? '抱歉，我无法完成这个请求' : '译:$l'),
      ],
    );
    await t.start('zh');
    expect(t.out[0], '译:line 0');
    expect(t.out[1], '');
    expect(t.out[2], '');
    expect(t.out[3], '译:line 3');
    expect(t.done, isFalse);
  });

  group('完整性检查 + 重新翻译', () {
    test('部分句子被原样退回：audit 能指出来，补翻只重发这些', () async {
      final sent = <List<String>>[];
      final t = SubTranslator(
        jobId: 'audit1',
        dirOverride: tmp,
        loadSrtFn: () async => srtOf(6),
        trFn: (lines, to) async {
          sent.add(List.of(lines));
          // 第一次故意把中间两句原样退回
          if (sent.length == 1) {
            return [
              for (final l in lines)
                (l == 'line 2' || l == 'line 4') ? l : '[$to] $l',
            ];
          }
          return [for (final l in lines) '[$to] $l'];
        },
      );
      await t.start('ja');
      final a = t.audit();
      expect(a.total, 6);
      expect(a.missing.length, 2);
      expect(a.sameAsSource.length, 2);
      expect(a.complete, isFalse);
      expect(a.summary.contains('2 句仍是原文'), isTrue);

      await t.redo(); // 只补没译的
      expect(sent.length, 2);
      expect(sent.last, ['line 2', 'line 4']);
      expect(t.audit().complete, isTrue);
      expect(t.out[2], '[ja] line 2');
    });

    test('全部重翻：所有句子都会重新发一遍', () async {
      final sent = <int>[];
      final t = SubTranslator(
        jobId: 'audit2',
        dirOverride: tmp,
        loadSrtFn: () async => srtOf(50),
        trFn: (lines, to) async {
          sent.add(lines.length);
          return [for (final l in lines) '[$to] $l'];
        },
      );
      await t.start('de');
      expect(t.audit().complete, isTrue);
      await t.redo(all: true);
      expect(sent, [40, 10, 40, 10]); // 两轮各 40+10
      expect(t.done, isTrue);
    });

    test('空字符串算没译', () async {
      final t = SubTranslator(
        jobId: 'audit3',
        dirOverride: tmp,
        loadSrtFn: () async => srtOf(3),
        trFn: (lines, to) async => [for (final l in lines) l == 'line 1' ? '' : 'x'],
      );
      await t.start('zh');
      final a = t.audit();
      // 空返回就留空（以前会拿原文兜底，看着像「译好了」）
      expect(a.missing.length, 1);
      expect(a.empty.length, 1);
      expect(a.sameAsSource, isEmpty);
      expect(a.ok, 2);
    });
  });

  test('退出页面（没人监听）也照常翻完并落盘', () async {
    final t = SubTranslator(
      jobId: 'leave1',
      dirOverride: tmp,
      loadSrtFn: () async => srtOf(80),
      trFn: (lines, to) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return [for (final l in lines) '[$to] $l'];
      },
    );
    var hits = 0;
    void listener() => hits++;
    t.addListener(listener);
    final fut = t.start('zh');
    // 模拟「退出去看别的页面」：监听摘掉，但任务不 cancel
    t.removeListener(listener);
    final before = hits;
    await fut;
    expect(hits, before); // 摘掉之后不再回调（页面已经不在）
    expect(t.done, isTrue);
    expect(await File('${tmp.path}/leave1_zh.json').exists(), isTrue);
  });
}

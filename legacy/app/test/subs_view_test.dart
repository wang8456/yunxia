import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/subs_srt.dart';

/// 用真实任务的 srt（从 /api/v1/subs/<id>/srt 抓的）验证解析，
/// 不是拿手写的几行糊弄。
void main() {
  test('真实 srt 解析：句数、首句、时间戳', () {
    final raw = File('test/fixtures/real.srt').readAsStringSync();
    final cues = parseSrt(raw);

    expect(cues.length, 337); // grep -c "-->" 实数
    expect(cues.first.text, 'You');
    expect(cues.first.start, 0);
    expect(cues.first.end, 2);
    expect(cues.first.stamp, '00:00');
    expect(cues[1].text, 'Oh!');
    expect(cues[1].start, 30);

    // 这一集 46 分钟，最靠后的一句应该超过 40 分钟
    expect(cues.last.start, greaterThan(2400));
  });

  test('Windows 换行 + 无序号也能认', () {
    const srt = '1\r\n00:00:01,500 --> 00:00:03,000\r\n第一句\r\n\r\n'
        '00:00:04,000 --> 00:00:05,500\r\n第二句\r\n第二行\r\n';
    final cues = parseSrt(srt);
    expect(cues.length, 2);
    expect(cues.first.start, 1.5);
    expect(cues.first.text, '第一句');
    expect(cues.last.end, 5.5);
    expect(cues.last.text, '第二句 第二行');

    // 超过一小时的片子：时间戳要 hh:mm:ss
    final long = parseSrt('1\n01:05:03,200 --> 01:05:04,000\n晚一点\n');
    expect(long.single.stamp, '01:05:03');
  });

  test('空内容 / 只有头部不炸', () {
    expect(parseSrt(''), isEmpty);
    expect(parseSrt('WEBVTT\n\n'), isEmpty);
  });
}

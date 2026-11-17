import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/ui/subs_monitor.dart';

SubJob job({
  String state = 'asr',
  bool live = false,
  bool relocating = false,
  double doneUntil = 0,
}) => SubJob.from({
  'id': 'x',
  'name': 'a.mp4',
  'state': state,
  'live': live,
  'relocating': relocating,
  'done_until': doneUntil,
});

void main() {
  group('实时听状态措辞 hudLabel', () {
    test('换位置中不能说成已停止', () {
      final j = job(state: 'cancelled', live: true, relocating: true);
      expect(j.hudLabel, '换位置中');
      // 换位置要算「在转」，否则播放页会把轮询停掉
      expect(j.running, isTrue);
    });

    test('这一窗转完说本窗已转完，不说整片已转好', () {
      expect(job(state: 'done', live: true).hudLabel, '本窗已转完');
    });

    test('真的停了才是已停止', () {
      final j = job(state: 'cancelled', live: false);
      expect(j.hudLabel, '已停止');
      expect(j.running, isFalse);
    });

    test('排队/转写照常', () {
      expect(job(state: 'queued', live: true).hudLabel, '排队中');
      expect(job(state: 'asr', live: true).hudLabel, '转写中');
    });

    test('整片队列听的面板措辞不受影响', () {
      expect(job(state: 'asr').hudLabel, '转写中');
      expect(job(state: 'done').hudLabel, '已转好');
      expect(job(state: 'cancelled').hudLabel, '已停止');
    });

    test('doneUntil 能给到「已转至」用的时间', () {
      final j = job(state: 'asr', live: true, doneUntil: 192);
      expect(j.doneLabel, '03:12');
    });
  });
}

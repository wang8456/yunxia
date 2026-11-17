import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/ui/subs_monitor.dart';

/// 「实时听」和「队列听」是两条路：停了之后 live 会变 false，
/// 界面必须靠 mode 分清，否则实时听跑完的片子会显示成「队列听 · 整片已转好」。
void main() {
  Map<String, dynamic> row({
    String mode = 'queue',
    bool live = false,
    int segs = 12,
    String state = 'done',
  }) => {
    'id': 'x',
    'name': '我的事说来话长.E01',
    'state': state,
    'live': live,
    'mode': mode,
    'segments': segs,
    'done_until': 1513.4,
  };

  test('实时听跑完（live=false、mode=live）仍算实时听', () {
    final j = SubJob.from(row(mode: 'live', live: false, segs: 36));
    expect(j.fromLive, isTrue);
    expect(j.live, isFalse);
    expect(j.segments, 36);
  });

  test('队列听不会被当成实时听', () {
    final j = SubJob.from(row(mode: 'queue'));
    expect(j.fromLive, isFalse);
  });

  test('老服务端没有 mode 字段时看 live', () {
    final m = row(mode: 'x')..remove('mode');
    expect(SubJob.from({...m, 'live': true}).fromLive, isTrue);
    expect(SubJob.from({...m, 'live': false}).fromLive, isFalse);
  });
}

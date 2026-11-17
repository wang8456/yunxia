import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/tr_bus.dart';

void main() {
  test('实时标记正常释放后队列立刻继续', () async {
    TrBus.reset();
    TrBus.beginLive();
    TrBus.endLive();
    final t0 = DateTime.now();
    await TrBus.waitForQueue(() => false);
    expect(DateTime.now().difference(t0).inMilliseconds, lessThan(500));
  });

  test('实时标记泄漏时不会把队列翻译卡死', () async {
    TrBus.reset();
    TrBus.livePatience = const Duration(milliseconds: 300);
    TrBus.beginLive(); // 谁也没 endLive（切后台/被系统杀掉那种）
    final t0 = DateTime.now();
    await TrBus.waitForQueue(() => false);
    final ms = DateTime.now().difference(t0).inMilliseconds;
    expect(ms, greaterThanOrEqualTo(250));
    expect(ms, lessThan(3000));
    expect(TrBus.liveActive, isFalse, reason: '泄漏的标记要自己清掉');
  });

  test('暂停时立刻返回，不等实时结束', () async {
    TrBus.reset();
    TrBus.livePatience = const Duration(seconds: 30);
    TrBus.beginLive();
    final t0 = DateTime.now();
    await TrBus.waitForQueue(() => true);
    expect(DateTime.now().difference(t0).inMilliseconds, lessThan(500));
  });
}

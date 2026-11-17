import 'dart:async';
import 'dart:io';

/// 翻译总线：**实时翻译优先，队列翻译让位**。
///
/// 为什么需要：翻译现在全在 App 里做（服务端 /tr 已退役）。实时翻译跟着
/// 播放走，要求几百毫秒级；队列翻译是整片几十分钟的活。两者一起跑会互相
/// 抢 API 配额和上行带宽 —— 用户看到的正是「一边看一边翻，中文半天不来」。
///
/// 规则（和「一旦有实时听，所有队列听暂停」同一条规矩，延伸到翻译层）：
/// - 播放器里开了实时翻译 → `beginLive()`，队列翻译在批次之间挂起
/// - 播放器关掉/关译文 → `endLive()`，队列翻译自动接着跑
/// - 全局并发上限 2（实时自己就能吃满 2，队列在实时活跃时拿 0）
class TrBus {
  TrBus._();

  static int _live = 0;
  static int _queueBusy = 0;
  static const int maxConcurrent = 2;

  /// 实时标记是什么时候亮的。播放器切后台/被系统杀掉时 endLive 可能没跑到，
  /// 标记一旦泄漏，队列翻译就会永远卡在同一批（用户看到的就是「译文 93%、
  /// 一直翻译中、点一下变暂停」）。所以给它一个上限：等太久就放行。
  static DateTime _liveSince = DateTime.fromMillisecondsSinceEpoch(0);
  static Duration livePatience = const Duration(minutes: 3);  // 测试里可以调小

  static bool get liveActive => _live > 0;
  static int get queueBusy => _queueBusy;
  static int get liveSessions => _live;

  static void beginLive() {
    if (_live == 0) _liveSince = DateTime.now();
    _live++;
  }

  /// 进程内状态复位（播放器异常退出、切后台没走 dispose 时用）
  static void reset() {
    _live = 0;
    _queueBusy = 0;
  }

  static void endLive() {
    if (_live > 0) _live--;
  }

  /// 队列翻译在每一批之前调用：实时翻译活着就一直等（200ms 一轮）。
  /// [paused] 由调用方传进来，用户暂停队列翻译时立刻返回，别卡死。
  static Future<void> waitForQueue(bool Function() paused) async {
    final t0 = DateTime.now();
    while (_live > 0) {
      if (paused()) return;
      // 兜底：实时标记亮了超过 livePatience 还没收，说明它泄漏了
      // （切后台 / 页面被系统回收）。一直等下去 = 队列翻译永远卡住。
      final waited = DateTime.now().difference(t0);
      final liveAge = DateTime.now().difference(_liveSince);
      if (waited > livePatience || liveAge > livePatience * 4) {
        _live = 0;
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
  }

  static void queueEnter() {
    _queueBusy++;
  }

  static void queueExit() {
    if (_queueBusy > 0) _queueBusy--;
  }
}

/// 翻译延迟埋点：每批「发出去 → 回来」写一行，便于判断慢在请求还是排队。
/// 只在播放时写，文件很小（一小时约几百行），退出播放器不清理（诊断用）。
void trLatencyLog(int lines, int ms) {
  try {
    final d = Directory('${Directory.systemTemp.parent.path}/files');
    if (!d.existsSync()) return;
    File('${d.path}/tr_latency.jsonl')
        .writeAsStringSync(
          '${DateTime.now().toIso8601String()} lines=$lines ms=$ms\n',
          mode: FileMode.append,
          flush: false,
        );
  } catch (_) {}
}

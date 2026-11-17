/// 磁力 / ed2k 的一条任务（服务端已归一化）。
/// 一条下载任务（磁力或 ed2k，服务端已归一化）
class DlTask {
  final String id;
  final String kind;
  final String name;
  final int size;
  final double pct;
  final int speed;
  final String state;
  final String error;

  /// 服务器上的落盘路径（下载完能顺着它进云匣）
  final String path;
  final String targetName;

  const DlTask({
    required this.id,
    required this.kind,
    required this.name,
    required this.size,
    required this.pct,
    required this.speed,
    required this.state,
    required this.error,
    this.path = '',
    this.targetName = '',
  });

  factory DlTask.fromJson(Map<String, dynamic> j) => DlTask(
        id: j['id'] as String? ?? '',
        kind: j['kind'] as String? ?? 'magnet',
        name: j['name'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        pct: (j['pct'] as num?)?.toDouble() ?? 0,
        speed: (j['speed'] as num?)?.toInt() ?? 0,
        state: j['state'] as String? ?? '',
        error: j['error'] as String? ?? '',
        path: j['path'] as String? ?? '',
        targetName: j['target_name'] as String? ?? '',
      );

  String get stateLabel {
    // aMule 回的是 Waiting / Downloading，别只认小写
    switch (state.toLowerCase()) {
      case 'active':
        return '下载中';
      case 'waiting':
        return '等待中';
      case 'complete':
        return '已完成';
      case 'paused':
        return '已暂停';
      case 'error':
        return '出错';
      default:
        return state.isEmpty ? '等待中' : state;
    }
  }

  bool get running =>
      const {'active', 'waiting', 'downloading'}.contains(state.toLowerCase());
  bool get paused => state.toLowerCase().contains('pause');
  bool get done => pct >= 100 || state.toLowerCase().contains('complete');
}

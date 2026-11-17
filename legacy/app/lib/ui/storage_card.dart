import 'package:flutter/material.dart';

import '../core/tokens.dart';
import '../core/ui_icons.dart';

/// 首页「我的储存」卡：环形占比 + 体积最大的几类 + 容量小色块。
/// 平板/宽屏（>=620）改成三栏：环 / 2×2 指标 / 占空间最多的文件夹。
/// 数据来自 `/meta/storage/analysis`（服务端异步扫描 + 6 小时缓存）。
class StorageCard extends StatelessWidget {
  final Map<String, dynamic>? ana;
  final String? err;
  final VoidCallback onRefresh;

  const StorageCard({super.key, required this.ana, required this.onRefresh, this.err});


  static const Map<String, String> _kindName = {
    'video': '视频',
    'image': '图片',
    'audio': '音频',
    'doc': '文档',
    'archive': '压缩包',
    'code': '代码',
    'other': '其他',
  };

  /// 与文件列表的配色同一套（browse_page 的 _FileRow）
  static const Map<String, Color> _kindColor = {
    'video': Color(0xFF7C5CF0),
    'image': Color(0xFF0E9D78),
    'audio': Color(0xFF8859DC),
    'doc': Color(0xFF287BE8),
    'archive': Color(0xFFC78218),
    'code': Color(0xFF0E8F80),
    'other': Color(0xFF5B6B82),
  };

  static String fmtBytes(num? n) {
    final v = (n ?? 0).toDouble();
    if (v <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB', 'TB'];
    var x = v;
    var i = 0;
    while (x >= 1024 && i < units.length - 1) {
      x /= 1024;
      i++;
    }
    final text = (x >= 100 || i == 0) ? x.round().toString() : x.toStringAsFixed(1);
    return '$text ${units[i]}';
  }

  /// 体积最大的三类 + 剩下合成「其他」
  List<Map<String, dynamic>> _kpis(List<Map<String, dynamic>> kinds) {
    final rows = [...kinds]
      ..sort((a, b) => ((b['bytes'] as num?) ?? 0).compareTo(((a['bytes'] as num?) ?? 0)));
    if (rows.isEmpty) return [];
    final head = rows.take(3).map((k) {
      final kind = (k['kind'] as String?) ?? 'other';
      return <String, dynamic>{
        'kind': kind,
        'bytes': k['bytes'],
        'label': '${_kindName[kind] ?? kind} ${(k['count'] as num?)?.toInt() ?? 0}',
        'color': _kindColor[kind] ?? const Color(0xFF5B6B82),
      };
    }).toList();
    final tail = rows.skip(3).toList();
    if (tail.isNotEmpty) {
      head.add(<String, dynamic>{
        'kind': 'rest',
        'bytes': tail.fold<num>(0, (s, k) => s + (((k['bytes'] as num?) ?? 0))),
        'label':
            '其他 ${tail.fold<int>(0, (s, k) => s + (((k['count'] as num?) ?? 0).toInt()))}',
        'color': const Color(0xFF5B6B82),
      });
    }
    return head;
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final disk = (ana?['disk'] as Map?)?.cast<String, dynamic>();
    final scan = (ana?['scan'] as Map?)?.cast<String, dynamic>();
    final scanning = ana?['scanning'] == true;
    final name = (ana?['name'] as String?) ?? '正在读取…';
    final note = (ana?['note'] as String?) ?? '';

    final total = (disk?['total'] as num?)?.toDouble() ?? 0;
    final used = (disk?['used'] as num?)?.toDouble() ?? 0;
    final free = (disk?['free'] as num?)?.toDouble() ?? 0;
    final filesBytes = (scan?['bytes'] as num?)?.toDouble() ?? 0;
    final pct = total > 0 ? (used / total).clamp(0.0, 1.0) : 0.0;
    final rest = (used - filesBytes) > 0 ? used - filesBytes : 0.0;

    final kinds = ((scan?['by_kind'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .where((k) => ((k['count'] as num?) ?? 0) > 0)
        .toList();
    final kpis = _kpis(kinds);
    final dirs = ((scan?['top_dirs'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .take(3)
        .toList();

    final children = <Widget>[
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('我的储存',
                    style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.15,
                        color: tone.ink)),
                const SizedBox(height: 3),
                Text(name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: tone.ink3)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          GestureDetector(
            onTap: onRefresh,
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: tone.surface2,
                borderRadius: BorderRadius.circular(9),
                border: Border.all(color: tone.line2),
              ),
              alignment: Alignment.center,
              child: scanning
                  ? SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.6, color: tone.ink3),
                    )
                  : UIIcon('refresh', size: 15, color: const Color(0xFF7D8B9C)),
            ),
          ),
        ],
      ),
    ];

    if (disk != null) {
      children.add(const SizedBox(height: 16));
      children.add(LayoutBuilder(
        builder: (context, c) {
          final wide = c.maxWidth >= 620;
          if (!wide) {
            return Row(
              children: [
                _ring(tone, pct, 124),
                const SizedBox(width: 18),
                Expanded(child: _kpiColumn(tone, kpis)),
              ],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _ring(tone, pct, 148),
              const SizedBox(width: 24),
              Expanded(child: _kpiGrid(tone, kpis)),
              if (dirs.isNotEmpty) ...[
                const SizedBox(width: 22),
                Container(width: 1, height: 96, color: tone.line2),
                const SizedBox(width: 22),
                SizedBox(width: 210, child: _dirsColumn(tone, dirs)),
              ],
            ],
          );
        },
      ));

      // 容量小色块
      children.add(const SizedBox(height: 16));
      children.add(Container(height: 1, color: tone.line2));
      children.add(const SizedBox(height: 14));
      children.add(LayoutBuilder(
        builder: (context, c) {
          final items = <Widget>[
            _chip(tone, '已用', fmtBytes(used), tone.ac),
            _chip(tone, '可用', fmtBytes(free), tone.line),
            _chip(tone, '总容量', fmtBytes(total), null),
            _chip(tone, '文件', '${(scan?['files'] as num?)?.toInt() ?? 0}', null),
          ];
          if (c.maxWidth < 620) {
            return Wrap(spacing: 7, runSpacing: 7, children: items);
          }
          // 宽屏与网页端一致：四等分铺满，内容居中
          final filled = <Widget>[
            _chip(tone, '已用', fmtBytes(used), tone.ac, fill: true),
            _chip(tone, '可用', fmtBytes(free), tone.line, fill: true),
            _chip(tone, '总容量', fmtBytes(total), null, fill: true),
            _chip(tone, '文件', '${(scan?['files'] as num?)?.toInt() ?? 0}', null, fill: true),
          ];
          return Row(
            children: [
              for (var i = 0; i < filled.length; i++) ...[
                if (i > 0) const SizedBox(width: 8),
                Expanded(child: filled[i]),
              ],
            ],
          );
        },
      ));

      if (rest > 0) {
        children.add(const SizedBox(height: 12));
        children.add(Text(
          '其余 ${fmtBytes(rest)} 为系统与容器占用${scanning ? ' · 正在统计…' : ''}',
          style: TextStyle(fontSize: 11.5, color: tone.ink3),
        ));
      }
    } else if (ana != null) {
      children.add(const SizedBox(height: 10));
      children.add(Text(note.isEmpty ? '这个来源不统计磁盘占用' : note,
          style: TextStyle(fontSize: 12.5, color: tone.ink3)));
    } else if (err != null) {
      children.add(const SizedBox(height: 10));
      children.add(Text(err!, style: TextStyle(fontSize: 12.5, color: tone.ink3)));
    } else {
      children.add(const SizedBox(height: 12));
      children.add(Text('正在读取…', style: TextStyle(fontSize: 11.5, color: tone.ink3)));
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: tone.surface,
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [
          BoxShadow(
              color: Color(0x1A111827),
              blurRadius: 24,
              offset: Offset(0, 8),
              spreadRadius: -18),
          BoxShadow(color: Color(0x08111827), blurRadius: 1, offset: Offset(0, 1)),
        ],
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }

  /// 环：中间百分比
  Widget _ring(Tone tone, double pct, double size) {
    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: pct,
              strokeWidth: 13,
              strokeCap: StrokeCap.round,
              backgroundColor: tone.line2,
              valueColor: AlwaysStoppedAnimation<Color>(tone.ac),
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${(pct * 100).round()}%',
                  style: TextStyle(
                      fontSize: size > 130 ? 26 : 22,
                      height: 1.1,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.8,
                      color: tone.ink)),
              const SizedBox(height: 1),
              Text('已用', style: TextStyle(fontSize: 11, color: tone.ink3)),
            ],
          ),
        ],
      ),
    );
  }

  /// 手机：竖排，数值左、名字右
  Widget _kpiColumn(Tone tone, List<Map<String, dynamic>> kpis) {
    if (kpis.isEmpty) {
      return Text('这个来源里还没有文件', style: TextStyle(fontSize: 12.5, color: tone.ink3));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < kpis.length; i++) ...[
          if (i > 0) const SizedBox(height: 11),
          Row(
            children: [
              _dot(kpis[i]['color'] as Color),
              const SizedBox(width: 6),
              Text(fmtBytes(kpis[i]['bytes'] as num?),
                  style: TextStyle(
                      fontSize: 14.5,
                      fontWeight: FontWeight.w600,
                      letterSpacing: -0.2,
                      color: tone.ink)),
              const SizedBox(width: 8),
              Expanded(
                child: Text('${kpis[i]['label']}',
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: tone.ink3)),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// 宽屏：2×2，名字在上、数值在下
  Widget _kpiGrid(Tone tone, List<Map<String, dynamic>> kpis) {
    if (kpis.isEmpty) {
      return Text('这个来源里还没有文件', style: TextStyle(fontSize: 12.5, color: tone.ink3));
    }
    final cells = [
      for (final k in kpis)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _dot(k['color'] as Color),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text('${k['label']}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: tone.ink3)),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Padding(
                padding: const EdgeInsets.only(left: 14),
                child: Text(fmtBytes(k['bytes'] as num?),
                    style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.2,
                        color: tone.ink)),
              ),
            ],
          ),
        ),
    ];
    return Column(
      children: [
        for (var i = 0; i < cells.length; i += 2)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: cells[i]),
              const SizedBox(width: 26),
              Expanded(child: i + 1 < cells.length ? cells[i + 1] : const SizedBox()),
            ],
          ),
      ],
    );
  }

  /// 宽屏右栏：占空间最多的三个文件夹
  Widget _dirsColumn(Tone tone, List<Map<String, dynamic>> dirs) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('占空间最多',
            style: TextStyle(fontSize: 11.5, color: tone.ink3, letterSpacing: 0.2)),
        const SizedBox(height: 9),
        for (final d in dirs)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                Expanded(
                  child: Text('${d['name'] ?? ''}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12.5, color: Color(0xFF3A4757))),
                ),
                const SizedBox(width: 10),
                Text(fmtBytes(d['bytes'] as num?),
                    style: TextStyle(fontSize: 12, color: tone.ink3)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _dot(Color color) => Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
      );

  /// 容量小色块：label 灰、值深；给了 color 才有左侧小方块。
  /// fill=true 时铺满可用宽度、内容居中（宽屏用，和网页端一致）。
  Widget _chip(Tone tone, String label, String value, Color? color, {bool fill = false}) {
    final inner = Row(
      mainAxisSize: fill ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: fill ? MainAxisAlignment.center : MainAxisAlignment.start,
      children: [
        if (color != null) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
          ),
          const SizedBox(width: 6),
        ],
        Text(label, style: TextStyle(fontSize: 12, color: tone.ink3)),
        const SizedBox(width: 6),
        Text(value,
            style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600, color: tone.ink)),
      ],
    );
    return Container(
      width: fill ? double.infinity : null,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: tone.surface2, borderRadius: BorderRadius.circular(9)),
      child: inner,
    );
  }
}

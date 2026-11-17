import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'widgets.dart';

/// 听译设置 —— 对齐旧版前端设置页的「听译」分组：
/// 实时听译（开/关）、识别精度（高质量/快速）、听译服务地址。
class SubsSettingsPage extends StatefulWidget {
  final App app;
  const SubsSettingsPage({super.key, required this.app});

  @override
  State<SubsSettingsPage> createState() => _SubsSettingsPageState();
}

class _SubsSettingsPageState extends State<SubsSettingsPage> {
  App get app => widget.app;

  String _hub = '';
  int _max = 1;
  int _active = 0;
  int _jobs = 0;
  bool _online = false;
  bool _loading = true;
  String _err = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await app.api.subsConfig();
      if (!mounted) return;
      setState(() {
        _hub = (r['hub'] as String?) ?? '';
        _max = (r['max_active'] as num?)?.toInt() ?? 1;
        _active = (r['active'] as num?)?.toInt() ?? 0;
        _jobs = (r['jobs'] as num?)?.toInt() ?? 0;
        _online = r['online'] == true;
        _loading = false;
        _err = (r['error'] as String?) ?? '';
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _err = '$e';
        });
      }
    }
  }

  static (String, bool, VoidCallback) _item(
          String label, bool on, VoidCallback tap) =>
      (label, on, tap);

  Widget _seg(List<(String, bool, VoidCallback)> items) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (label, on, tap) in items) ...[
            GestureDetector(
              onTap: tap,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                decoration: BoxDecoration(
                  color: on
                      ? Theme.of(context).extension<Tone>()!.ac
                      : Theme.of(context).extension<Tone>()!.surface2,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: on
                        ? Colors.white
                        : Theme.of(context).extension<Tone>()!.ink2,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
        ],
      );

  Widget _row({
    required String icon,
    required Color bg,
    required Color fg,
    required String title,
    String? sub,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final tone = Theme.of(context).extension<Tone>()!;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
        child: Row(
          children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(11),
              ),
              alignment: Alignment.center,
              child: UIIcon(icon, size: 18, color: fg),
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: tone.ink)),
                  if (sub != null) ...[
                    const SizedBox(height: 2),
                    Text(sub,
                        style: TextStyle(fontSize: 11.5, color: tone.ink3)),
                  ],
                ],
              ),
            ),
            if (trailing != null) trailing,
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
    final s = app.session;

    return Scaffold(
      backgroundColor: tone.bg,
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 40),
          children: [
            Row(
              children: [
                Press(
                  onTap: () => Navigator.pop(context),
                  scale: 0.94,
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: UIIcon('arrow-left', size: 22, color: tone.ink),
                  ),
                ),
                const SizedBox(width: 4),
                Text('听设置',
                    style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: tone.ink)),
              ],
            ),
            const SizedBox(height: 14),
            SurfaceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _row(
                    icon: 'translate',
                    bg: const Color(0xFFEAF7F0),
                    fg: const Color(0xFF0D9C7A),
                    title: '播放时实时听',
                    sub: s.subLive ? '边播边出 · 只转播放位置之后' : '整片转完再出',
                    trailing: _seg([
                      ('开', s.subLive, () {
                        setState(() => s.subLive = true);
                        s.save();
                      }),
                      ('关', !s.subLive, () {
                        setState(() => s.subLive = false);
                        s.save();
                      }),
                    ]),
                  ),
                  Divider(height: 1, color: tone.line),
                  _row(
                    icon: 'speed',
                    bg: const Color(0xFFEFEAFF),
                    fg: const Color(0xFF7C5CF0),
                    title: '识别精度',
                    sub: s.subModel == 'turbo' ? '高质量 · 慢一些' : '快速 · 先出字幕',
                    trailing: _seg([
                      ('高质量', s.subModel == 'turbo', () {
                        setState(() => s.subModel = 'turbo');
                        s.save();
                      }),
                      ('快速', s.subModel == 'small', () {
                        setState(() => s.subModel = 'small');
                        s.save();
                      }),
                    ]),
                  ),
                  Divider(height: 1, color: tone.line),
                  _row(
                    icon: 'playlist',
                    bg: const Color(0xFFE8F2FF),
                    fg: const Color(0xFF1677F8),
                    title: '同时转写',
                    sub: _loading ? '读取中…' : '现在 ${_active} 个在跑 / 上限 $_max',
                    trailing: _seg([
                      for (final n in const [1, 2, 3])
                        _item('$n', _max == n, () async {
                          try {
                            await app.api.subsSetMax(n);
                            await _load();
                            app.toast('同时转写 $n 个');
                          } catch (e) {
                            app.toast('设置失败：$e');
                          }
                        }),
                    ]),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SurfaceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _row(
                    icon: 'link',
                    bg: const Color(0xFFE6F6FB),
                    fg: const Color(0xFF0E8EA3),
                    title: '听服务地址',
                    sub: _loading
                        ? '读取中…'
                        : (_hub.isEmpty
                            ? (_err.isEmpty ? '未知' : _err)
                            : '$_hub（自动）'),
                    trailing: _loading
                        ? null
                        : Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 9, vertical: 4),
                            decoration: BoxDecoration(
                              color: _online
                                  ? const Color(0xFFE5F8EF)
                                  : const Color(0xFFFFF0EE),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Text(
                              _online ? '在线' : '离线',
                              style: TextStyle(
                                fontSize: 11.5,
                                fontWeight: FontWeight.w600,
                                color: _online
                                    ? const Color(0xFF0E9D78)
                                    : const Color(0xFFE45E53),
                              ),
                            ),
                          ),
                  ),
                  Divider(height: 1, color: tone.line),
                  _row(
                    icon: 'refresh',
                    bg: tone.icobg,
                    fg: tone.ac,
                    title: '刷新状态',
                    sub: _loading ? '' : '共 $_jobs 个字幕任务',
                    onTap: () {
                      setState(() => _loading = true);
                      _load();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '听 = 把话音转成字幕，在 NAS 上排队、真正吃 CPU 的转写在电脑上的 worker 里跑。'
                '译 = 播放时按画面实时翻，不排队、不预翻整片，看哪段翻哪段。'
                '精度选「快速」先出粗字幕，选「高质量」更准但慢；同时上限调高会更占 CPU。',
                style: TextStyle(fontSize: 11.5, height: 1.7, color: tone.ink3),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

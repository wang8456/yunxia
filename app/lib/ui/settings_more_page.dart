import 'dart:io';

import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/native.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'kit.dart';
import 'widgets.dart';

/// 「更多」——设置页原来把连接检测/清理缓存/亮度权限/安装权限/关于
/// 全摊在主列表里，一屏装不下。现在收进这一页，主列表只留一行入口。
class SettingsMorePage extends StatefulWidget {
  final App app;
  const SettingsMorePage({super.key, required this.app});

  @override
  State<SettingsMorePage> createState() => _SettingsMorePageState();
}

class _SettingsMorePageState extends State<SettingsMorePage> {
  App get app => widget.app;

  @override
  Widget build(BuildContext context) {
    final tone = Theme.of(context).extension<Tone>()!;
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
                Text('更多',
                    style: TextStyle(
                        fontSize: 19,
                        fontWeight: FontWeight.w700,
                        color: tone.ink)),
              ],
            ),
            const SizedBox(height: 12),
            GroupCard(
              children: [
                KitRow(
                  icon: 'refresh',
                  iconBg: tone.icobg,
                  iconColor: tone.ac,
                  title: '连接检测',
                  sub: '打一次 /healthz，看通不通',
                  trailing: UIIcon('chevron-right',
                      size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                  onTap: () async {
                    final t0 = DateTime.now();
                    try {
                      final r = await app.api.healthz();
                      final ms = DateTime.now().difference(t0).inMilliseconds;
                      app.toast('通 · ${ms}ms · 服务端 ${r['version'] ?? '?'}');
                    } catch (e) {
                      app.toast('不通：$e');
                    }
                  },
                ),
                KitRow(
                  icon: 'trash',
                  iconBg: const Color(0xFFFFF0EE),
                  iconColor: const Color(0xFFE45E53),
                  title: '清理缓存',
                  sub: '清掉下载临时文件',
                  trailing: UIIcon('chevron-right',
                      size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                  onTap: () async {
                    final ok = await showConfirmSheet(context,
                        title: '清理缓存',
                        text: '只会删掉下载过程中的临时文件，已存到「下载/云匣」的文件不动。');
                    if (ok != true) return;
                    try {
                      final dir = Directory('${Directory.systemTemp.path}/dl');
                      var n = 0;
                      var bytes = 0;
                      if (dir.existsSync()) {
                        for (final f in dir.listSync()) {
                          if (f is File) {
                            bytes += f.lengthSync();
                            f.deleteSync();
                            n++;
                          }
                        }
                      }
                      final mb = (bytes / 1024 / 1024).toStringAsFixed(1);
                      app.toast(n == 0 ? '没有要清的' : '清掉 $n 个文件 · $mb MB');
                    } catch (e) {
                      app.toast('清理失败：$e');
                    }
                  },
                ),
                KitRow(
                  icon: 'setting',
                  iconBg: const Color(0xFFFFF3DF),
                  iconColor: const Color(0xFFC78218),
                  title: '系统亮度权限',
                  sub: '播放器左滑要改系统亮度，得先允许「修改系统设置」',
                  trailing: UIIcon('chevron-right',
                      size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                  onTap: () async {
                    await Native.openWriteSettings();
                    app.toast('把「允许修改系统设置」打开，播放器就能改系统亮度');
                  },
                ),
                KitRow(
                  icon: 'download',
                  iconBg: const Color(0xFFE8F2FF),
                  iconColor: const Color(0xFF1677F8),
                  title: '安装权限',
                  sub: '装 APK 要开「安装未知应用」，点这里跳系统开关',
                  trailing: UIIcon('chevron-right',
                      size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                  onTap: () async {
                    final ok = await Native.canInstall();
                    if (ok) {
                      app.toast('已授权，可以直接装 APK 了');
                      return;
                    }
                    await Native.openInstallPermission();
                    app.toast('把「允许来自此来源」打开，再回云匣');
                  },
                ),
                KitRow(
                  icon: 'info',
                  iconBg: tone.icobg,
                  iconColor: tone.ink2,
                  title: '关于云匣',
                  sub: '连的是 ${app.api.server}',
                  trailing: UIIcon('chevron-right',
                      size: 17, color: tone.ink3.withValues(alpha: 0.55)),
                  onTap: () => app.toast('云匣 · NAS 5007'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

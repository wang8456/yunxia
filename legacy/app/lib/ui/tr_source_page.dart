import 'package:flutter/material.dart';

import '../core/app_state.dart';
import '../core/translator.dart';
import '../core/tokens.dart';
import '../core/ui_icons.dart';
import 'widgets.dart';

/// 翻译源设置 —— 译在 App 里跑，不问服务器。
///
/// 默认 DeepSeek（`deepseek-flash`），也可以填任意 OpenAI 兼容地址
/// （硅基流动、月之暗面、自建 one-api…）。
class TrSourcePage extends StatefulWidget {
  final App app;
  const TrSourcePage({super.key, required this.app});

  @override
  State<TrSourcePage> createState() => _TrSourcePageState();
}

class _TrSourcePageState extends State<TrSourcePage> {
  App get app => widget.app;
  TrSource get src => TrSource.current;

  bool _testing = false;
  String _result = '';
  bool _ok = false;

  void _sync() {
    // 改完立刻写回会话（落盘）并同步运行中的翻译器
    app.session.setTrSource(
      provider: src.provider,
      base: src.base,
      model: src.model,
      key: src.key,
    );
    setState(() {});
  }

  Future<String?> _askText({
    required String title,
    required String hint,
    required String value,
    bool secret = false,
    TextInputType? keyboard,
  }) async {
    final c = TextEditingController(text: value);
    var hide = secret;
    final r = await showDialog<String>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => AlertDialog(
          title: Text(title, style: const TextStyle(fontSize: 16.5)),
          content: TextField(
            controller: c,
            autofocus: true,
            obscureText: hide,
            keyboardType: keyboard,
            decoration: InputDecoration(
              hintText: hint,
              suffixIcon: secret
                  ? IconButton(
                      icon: Icon(
                        hide
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        size: 19,
                        color: Theme.of(ctx).extension<Tone>()!.ink3,
                      ),
                      onPressed: () => setSt(() => hide = !hide),
                    )
                  : null,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, c.text.trim()),
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
    c.dispose();
    return r;
  }

  Future<void> _test() async {
    setState(() {
      _testing = true;
      _result = '';
      _ok = false;
    });
    try {
      final r = await Translator.test(src);
      if (!mounted) return;
      setState(() {
        _testing = false;
        _ok = true;
        _result = '通了：$r';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _ok = false;
        _result = '$e';
      });
    }
  }

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
                Text(
                  '翻译源',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: tone.ink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.fromLTRB(6, 0, 6, 12),
              child: Text(
                '听（转写）还在服务器上跑，翻译在手机里跑，不经过服务器，也不占服务器的额度。',
                style: TextStyle(fontSize: 12.5, height: 1.45, color: tone.ink3),
              ),
            ),
            SurfaceCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _row(
                    icon: 'translate',
                    bg: const Color(0xFFEAF7F0),
                    fg: const Color(0xFF0D9C7A),
                    title: '服务',
                    sub: src.isCustom ? '任意 OpenAI 兼容地址' : 'api.deepseek.com',
                    trailing: _seg([
                      ('DeepSeek', !src.isCustom, () {
                        src.provider = TrSource.deepseek;
                        if (src.model.trim().isEmpty) {
                          src.model = TrSource.defaultModel;
                        }
                        _sync();
                      }),
                      ('自定义', src.isCustom, () {
                        src.provider = TrSource.custom;
                        _sync();
                      }),
                    ]),
                  ),
                  if (src.isCustom) ...[
                    Divider(height: 1, color: tone.line),
                    _row(
                      icon: 'folder',
                      bg: const Color(0xFFE8F2FF),
                      fg: const Color(0xFF1677F8),
                      title: '接口地址',
                      sub: src.base.isEmpty ? '必填 · 例如 https://api.siliconflow.cn/v1' : src.base,
                      trailing: _chev(tone),
                      onTap: () async {
                        final r = await _askText(
                          title: '接口地址',
                          hint: 'https://api.siliconflow.cn/v1',
                          value: src.base,
                          keyboard: TextInputType.url,
                        );
                        if (r == null) return;
                        src.base = r;
                        _sync();
                      },
                    ),
                  ],
                  Divider(height: 1, color: tone.line),
                  _row(
                    icon: 'speed',
                    bg: const Color(0xFFEFEAFF),
                    fg: const Color(0xFF7C5CF0),
                    title: '模型',
                    sub: src.shownModel,
                    trailing: _chev(tone),
                    onTap: () async {
                      final r = await _askText(
                        title: '模型名',
                        hint: src.isCustom ? '填服务商给的模型名' : TrSource.defaultModel,
                        value: src.model,
                      );
                      if (r == null) return;
                      src.model = r;
                      _sync();
                    },
                  ),
                  if (!src.isCustom) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(58, 0, 14, 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final m in TrSource.deepseekModels)
                            _chip(m, src.shownModel == m, () {
                              src.model = m;
                              _sync();
                            }),
                        ],
                      ),
                    ),
                  ],
                  Divider(height: 1, color: tone.line),
                  _row(
                    icon: 'lock',
                    bg: const Color(0xFFFFF3E5),
                    fg: const Color(0xFFE08A16),
                    title: 'API 密钥',
                    sub: src.key.isEmpty ? '未填 · 翻译不可用' : src.maskedKey,
                    trailing: _chev(tone),
                    onTap: () async {
                      final r = await _askText(
                        title: 'API 密钥',
                        hint: 'sk-…',
                        value: src.key,
                        secret: true,
                      );
                      if (r == null) return;
                      src.key = r;
                      _sync();
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            SurfaceCard(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  GestureDetector(
                    onTap: _testing ? null : _test,
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      decoration: BoxDecoration(
                        color: tone.ac.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Center(
                        child: Text(
                          _testing ? '正在翻译…' : '测试一下',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: tone.ac,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_result.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text(
                      _result,
                      style: TextStyle(
                        fontSize: 12.5,
                        height: 1.45,
                        color: _ok ? const Color(0xFF0D9C7A) : const Color(0xFFD14343),
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  Text(
                    '密钥只存在这台设备上（App 自己的配置文件），不会上传。'
                    '恢复出厂/清除数据会丢，重填一次就行。',
                    style: TextStyle(fontSize: 12, height: 1.5, color: tone.ink3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chev(Tone tone) => UIIcon(
    'chevron-right',
    size: 17,
    color: tone.ink3.withValues(alpha: 0.55),
  );

  Widget _chip(String label, bool on, VoidCallback tap) => GestureDetector(
    onTap: tap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: on ? Theme.of(context).extension<Tone>()!.ac.withValues(alpha: 0.12) : Colors.transparent,
        border: Border.all(
          color: on
              ? Theme.of(context).extension<Tone>()!.ac
              : Theme.of(context).extension<Tone>()!.line2,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w600,
          color: on
              ? Theme.of(context).extension<Tone>()!.ac
              : Theme.of(context).extension<Tone>()!.ink3,
        ),
      ),
    ),
  );

  Widget _row({
    required String icon,
    required Color bg,
    required Color fg,
    required String title,
    required String sub,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    final tone = Theme.of(context).extension<Tone>()!;
    final row = Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Row(
        children: [
          UIIcon(icon, size: 17, color: fg),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: tone.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  sub,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 12, height: 1.35, color: tone.ink3),
                ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 10), trailing],
        ],
      ),
    );
    return onTap == null ? row : GestureDetector(onTap: onTap, child: row);
  }

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
                color: on ? Colors.white : Theme.of(context).extension<Tone>()!.ink3,
              ),
            ),
          ),
        ),
        const SizedBox(width: 6),
      ],
    ],
  );
}

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

/// 极简 Markdown 渲染（对话用）。
///
/// 只做 Agent 回复里真会出现的少数几种：代码块、行内代码、粗体、斜体、
/// 标题、列表、引用、表格（按等宽块显示）。不引第三方包 —— 包体不动、
/// 样式完全跟着主题走，和 App 其它地方的排版一致。
class MarkdownLite extends StatelessWidget {
  final String text;
  final Color ink;
  final Color ink2;
  final Color codeBg;
  final Color line;
  final double size;

  /// 点正文里的链接（http/https）。null = 链接只高亮、不可点
  final void Function(String url)? onTapLink;

  const MarkdownLite(
    this.text, {
    super.key,
    required this.ink,
    required this.ink2,
    required this.codeBg,
    required this.line,
    this.size = 13.5,
    this.onTapLink,
  });

  @override
  Widget build(BuildContext context) {
    final blocks = _parse(text);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var i = 0; i < blocks.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          blocks[i],
        ],
      ],
    );
  }

  List<Widget> _parse(String src) {
    final lines = src.replaceAll('\r\n', '\n').split('\n');
    final out = <Widget>[];
    var i = 0;

    Widget para(String s, {double? fontSize, FontWeight? weight, Color? color}) {
      return Text.rich(
        TextSpan(children: _inline(s)),
        style: TextStyle(
          fontSize: fontSize ?? size,
          height: 1.6,
          color: color ?? ink,
          fontWeight: weight,
        ),
      );
    }

    while (i < lines.length) {
      final t = lines[i].trimRight();

      // ``` 代码块
      if (t.trimLeft().startsWith('```')) {
        i++;
        final buf = StringBuffer();
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          buf.writeln(lines[i]);
          i++;
        }
        i++; // 跳过收尾的 ```
        out.add(_code(buf.toString().trimRight()));
        continue;
      }

      // 表格：连续的 | 行（含分隔行）按等宽块显示，比拆成散文好读
      if (t.trimLeft().startsWith('|')) {
        final buf = StringBuffer();
        while (i < lines.length && lines[i].trimLeft().startsWith('|')) {
          buf.writeln(lines[i].trimRight());
          i++;
        }
        out.add(_code(buf.toString().trimRight()));
        continue;
      }

      final l = t.trimLeft();
      if (l.isEmpty) {
        i++;
        continue;
      }

      // 标题
      if (l.startsWith('### ')) {
        out.add(para(l.substring(4), fontSize: size + 0.5, weight: FontWeight.w700));
        i++;
        continue;
      }
      if (l.startsWith('## ')) {
        out.add(para(l.substring(3), fontSize: size + 2, weight: FontWeight.w700));
        i++;
        continue;
      }
      if (l.startsWith('# ')) {
        out.add(para(l.substring(2), fontSize: size + 4, weight: FontWeight.w700));
        i++;
        continue;
      }

      // 引用
      if (l.startsWith('> ')) {
        final buf = <String>[];
        while (i < lines.length && lines[i].trimLeft().startsWith('> ')) {
          buf.add(lines[i].trimLeft().substring(2));
          i++;
        }
        out.add(Container(
          padding: const EdgeInsets.only(left: 10),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: line, width: 3)),
          ),
          child: para(buf.join(' '), color: ink2),
        ));
        continue;
      }

      // 列表（- * + 或 1. 2.）
      final bullet = RegExp(r'^([-*+•]|\d+[.)])\s+');
      if (bullet.hasMatch(l)) {
        final rows = <Widget>[];
        while (i < lines.length && bullet.hasMatch(lines[i].trimLeft())) {
          final cur = lines[i].trimLeft();
          final m = bullet.firstMatch(cur)!;
          final mark = m.group(1)!;
          final isNum = RegExp(r'^\d').hasMatch(mark);
          final body = cur.substring(m.end);
          rows.add(Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: isNum ? 22 : 14,
                child: isNum
                    ? Padding(
                        padding: const EdgeInsets.only(top: 1),
                        child: Text('$mark',
                            style: TextStyle(
                                fontSize: size, height: 1.6, color: ink2)),
                      )
                    : Padding(
                        padding: EdgeInsets.only(top: size * 0.62),
                        child: Container(
                          width: 4,
                          height: 4,
                          decoration: BoxDecoration(
                              color: ink2, shape: BoxShape.circle),
                        ),
                      ),
              ),
              Expanded(child: para(body)),
            ],
          ));
          i++;
        }
        out.add(Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var k = 0; k < rows.length; k++) ...[
              if (k > 0) const SizedBox(height: 3),
              rows[k],
            ],
          ],
        ));
        continue;
      }

      // 普通段落：连续非空行合并
      final buf = <String>[l];
      i++;
      while (i < lines.length &&
          lines[i].trim().isNotEmpty &&
          !lines[i].trimLeft().startsWith('```') &&
          !lines[i].trimLeft().startsWith('|') &&
          !bullet.hasMatch(lines[i].trimLeft()) &&
          !lines[i].trimLeft().startsWith('#') &&
          !lines[i].trimLeft().startsWith('> ')) {
        buf.add(lines[i].trimLeft());
        i++;
      }
      out.add(para(buf.join(' ')));
    }
    return out;
  }

  Widget _code(String s) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: codeBg,
        borderRadius: BorderRadius.circular(9),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text(
          s,
          style: TextStyle(
            fontSize: size - 1.2,
            height: 1.5,
            letterSpacing: 0.3,
            color: ink,
          ),
        ),
      ),
    );
  }

  /// 把一段纯文本切成「文字 + 可点链接」。
  /// 和旧版前端一致：链接只认 http(s)，尾部的标点（。，、)」等）不算进 URL。
  static final _urlRe = RegExp(r'https?://[^\s<>"' r"'" r'）】。，、；：！？]+');

  List<InlineSpan> _links(String s, TextStyle base) {
    final out = <InlineSpan>[];
    var last = 0;
    for (final m in _urlRe.allMatches(s)) {
      var url = m.group(0)!;
      // 去掉误吞的收尾标点
      while (url.isNotEmpty && '.,;:!?)]}，。、；：！？）」』'.contains(url[url.length - 1])) {
        url = url.substring(0, url.length - 1);
      }
      final start = m.start;
      final end = start + url.length;
      if (start > last) out.add(TextSpan(text: s.substring(last, start)));
      final tap = onTapLink;
      out.add(TextSpan(
        text: url,
        style: TextStyle(color: const Color(0xFF1677F8), decoration: TextDecoration.underline,
            decorationColor: const Color(0x551677F8)),
        recognizer: tap == null
            ? null
            : (TapGestureRecognizer()..onTap = () => tap(url)),
      ));
      last = end;
    }
    if (last == 0) return [TextSpan(text: s)];
    if (last < s.length) out.add(TextSpan(text: s.substring(last)));
    return out;
  }

  /// 行内元素：`code`、**粗**、*斜*、~~删~~
  List<InlineSpan> _inline(String s) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'(`[^`]+`|\*\*[^*]+\*\*|__[^_]+__|\*[^*\n]+\*|~~[^~]+~~)');
    var last = 0;
    for (final m in re.allMatches(s)) {
      if (m.start > last) {
        spans.addAll(_links(s.substring(last, m.start), const TextStyle()));
      }
      final tok = m.group(0)!;
      if (tok.startsWith('`')) {
        spans.add(TextSpan(
          text: tok.substring(1, tok.length - 1),
          style: TextStyle(
            letterSpacing: 0.3,
            fontSize: size - 1,
            backgroundColor: codeBg,
          ),
        ));
      } else if (tok.startsWith('**') || tok.startsWith('__')) {
        spans.add(TextSpan(
          text: tok.substring(2, tok.length - 2),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ));
      } else if (tok.startsWith('~~')) {
        spans.add(TextSpan(
          text: tok.substring(2, tok.length - 2),
          style: const TextStyle(decoration: TextDecoration.lineThrough),
        ));
      } else {
        spans.add(TextSpan(
          text: tok.substring(1, tok.length - 1),
          style: const TextStyle(fontStyle: FontStyle.italic),
        ));
      }
      last = m.end;
    }
    if (last < s.length) spans.addAll(_links(s.substring(last), const TextStyle()));
    return spans;
  }
}

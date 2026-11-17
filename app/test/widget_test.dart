// 冒烟测试：令牌表与工具函数（界面渲染测试在真机上做，这里只保证纯逻辑不跑偏）。
import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/models.dart';
import 'package:yunxia_app/core/tokens.dart';

void main() {
  test('主题表齐全且颜色不为空', () {
    // 主题是会继续加的（蓝/灰/深/绿/棕…），别把数量写死成 3
    expect(Tokens.all.length, greaterThanOrEqualTo(3));
    for (final t in Tokens.all) {
      expect(t.id.isNotEmpty, true);
      expect(t.ac.a, greaterThan(0));
    }
  });

  test('按 id 取主题，未知 id 回落默认蓝', () {
    expect(Tokens.byId('dark').dark, true);
    expect(Tokens.byId('不存在').id, 'blue');
  });

  test('文件类型色三套主题都有值', () {
    for (final t in Tokens.all) {
      for (final k in ['dir', 'image', 'video', 'pdf', 'code', 'archive', 'file']) {
        final (bg, fg) = t.iconOf(k);
        expect(bg.a, greaterThan(0));
        expect(fg.a, greaterThan(0));
      }
    }
  });

  test('大小格式化与网页版一致', () {
    expect(humanSize(0), '0 B');
    expect(humanSize(999), '999 B');
    expect(humanSize(1024), '1.0 KB');
    expect(humanSize(1536), '1.5 KB');
    expect(humanSize(5 * 1024 * 1024 * 1024), '5.0 GB');
  });

  test('时间格式化：今天/昨天/更早', () {
    final now = DateTime.now();
    expect(humanTime(now).startsWith('今天'), true);
    expect(humanTime(now.subtract(const Duration(days: 1))).startsWith('昨天'), true);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:yunxia_app/core/subs_tr.dart';

void main() {
  test('语言码归一：监控页和播放页写法不一样也认得出是同一份译文', () {
    expect(langKey('zh'), 'zh');
    expect(langKey('zh-CN'), 'zh');
    expect(langKey('zh-Hans'), 'zh');
    expect(langKey('zh_cn'), 'zh');
    expect(langKey('简体中文'), 'zh');
    expect(langKey('zh-TW'), 'zh-tw');
    expect(langKey('zh-Hant'), 'zh-tw');
    expect(langKey('繁體中文'), 'zh-tw');
    expect(langKey('en-US'), 'en');
    expect(langKey('JA'), 'ja');
    expect(langKey(''), '');
  });
}

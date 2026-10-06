import 'package:flutter_test/flutter_test.dart';
import 'package:shopping_buddy/src/sync/connect_code.dart';

void main() {
  test('parses the code the server builds (same vector as server/tests/test_web.py)', () {
    final code = parseConnectCode('shoppingbuddy://connect?url=https%3A%2F%2Fbuddy.example.org%2Fsb&token=a+b%26c')!;
    expect(code.url, 'https://buddy.example.org/sb');
    expect(code.token, 'a b&c');
  });

  test('other QR codes are refused', () {
    for (final text in [
      'https://buddy.example.org',
      'shoppingbuddy://other?url=https%3A%2F%2Fx.org&token=t',
      'shoppingbuddy://connect?url=https%3A%2F%2Fx.org',
      'shoppingbuddy://connect?url=ftp%3A%2F%2Fx.org&token=t',
      'shoppingbuddy://connect?url=x.org&token=t',
      '4006381333931',
    ]) {
      expect(parseConnectCode(text), isNull, reason: text);
    }
  });
}

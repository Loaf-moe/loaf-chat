import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/model/message_route.dart';

void main() {
  test('two routes to the same message are equal', () {
    expect(
      const MessageRoute('!a:x', r'$1'),
      const MessageRoute('!a:x', r'$1'),
    );
    expect(
      const MessageRoute('!a:x', r'$1').hashCode,
      const MessageRoute('!a:x', r'$1').hashCode,
    );
    expect(
      const MessageRoute('!a:x', r'$1'),
      isNot(const MessageRoute('!a:x', r'$2')),
    );
  });
}

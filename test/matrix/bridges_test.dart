import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/bridges.dart';
import 'package:loaf_native/ui/model/models.dart';

void main() {
  test('an OOYE puppet is from Discord', () {
    expect(bridgeOf('@_ooye_a:loaf.moe'), Bridge.discord);
    expect(bridgeOf('@_ooye_123456789:loaf.moe'), Bridge.discord);
  });

  test('anyone else is from nowhere', () {
    expect(bridgeOf('@ooye:loaf.moe'), isNull);
    expect(bridgeOf('@x_ooye_:loaf.moe'), isNull);
    expect(bridgeOf('@_ooye:loaf.moe'), isNull);
    expect(bridgeOf('@ada:loaf.moe'), isNull);
  });
}

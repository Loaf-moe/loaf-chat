import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/widgets/count_label.dart';

void main() {
  test('counts read as numbers up to 99, then 99+', () {
    expect(countLabel(1), '1');
    expect(countLabel(99), '99');
    expect(countLabel(100), '99+');
    expect(countLabel(250), '99+');
  });
}

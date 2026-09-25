import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/ui/spaces/space_address.dart';

void main() {
  group('parseSpaceAddress', () {
    test('takes an alias as written', () {
      expect(parseSpaceAddress('#bakers:loaf.moe'), '#bakers:loaf.moe');
    });

    test('adds the # people leave off', () {
      expect(parseSpaceAddress('bakers:loaf.moe'), '#bakers:loaf.moe');
    });

    test('ignores whitespace around a paste', () {
      expect(parseSpaceAddress('  #bakers:loaf.moe \n'), '#bakers:loaf.moe');
    });

    test('reads a matrix.to link', () {
      expect(
        parseSpaceAddress('https://matrix.to/#/#bakers:loaf.moe'),
        '#bakers:loaf.moe',
      );
    });

    test('reads a percent-encoded matrix.to link', () {
      expect(
        parseSpaceAddress('https://matrix.to/#/%23bakers%3Aloaf.moe'),
        '#bakers:loaf.moe',
      );
    });

    test('reads a room id link, dropping the via servers', () {
      expect(
        parseSpaceAddress('matrix.to/#/!abc123:loaf.moe?via=loaf.moe'),
        '!abc123:loaf.moe',
      );
    });

    test('says nothing for text that is not an address yet', () {
      expect(parseSpaceAddress(''), isNull);
      expect(parseSpaceAddress('bakers'), isNull);
      expect(parseSpaceAddress('#bakers'), isNull);
      expect(parseSpaceAddress('@mika:loaf.moe'), isNull);
      expect(
        parseSpaceAddress('https://example.com/#/#bakers:loaf.moe'),
        isNull,
      );
    });
  });
}

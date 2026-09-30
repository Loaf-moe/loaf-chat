import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/update/ed25519.dart';

import '../matrix/crypto_harness.dart';

String _b64(String hex) => base64.encode([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

// RFC 8032, 7.1, test 1: the empty message.
final _key = _b64(
  'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
);
final _signature = _b64(
  'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb882159'
  '0a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
);

void main() {
  setUpAll(loadVodozemac);

  test('a true signature checks out, padded base64 or not', () {
    expect(ed25519Check(_key)('', _signature), isTrue);
    expect(
      ed25519Check(_key.replaceAll('=', ''))('', _signature.replaceAll('=', '')),
      isTrue,
    );
  });

  test('the same signature over other text does not', () {
    expect(ed25519Check(_key)('loaf', _signature), isFalse);
  });

  test('rubbish is a no, not a crash', () {
    expect(ed25519Check(_key)('', 'not base64 at all!'), isFalse);
    expect(ed25519Check('')('', _signature), isFalse);
  });
}

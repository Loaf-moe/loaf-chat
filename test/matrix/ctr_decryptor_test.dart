import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:loaf_native/matrix/ctr_decryptor.dart';
import 'package:matrix/matrix.dart';

import 'crypto_harness.dart';

void main() {
  setUpAll(loadVodozemac);

  test(
    'chunked decryption matches the whole-file decrypt at every boundary',
    () async {
      final random = Random(7);
      for (final length in [0, 1, 15, 16, 17, 1000, 65535, 65536, 65537]) {
        final plain = Uint8List.fromList(
          List.generate(length, (_) => random.nextInt(256)),
        );
        final enc = await MatrixFile(bytes: plain, name: 'x').encrypt();
        final whole = await decryptFileImplementation(enc);
        expect(whole, plain, reason: 'reference, length $length');
        for (final chunk in [1, 15, 16, 17, 4096, 65537]) {
          final d = CtrDecryptor(
            key: base64Decode(
              base64.normalize(enc.k.replaceAll('-', '+').replaceAll('_', '/')),
            ),
            iv: base64Decode(base64.normalize(enc.iv)),
          );
          final out = BytesBuilder();
          for (var i = 0; i < enc.data.length; i += chunk) {
            out.add(
              d.add(enc.data.sublist(i, min(i + chunk, enc.data.length))),
            );
          }
          out.add(d.close());
          expect(out.takeBytes(), plain, reason: 'length $length chunk $chunk');
        }
      }
    },
  );
}

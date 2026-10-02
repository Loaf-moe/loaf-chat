import 'dart:typed_data';

import 'package:vodozemac/vodozemac.dart';

/// AES-256-CTR decryption of a Matrix attachment as it arrives, in chunks of
/// any size. CTR turns each 16-byte block independently, so only whole blocks
/// are decrypted as they come; a partial block waits for the next chunk, or
/// for [close].
class CtrDecryptor {
  CtrDecryptor({required List<int> key, required List<int> iv})
    : _key = Uint8List.fromList(key),
      _iv = Uint8List.fromList(iv) {
    if (_key.length != 32) {
      throw ArgumentError.value(key.length, 'key', 'must be 32 bytes');
    }
    if (_iv.length != 16) {
      throw ArgumentError.value(iv.length, 'iv', 'must be 16 bytes');
    }
  }

  final Uint8List _key;
  final Uint8List _iv;

  /// Whole blocks decrypted so far: where the counter stands.
  int _block = 0;
  Uint8List _carry = Uint8List(0);

  /// Plaintext for every whole 16-byte block so far; the remainder waits.
  Uint8List add(List<int> chunk) {
    final joined = _carry.isEmpty
        ? Uint8List.fromList(chunk)
        : (BytesBuilder(copy: false)
                ..add(_carry)
                ..add(chunk))
              .takeBytes();
    final whole = joined.length - joined.length % 16;
    _carry = Uint8List.sublistView(joined, whole);
    if (whole == 0) return Uint8List(0);
    final out = CryptoUtils.aesCtr(
      input: Uint8List.sublistView(joined, 0, whole),
      key: _key,
      iv: _ivAt(_block),
    );
    _block += whole ~/ 16;
    return out;
  }

  /// The last partial block.
  Uint8List close() {
    if (_carry.isEmpty) return Uint8List(0);
    final out = CryptoUtils.aesCtr(input: _carry, key: _key, iv: _ivAt(_block));
    _carry = Uint8List(0);
    return out;
  }

  /// The IV plus [n], as a 128-bit big-endian integer: the counter block the
  /// [n]th block starts from.
  Uint8List _ivAt(int n) {
    final out = Uint8List.fromList(_iv);
    var carry = n;
    for (var i = 15; i >= 0 && carry > 0; i--) {
      carry += out[i];
      out[i] = carry & 0xff;
      carry >>= 8;
    }
    return out;
  }
}

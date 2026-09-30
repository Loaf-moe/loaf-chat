/// Ed25519 by way of vodozemac, which the app already carries for Matrix.
/// vodozemac must be initialised first; `MatrixSession.open` does that.
library;

import 'package:vodozemac/vodozemac.dart' as vod;

typedef SignatureCheck = bool Function(String message, String signature);

/// A check against one base64 public key. Never throws: a key or signature
/// that cannot even be read is simply not a match.
SignatureCheck ed25519Check(String publicKey) => (message, signature) {
  try {
    // vodozemac reads unpadded base64; openssl and `base64` write padding.
    vod.Ed25519PublicKey.fromBase64(publicKey.replaceAll('=', '')).verify(
      message: message,
      signature: vod.Ed25519Signature.fromBase64(signature.replaceAll('=', '')),
    );
    return true;
  } catch (_) {
    return false;
  }
};

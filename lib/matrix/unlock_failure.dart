/// What a failed unlock of secret storage means to the person: a key that
/// opens nothing, or a server that didn't answer. One mapping for unlocking
/// this device and for unlocking to vouch for another, so the two never
/// disagree.
library;

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';

import '../ui/verify/verifier.dart';

/// Only transport failures read as unreachable: a mistyped key must never
/// send someone off to check their connection.
UnlockResult unlockFailure(Object error, [StackTrace? stack]) {
  switch (error) {
    case InvalidPassphraseException() || FormatException():
      return UnlockResult.wrongKey;
    case BootstrapBadStateException():
      Logs().w(
        '[loaf] this account has no usable secret storage',
        error,
        stack,
      );
      return UnlockResult.wrongKey;
    case IOException() ||
        http.ClientException() ||
        TimeoutException() ||
        MatrixException():
      Logs().w('[loaf] reaching the server failed', error, stack);
      return UnlockResult.unreachable;
    default:
      Logs().w('[loaf] unlocking secret storage failed', error, stack);
      return UnlockResult.wrongKey;
  }
}

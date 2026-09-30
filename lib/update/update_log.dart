/// Where the updaters say what went wrong. A failed update is never shown
/// to anyone, so this line is the only trace of it.
library;

import 'package:flutter/foundation.dart';

void updateLog(String message, [Object? error, StackTrace? stack]) {
  debugPrint('[loaf update] $message${error == null ? '' : ': $error'}');
  if (stack != null) debugPrint('$stack'.split('\n').take(8).join('\n'));
}

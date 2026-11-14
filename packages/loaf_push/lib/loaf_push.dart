/// The Rust crate `loaf_push`, built and bundled by `hook/build.dart`.
///
/// Two callers, one library. On iOS the Notification Service Extension
/// `dlopen`s it from the app's Frameworks for `loaf_push_decrypt`, which no
/// Dart calls. [notifies] is the other end: the app's own push-rule verdict,
/// so the phone and the app cannot judge a message differently.
library;

import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

const _asset = 'package:loaf_push/loaf_push.dart';

@Native<Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int64, Pointer<Utf8>)>(
  symbol: 'loaf_push_notifies',
  assetId: _asset,
)
external int _notifies(
  Pointer<Utf8> rules,
  Pointer<Utf8> event,
  int members,
  Pointer<Utf8> power,
);

/// Whether [rules] notify for [event] in a room of [members] people, where
/// [power] is the room's `m.room.power_levels` content.
///
/// [rules] is the ruleset as the server sends it — `override`, `content`,
/// `room`, `sender`, `underride`, untouched. The crate applies the spec's
/// order and Synapse's treatment of the legacy mention rules itself, so
/// nothing is reshaped here. [userId] and [displayName] are what the rules
/// read about you.
///
/// [members] is null for a room whose joined count the app has never been
/// told; the crate holds member-count conditions rather than dropping them,
/// so an unknown count cannot silence a direct message.
///
/// Null when the crate could not judge: unparsable rules, or an event with
/// no content. The caller decides what that means — for a notification,
/// showing it (see `PushRules.notifies`).
bool? notifies({
  required String userId,
  String? displayName,
  required Map<String, Object?> rules,
  required Map<String, Object?> event,
  int? members,
  Map<String, Object?>? power,
}) {
  // The shape of `rules.json`, which the extension reads from the App Group:
  // one document, so both callers hand the crate the same thing.
  final rulesC = jsonEncode({
    'user_id': userId,
    'display_name': ?displayName,
    'rules': rules,
  }).toNativeUtf8();
  final eventC = jsonEncode(event).toNativeUtf8();
  final powerC = power == null ? nullptr : jsonEncode(power).toNativeUtf8();
  try {
    return switch (_notifies(rulesC, eventC, members ?? -1, powerC.cast())) {
      1 => true,
      0 => false,
      _ => null,
    };
  } finally {
    calloc
      ..free(rulesC)
      ..free(eventC);
    if (powerC != nullptr) calloc.free(powerC);
  }
}

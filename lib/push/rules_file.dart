/// The push rules the iOS Notification Service Extension judges a push with,
/// left in the App Group container because the extension cannot reach the
/// running client.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:matrix/matrix.dart';

/// `{user_id, display_name, written_at, rules}`, with the ruleset exactly as
/// the server sends it. The spec's departures are the evaluator's to make —
/// `packages/loaf_push/rust/src/rules.rs` makes them — so this hands the
/// extension what `lib/matrix/push_rules.dart` hands the same crate. A
/// ruleset chewed over here would let one piece of code reach two verdicts.
Map<String, Object?> rulesFile({
  required String userId,
  required String? displayName,
  required PushRuleSet rules,
  required DateTime now,
}) => {
  'user_id': userId,
  'display_name': displayName,
  'written_at': now.millisecondsSinceEpoch,
  'rules': rules.toJson(),
};

/// Keeps `rules.json` level with the account: the rules themselves, and the
/// display name `contains_display_name` is matched against.
class RulesWriter {
  RulesWriter(this.client, this.file) {
    _subs = [
      client.onSync.stream.listen(_onSync),
      client.onUserProfileUpdate.stream.listen(_onProfileUpdate),
    ];
    unawaited(_loadName());
  }

  final Client client;
  final File file;
  late final List<StreamSubscription<Object?>> _subs;
  String? _displayName;
  String? _written;
  var _disposed = false;

  void dispose() {
    _disposed = true;
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
  }

  void _onSync(SyncUpdate update) {
    final changed =
        update.accountData?.any((event) => event.type == 'm.push_rules') ??
        false;
    if (changed) _write();
  }

  void _onProfileUpdate(String userId) {
    if (userId != client.userID) return;
    unawaited(_loadName(fresh: true));
  }

  /// [fresh] for the SDK's own "this profile changed". A stale name in the
  /// app mis-draws a label; a stale name here has the extension judging
  /// contains_display_name against a name you no longer answer to, and the
  /// mention goes unannounced.
  Future<void> _loadName({bool fresh = false}) async {
    final userId = client.userID;
    if (userId != null) {
      try {
        final profile = await client.getUserProfile(
          userId,
          maxCacheAge: fresh ? Duration.zero : const Duration(days: 1),
        );
        if (_disposed) return;
        final name = profile.displayname?.trim();
        _displayName = name == null || name.isEmpty ? null : name;
      } catch (_) {
        // No name is a fair answer: contains_display_name then matches
        // nothing, which is what the app's own evaluator does too.
        if (_disposed) return;
      }
    }
    _write();
  }

  void _write() {
    if (_disposed) return;
    final rules = client.globalPushRules;
    final userId = client.userID;
    // Never an empty ruleset. That silences every push, and the extension
    // fails open only on a file that is not there at all.
    if (rules == null || userId == null) return;
    final document = rulesFile(
      userId: userId,
      displayName: _displayName,
      rules: rules,
      now: DateTime.now(),
    );
    // written_at moves on every write, so it cannot be part of what
    // "unchanged" means.
    final fingerprint = jsonEncode({...document}..remove('written_at'));
    if (fingerprint == _written) return;
    // Beside, then rename, so the extension never reads half a document.
    File('${file.path}.tmp')
      ..writeAsStringSync(jsonEncode(document))
      ..renameSync(file.path);
    _written = fingerprint;
  }
}

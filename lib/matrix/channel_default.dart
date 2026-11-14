/// What "all messages" and "mentions only" mean in the account's push
/// rules, and the one repair that keeps encrypted channels reaching the
/// phone at all.
///
/// It lives under `lib/matrix/` rather than beside the Settings widget
/// because it is push rules and a [Client]; everything that touches
/// `package:matrix` lives here.
library;

import 'package:matrix/matrix.dart';

import '../ui/shell/profile.dart';

/// The one rule the channel default moves.
const _messageRule = '.m.rule.message';

/// The rule that carries an encrypted message to the device. It is never
/// disabled: the server cannot see inside the message, so it cannot know
/// whether it mentions you. Only the device can, and only if the message
/// reaches it — the notification extension decrypts it and applies the
/// real rules there.
const _encryptedRule = '.m.rule.encrypted';

/// `.m.rule.message` decides. An account that has never had one notifies
/// for everything, which is the server's own default.
ChannelDefault readDefault(PushRuleSet rules) {
  final message = rules.underride
      ?.where((rule) => rule.ruleId == _messageRule)
      .firstOrNull;
  return message == null || message.enabled
      ? ChannelDefault.all
      : ChannelDefault.mentions;
}

/// Writes [level], touching `.m.rule.message` and nothing else. The DM
/// rules and the mention overrides are left alone, which is what keeps
/// direct messages and mentions notifying at either setting.
Future<void> writeDefault(Client client, ChannelDefault level) =>
    client.setPushRuleEnabled(
      PushRuleKind.underride,
      _messageRule,
      level == ChannelDefault.all,
    );

/// Turns `.m.rule.encrypted` back on where it is off, and writes nothing
/// where it is already on.
///
/// Builds before this one disabled it alongside `.m.rule.message`, so an
/// account that chose mentions-only then still has it off on the server.
/// Left that way, an encrypted channel pushes nothing at all, the extension
/// never runs, and mentions in it are silent.
Future<void> repairEncryptedRule(Client client) async {
  final encrypted = client.globalPushRules?.underride
      ?.where((rule) => rule.ruleId == _encryptedRule)
      .firstOrNull;
  if (encrypted == null || encrypted.enabled) return;
  await client.setPushRuleEnabled(PushRuleKind.underride, _encryptedRule, true);
}

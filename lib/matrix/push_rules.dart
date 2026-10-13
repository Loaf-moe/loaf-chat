/// The push rules as the spec and Synapse apply them, over the SDK's
/// evaluator, which differs in two ways. It checks room rules before
/// content rules, where the spec says content first: a mentions-only room
/// would silence `.m.rule.contains_user_name`. And it applies the legacy
/// body-mention rules to a message that carries `m.mentions`, which
/// Synapse skips: such a message is judged by what it says it mentions.
/// Both are undone by what the evaluator is handed: the content rules as
/// overrides, at the end, where they come before room rules; and for a
/// message with `m.mentions`, a ruleset without the three legacy rules.
library;

import 'package:matrix/matrix.dart';

class PushRules {
  PushRules(this.client);

  final Client client;

  /// The account data the evaluators were built from: the SDK replaces
  /// it whenever new rules arrive, so a new object means a rebuild.
  BasicEvent? _source;
  var _built = false;
  late PushruleEvaluator _withLegacy;
  late PushruleEvaluator _withoutLegacy;

  static const _legacy = {
    '.m.rule.contains_display_name',
    '.m.rule.contains_user_name',
    '.m.rule.roomnotif',
  };

  bool notifies(Event event) {
    final source = client.accountData[EventTypes.PushRules];
    if (!_built || !identical(source, _source)) {
      _source = source;
      _build(client.globalPushRules ?? PushRuleSet());
      _built = true;
    }
    final intentional = event.content['m.mentions'] is Map;
    return (intentional ? _withoutLegacy : _withLegacy).match(event).notify;
  }

  void _build(PushRuleSet rules) {
    final override = [
      ...?rules.override,
      for (final rule in rules.content ?? const <PushRule>[])
        PushRule(
          ruleId: rule.ruleId,
          default$: rule.default$,
          enabled: rule.enabled,
          actions: rule.actions,
          conditions: [
            PushCondition(
              kind: PushRuleConditions.eventMatch.name,
              key: 'content.body',
              pattern: rule.pattern,
            ),
          ],
        ),
    ];
    PushruleEvaluator evaluator(List<PushRule> override) =>
        PushruleEvaluator.fromRuleset(
          PushRuleSet(
            override: override,
            content: const [],
            room: rules.room,
            sender: rules.sender,
            underride: rules.underride,
          ),
        );
    _withLegacy = evaluator(override);
    _withoutLegacy = evaluator([
      for (final rule in override)
        if (!_legacy.contains(rule.ruleId)) rule,
    ]);
  }
}

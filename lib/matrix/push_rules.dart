/// The push rules as the spec and Synapse apply them, over the SDK's
/// evaluator, which differs in three ways. It checks room rules before
/// content rules, where the spec says content first: a mentions-only room
/// would silence `.m.rule.contains_user_name`. It applies the legacy
/// body-mention rules to a message that carries `m.mentions`, which
/// Synapse skips: such a message is judged by what it says it mentions.
/// And it counts a room's members from those in memory, which a room
/// nobody has opened holds few of, where the server's summary has the
/// count. All three are undone by what the evaluator is handed: the
/// content rules as overrides, at the end, where they come before room
/// rules; for a message with `m.mentions`, a ruleset without the three
/// legacy rules; and every member-count condition decided here against
/// the summary, the rule kept or dropped by it.
library;

import 'package:matrix/matrix.dart';

class PushRules {
  PushRules(this.client);

  final Client client;

  /// The account data the rulesets were built from: the SDK replaces it
  /// whenever new rules arrive, so a new object means a rebuild.
  BasicEvent? _source;
  var _built = false;
  late PushRuleSet _rules;

  /// Evaluators by whether the message carries `m.mentions` and the
  /// room's member count, null for a room whose summary has none.
  final _evaluators = <(bool, int?), PushruleEvaluator>{};

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
    // Present, whatever its shape, as Synapse reads it.
    final intentional = event.content.containsKey('m.mentions');
    final count = event.room.summary.mJoinedMemberCount;
    final evaluator = _evaluators[(intentional, count)] ??= _evaluator(
      intentional: intentional,
      count: count,
    );
    return evaluator.match(event).notify;
  }

  void _build(PushRuleSet rules) {
    _evaluators.clear();
    _rules = PushRuleSet(
      override: [
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
      ],
      content: const [],
      room: rules.room,
      sender: rules.sender,
      underride: rules.underride,
    );
  }

  PushruleEvaluator _evaluator({required bool intentional, int? count}) {
    List<PushRule>? sized(List<PushRule>? rules) {
      if (rules == null) return null;
      return [
        for (final rule in rules)
          if (!(intentional && _legacy.contains(rule.ruleId)))
            if (count == null) rule else ?_counted(rule, count),
      ];
    }

    return PushruleEvaluator.fromRuleset(
      PushRuleSet(
        override: sized(_rules.override),
        content: const [],
        room: sized(_rules.room),
        sender: sized(_rules.sender),
        underride: sized(_rules.underride),
      ),
    );
  }

  /// [rule] with its member-count conditions decided against [count]:
  /// the rule without them when each holds, null when one does not.
  static PushRule? _counted(PushRule rule, int count) {
    final conditions = rule.conditions;
    if (conditions == null) return rule;
    final rest = <PushCondition>[];
    for (final condition in conditions) {
      if (condition.kind != PushRuleConditions.roomMemberCount.name) {
        rest.add(condition);
        continue;
      }
      final is$ = condition.is$;
      if (is$ == null || !_holds(is$, count)) return null;
    }
    if (rest.length == conditions.length) return rule;
    return PushRule(
      ruleId: rule.ruleId,
      default$: rule.default$,
      enabled: rule.enabled,
      actions: rule.actions,
      conditions: rest,
      pattern: rule.pattern,
    );
  }

  /// The spec's `is`: a number, with `==`, `<`, `<=`, `>` or `>=` before
  /// it; bare means equal. Unparsable never holds.
  static bool _holds(String is$, int count) {
    final match = RegExp(r'^(==|>=|<=|>|<)?(\d+)$').firstMatch(is$.trim());
    if (match == null) return false;
    final wanted = int.parse(match[2]!);
    return switch (match[1]) {
      '>=' => count >= wanted,
      '<=' => count <= wanted,
      '>' => count > wanted,
      '<' => count < wanted,
      _ => count == wanted,
    };
  }
}

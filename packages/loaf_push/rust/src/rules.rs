//! The account's push rules, judged on a decrypted event.
//!
//! This is `lib/matrix/push_rules.dart` in Rust. That file wraps the matrix
//! SDK's `PushruleEvaluator` and undoes three of its departures from the
//! spec — the notifications audit's F1, F4 and F6 — so the behaviour
//! reproduced here is the SDK's *as Loaf hands it the rules*, not the SDK's
//! own:
//!
//! - the order is override, then content, then room, then sender, then
//!   underride, where the SDK puts room and sender ahead of content (F4);
//! - a message carrying `m.mentions` is judged without the three legacy
//!   body-mention rules, as Synapse judges it (F6);
//! - a `room_member_count` condition is decided against the count the app
//!   read from the room summary, not against the members in memory (F1).
//!
//! Where this and the app disagree, `tests/fixtures/rules.json` says so:
//! Task 3b generates it from the app's own suite and both sides must answer
//! every case the same way.
//!
//! Nothing here panics or allocates unboundedly: the extension calls it with
//! about thirty seconds for the whole notification, and the release profile
//! aborts on panic, so the contract is the same as `decrypt`'s — no
//! unwrapping, no indexing without a bound.

use serde_json::{Map, Value};
use std::collections::HashMap;

/// What the app wrote to `rules.json`: the rules as the server sends them,
/// and the two things about you that the rules read.
#[derive(Debug, Clone)]
pub struct Account {
    pub user_id: String,
    pub display_name: Option<String>,
    /// The ruleset object: `override`, `content`, `room`, `sender`,
    /// `underride`. Untransformed — the compensations happen here.
    pub rules: Value,
}

/// `rules.json`, or the extension's refreshed copy of it. `None` when the
/// text is not JSON, carries no `user_id`, or carries no ruleset: the caller
/// then shows the message rather than guessing at it.
pub fn account_from_json(text: &str) -> Option<Account> {
    let file: Value = serde_json::from_str(text).ok()?;
    let user_id = file.get("user_id")?.as_str()?.to_owned();
    let rules = file.get("rules")?;
    if !rules.is_object() {
        return None;
    }
    Some(Account {
        user_id,
        display_name: file
            .get("display_name")
            .and_then(Value::as_str)
            .map(str::to_owned),
        rules: rules.clone(),
    })
}

/// The three rules Synapse skips for a message that carries `m.mentions`.
const LEGACY: [&str; 3] = [
    ".m.rule.contains_display_name",
    ".m.rule.contains_user_name",
    ".m.rule.roomnotif",
];

/// The rule kinds, in the order Loaf evaluates them. `Content` is second
/// because the spec puts content rules ahead of room rules (F4).
const KINDS: [Kind; 5] = [
    Kind::Override,
    Kind::Content,
    Kind::Room,
    Kind::Sender,
    Kind::Underride,
];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Kind {
    Override,
    Content,
    Room,
    Sender,
    Underride,
}

impl Kind {
    fn key(self) -> &'static str {
        match self {
            Kind::Override => "override",
            Kind::Content => "content",
            Kind::Room => "room",
            Kind::Sender => "sender",
            Kind::Underride => "underride",
        }
    }
}

/// Whether the rules notify for `event` in a room of `members` people.
///
/// `power` is the room's `m.room.power_levels` content, for the
/// `sender_notification_permission` condition that `@room` rules carry;
/// `None` means it could not be read, and the condition then holds, because
/// a notification you did not need is a smaller harm than a mention you
/// never saw. `members` is `None` for a room whose count the app never
/// recorded, and count conditions then hold for the same reason.
///
/// `None` when no verdict can be reached: the ruleset is not an object, or
/// the event carries no content. The caller shows the message.
pub fn notifies(
    account: &Account,
    event: &Value,
    members: Option<u64>,
    power: Option<&Value>,
) -> Option<bool> {
    let rules = account.rules.as_object()?;
    let content = event.get("content")?.as_object()?;
    // Present whatever its shape, as Synapse reads it (F6).
    let intentional = content.contains_key("m.mentions");

    let mut flat: HashMap<String, &Value> = HashMap::new();
    if let Some(obj) = event.as_object() {
        flatten(obj, "", &mut flat);
    }
    let room_id = flat.get("room_id").and_then(|v| v.as_str()).unwrap_or("");
    let sender = flat.get("sender").and_then(|v| v.as_str()).unwrap_or("");

    let judge = Judge {
        account,
        flat: &flat,
        members,
        power,
        sender,
    };

    for kind in KINDS {
        let Some(list) = rules.get(kind.key()).and_then(Value::as_array) else {
            continue;
        };
        for rule in list {
            let Some(rule) = rule.as_object() else {
                continue;
            };
            // A rule with no id is unusable: room and sender rules are found
            // by it, and the legacy skip reads it.
            let id = rule.get("rule_id").and_then(Value::as_str).unwrap_or("");
            // `enabled` is required by the spec; a rule missing it is treated
            // as on, which is what the server's defaults are.
            if !rule.get("enabled").and_then(Value::as_bool).unwrap_or(true) {
                continue;
            }
            if intentional && LEGACY.contains(&id) {
                continue;
            }
            let matched = match kind {
                // Room and sender rules carry no conditions: the SDK finds
                // them by id, and so does this.
                Kind::Room => id == room_id,
                Kind::Sender => id == sender,
                Kind::Content => match rule.get("pattern").and_then(Value::as_str) {
                    // The synthetic condition the SDK builds: a body match
                    // on the rule's pattern.
                    Some(pattern) => judge.body_matches(pattern),
                    None => false,
                },
                Kind::Override | Kind::Underride => match rule.get("conditions") {
                    Some(Value::Array(conditions)) => conditions.iter().all(|c| judge.holds(c)),
                    // No conditions is every event: `.m.rule.master` is this
                    // rule with no actions.
                    None => true,
                    // Anything else is a malformed rule, which the SDK drops.
                    Some(_) => false,
                },
            };
            if matched {
                return Some(notify_from(rule.get("actions")));
            }
        }
    }
    Some(false)
}

/// `notify` unless something later says otherwise, as the SDK folds the
/// list: tweaks are irrelevant to whether anything is shown.
fn notify_from(actions: Option<&Value>) -> bool {
    let Some(Value::Array(actions)) = actions else {
        return false;
    };
    let mut notify = false;
    for action in actions {
        match action.as_str() {
            Some("notify") => notify = true,
            Some("dont_notify") => notify = false,
            _ => {}
        }
    }
    notify
}

/// The event's JSON with nested objects flattened into dotted keys, as the
/// SDK's `_flattenJson` does: only objects recurse, so an array or a string
/// lands whole, and an empty object lands not at all.
fn flatten<'a>(obj: &'a Map<String, Value>, prefix: &str, out: &mut HashMap<String, &'a Value>) {
    for (key, value) in obj {
        let path = if prefix.is_empty() {
            key.clone()
        } else {
            format!("{prefix}.{key}")
        };
        match value {
            Value::Object(nested) => flatten(nested, &path, out),
            _ => {
                out.insert(path, value);
            }
        }
    }
}

struct Judge<'a> {
    account: &'a Account,
    flat: &'a HashMap<String, &'a Value>,
    members: Option<u64>,
    power: Option<&'a Value>,
    sender: &'a str,
}

impl Judge<'_> {
    fn holds(&self, condition: &Value) -> bool {
        let Some(condition) = condition.as_object() else {
            return false;
        };
        match condition.get("kind").and_then(Value::as_str) {
            Some("event_match") => self.event_match(condition),
            Some("event_property_is") => self.property(condition, false),
            Some("event_property_contains") => self.property(condition, true),
            Some("contains_display_name") => match self.account.display_name.as_deref() {
                Some(name) => self.body(|body| bounded(&fold(name), body, false)),
                // No name is no match, as the SDK's null display name is.
                None => false,
            },
            Some("room_member_count") => {
                match (condition.get("is").and_then(Value::as_str), self.members) {
                    (Some(is), Some(count)) => count_holds(is, count),
                    // A count we never recorded holds: the one default rule a
                    // count guards is the DM rule, and losing it is silence.
                    (Some(_), None) => true,
                    (None, _) => false,
                }
            }
            Some("sender_notification_permission") => {
                match (condition.get("key").and_then(Value::as_str), self.power) {
                    (Some(kind), Some(power)) => can_notify(power, self.sender, kind),
                    // Power levels we could not read hold, for the same
                    // reason an unknown member count does.
                    (Some(_), None) => true,
                    (None, _) => false,
                }
            }
            // An unknown condition makes the rule unusable, and the SDK
            // drops such a rule rather than ignoring the condition.
            _ => false,
        }
    }

    /// The field a condition names, with the spec's `\.` escape undone, as
    /// the SDK undoes it before looking the key up.
    fn field(&self, condition: &Map<String, Value>) -> Option<String> {
        Some(condition.get("key")?.as_str()?.replace(r"\.", "."))
    }

    fn event_match(&self, condition: &Map<String, Value>) -> bool {
        let (Some(field), Some(pattern)) = (
            self.field(condition),
            condition.get("pattern").and_then(Value::as_str),
        ) else {
            return false;
        };
        // Only a string field can match a pattern.
        let Some(value) = self.flat.get(&field).and_then(|v| v.as_str()) else {
            return false;
        };
        if field == "content.body" {
            // The one field matched on word boundaries rather than whole.
            bounded(&fold(pattern), &fold(value), true)
        } else {
            glob(&fold(pattern), &fold(value))
        }
    }

    fn property(&self, condition: &Map<String, Value>, contains: bool) -> bool {
        let (Some(field), Some(wanted)) = (self.field(condition), condition.get("value")) else {
            return false;
        };
        // The spec allows a string, a number, a bool or null, and the SDK
        // drops the rule for anything else.
        if !(wanted.is_string() || wanted.is_number() || wanted.is_boolean() || wanted.is_null()) {
            return false;
        }
        match self.flat.get(&field) {
            Some(value) if contains => match value.as_array() {
                Some(items) => items.contains(wanted),
                None => false,
            },
            // Present and equal; null is a value a field can hold, so
            // presence is checked rather than inferred.
            Some(value) => *value == wanted,
            None => false,
        }
    }

    fn body<F: Fn(&[char]) -> bool>(&self, f: F) -> bool {
        match self.flat.get("content.body").and_then(|v| v.as_str()) {
            Some(body) => f(&fold(body)),
            None => false,
        }
    }

    fn body_matches(&self, pattern: &str) -> bool {
        let pattern = fold(pattern);
        self.body(|body| bounded(&pattern, body, true))
    }
}

/// Case folded to chars, so the matchers below can index without worrying
/// about where a character starts. Expanding folds (ß → ss) apply to the
/// pattern and the text alike, which is what makes them comparable.
fn fold(s: &str) -> Vec<char> {
    s.chars().flat_map(char::to_lowercase).collect()
}

/// Dart's `\w` with no unicode flag: ASCII letters, digits and underscore.
/// Everything else, a Japanese character included, is a boundary.
fn is_word(c: char) -> bool {
    c.is_ascii_alphanumeric() || c == '_'
}

/// The SDK's `(^|\W)pattern($|\W)`: the pattern somewhere in `text`, with a
/// boundary on each side. With [as_glob], `*` and `?` apply.
fn bounded(pattern: &[char], text: &[char], as_glob: bool) -> bool {
    let n = text.len();
    let wild = as_glob && pattern.iter().any(|c| *c == '*' || *c == '?');
    if !wild {
        // The common case by far: a localpart, a display name or a keyword,
        // found by sliding rather than by trying every span.
        let len = pattern.len();
        // Nothing to slide: a pattern longer than the text cannot be in it,
        // and `saturating_sub` would otherwise leave one span to try, whose
        // end is past the text.
        if len > n {
            return false;
        }
        for start in 0..=(n - len) {
            if start > 0 && is_word(text[start - 1]) {
                continue;
            }
            let end = start + len;
            if end < n && is_word(text[end]) {
                continue;
            }
            if &text[start..end] == pattern {
                return true;
            }
        }
        // An empty pattern against empty text slides zero times above.
        return n == 0 && len == 0;
    }
    for start in 0..=n {
        if start > 0 && is_word(text[start - 1]) {
            continue;
        }
        for end in start..=n {
            if end < n && is_word(text[end]) {
                continue;
            }
            if glob(pattern, &text[start..end]) {
                return true;
            }
        }
    }
    false
}

/// A whole-value glob, the SDK's `^pattern$`: `*` is any run, `?` is one
/// character. Iterative with one backtrack point, so no recursion and no
/// pathological blow-up on a pattern of many stars.
fn glob(pattern: &[char], text: &[char]) -> bool {
    let (mut p, mut t) = (0usize, 0usize);
    let (mut star, mut resume) = (None, 0usize);
    while t < text.len() {
        match pattern.get(p) {
            Some('*') => {
                star = Some(p);
                p += 1;
                resume = t;
            }
            Some('?') => {
                p += 1;
                t += 1;
            }
            Some(c) if *c == text[t] => {
                p += 1;
                t += 1;
            }
            // No match here: give the last star one more character.
            _ => match star {
                Some(s) => {
                    p = s + 1;
                    resume += 1;
                    t = resume;
                }
                None => return false,
            },
        }
    }
    pattern[p..].iter().all(|c| *c == '*')
}

/// The spec's `is`: a number with an optional comparison before it, bare
/// meaning equal. Unparsable never holds, as `push_rules.dart` has it.
fn count_holds(is: &str, count: u64) -> bool {
    let is = is.trim();
    let (op, digits) = match is.get(..2) {
        Some(op @ ("==" | ">=" | "<=")) => (op, &is[2..]),
        _ => match is.get(..1) {
            Some(op @ (">" | "<")) => (op, &is[1..]),
            _ => ("==", is),
        },
    };
    if digits.is_empty() || !digits.chars().all(|c| c.is_ascii_digit()) {
        return false;
    }
    let Ok(wanted) = digits.parse::<u64>() else {
        return false;
    };
    match op {
        ">=" => count >= wanted,
        "<=" => count <= wanted,
        ">" => count > wanted,
        "<" => count < wanted,
        _ => count == wanted,
    }
}

/// Whether `sender` may send this kind of notification in the room, from its
/// power levels: the spec's defaults are 0 for a user and 50 for `room`.
fn can_notify(power: &Value, sender: &str, kind: &str) -> bool {
    let level = power
        .get("users")
        .and_then(|users| users.get(sender))
        .and_then(Value::as_i64)
        .or_else(|| power.get("users_default").and_then(Value::as_i64))
        .unwrap_or(0);
    let needed = power
        .get("notifications")
        .and_then(|n| n.get(kind))
        .and_then(Value::as_i64)
        .unwrap_or(50);
    level >= needed
}

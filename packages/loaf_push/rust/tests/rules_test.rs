//! The push rules as the app applies them, judged here instead.
//!
//! The app's `lib/matrix/push_rules.dart` is the specification: it wraps the
//! SDK's `PushruleEvaluator` and undoes three of its departures from the
//! Matrix spec, the notifications audit's F1, F4 and F6. Each is a case
//! below, named after its finding, so a failure says which one broke.
//!
//! Task 3b pins every case the app's own 245-case suite runs against this
//! same function. These are the hand-written ones: they fail with a rule's
//! name rather than a case number.

use loaf_push::rules::{Account, account_from_json, notifies};
use serde_json::{Value, json};

const ADA: &str = "@ada:example.com";
const BOB: &str = "@bob:example.com";
const ROOM: &str = "!g:example.com";

fn account(rules: Value) -> Account {
    Account {
        user_id: ADA.to_owned(),
        display_name: Some("ada".to_owned()),
        rules,
    }
}

/// A message from bob in the group room.
fn msg(body: &str) -> Value {
    json!({
        "type": "m.room.message",
        "room_id": ROOM,
        "sender": BOB,
        "content": {"msgtype": "m.text", "body": body},
    })
}

/// [msg] carrying an `m.mentions` of its own, whatever its shape.
fn mentioning(body: &str, mentions: Value) -> Value {
    let mut event = msg(body);
    event["content"]["m.mentions"] = mentions;
    event
}

fn notify(rule_id: &str, conditions: Value) -> Value {
    json!({
        "rule_id": rule_id, "default": true, "enabled": true,
        "conditions": conditions, "actions": ["notify"],
    })
}

/// The rule shape Loaf writes for "all messages" in one room: no actions.
fn silent(rule_id: &str, conditions: Value) -> Value {
    json!({
        "rule_id": rule_id, "default": false, "enabled": true,
        "conditions": conditions, "actions": [],
    })
}

/// `.m.rule.message`, the default that notifies for anything else.
fn message_default() -> Value {
    json!([{
        "rule_id": ".m.rule.message", "default": true, "enabled": true,
        "conditions": [{"kind": "event_match", "key": "type", "pattern": "m.room.message"}],
        "actions": ["notify"],
    }])
}

// ---------------------------------------------------------------- F4

#[test]
fn f4_a_content_rule_beats_a_silent_room_rule() {
    // The SDK checks room rules before content rules; the spec says content
    // first, so a mentions-only room must still notify for your localpart.
    let rules = json!({
        "content": [{
            "rule_id": ".m.rule.contains_user_name", "default": true, "enabled": true,
            "pattern": "ada", "actions": ["notify"],
        }],
        "room": [{"rule_id": ROOM, "default": false, "enabled": true, "actions": []}],
    });
    assert_eq!(
        notifies(&account(rules), &msg("hi ada!"), Some(5), None),
        Some(true)
    );
}

#[test]
fn f4_a_silent_room_rule_still_silences_a_plain_message() {
    let rules = json!({
        "content": [{
            "rule_id": ".m.rule.contains_user_name", "default": true, "enabled": true,
            "pattern": "ada", "actions": ["notify"],
        }],
        "room": [{"rule_id": ROOM, "default": false, "enabled": true, "actions": []}],
        "underride": message_default(),
    });
    assert_eq!(
        notifies(&account(rules), &msg("morning all"), Some(5), None),
        Some(false)
    );
}

// ---------------------------------------------------------------- F6

#[test]
fn f6_m_mentions_drops_the_legacy_display_name_rule() {
    // Synapse skips the three legacy rules for a message carrying
    // `m.mentions`: such a message is judged by what it says it mentions.
    let rules = json!({
        "override": [notify(
            ".m.rule.contains_display_name",
            json!([{"kind": "contains_display_name"}]),
        )],
    });
    let empty = mentioning("hi ada!", json!({}));
    assert_eq!(
        notifies(&account(rules), &empty, Some(5), None),
        Some(false)
    );
}

#[test]
fn f6_without_m_mentions_the_legacy_display_name_rule_applies() {
    let rules = json!({
        "override": [notify(
            ".m.rule.contains_display_name",
            json!([{"kind": "contains_display_name"}]),
        )],
    });
    assert_eq!(
        notifies(&account(rules), &msg("hi ada!"), Some(5), None),
        Some(true)
    );
}

// ---------------------------------------------------------------- F1

#[test]
fn f1_one_to_one_holds_at_two_members() {
    let rules = json!({
        "underride": [notify(
            ".m.rule.room_one_to_one",
            json!([{"kind": "room_member_count", "is": "2"}]),
        )],
    });
    assert_eq!(
        notifies(&account(rules), &msg("hello"), Some(2), None),
        Some(true)
    );
}

#[test]
fn f1_one_to_one_is_dropped_above_two_members() {
    let rules = json!({
        "underride": [notify(
            ".m.rule.room_one_to_one",
            json!([{"kind": "room_member_count", "is": "2"}]),
        )],
    });
    assert_eq!(
        notifies(&account(rules), &msg("hello"), Some(3), None),
        Some(false)
    );
}

#[test]
fn f1_an_unknown_member_count_holds_rather_than_silences() {
    // Fail open: a room the app never recorded a count for must not lose its
    // DM rule, which is the one default rule a count guards.
    let rules = json!({
        "underride": [notify(
            ".m.rule.room_one_to_one",
            json!([{"kind": "room_member_count", "is": "2"}]),
        )],
    });
    assert_eq!(
        notifies(&account(rules), &msg("hello"), None, None),
        Some(true)
    );
}

#[test]
fn a_member_count_comparison_reads_its_operator() {
    for (is, count, want) in [
        (">1", 2, true),
        (">=2", 2, true),
        ("<3", 2, true),
        ("<=1", 2, false),
        ("==2", 2, true),
        ("2", 3, false),
        ("nonsense", 2, false),
    ] {
        let rules = json!({
            "underride": [notify("r", json!([{"kind": "room_member_count", "is": is}]))],
        });
        assert_eq!(
            notifies(&account(rules), &msg("hello"), Some(count), None),
            Some(want),
            "is={is} count={count}"
        );
    }
}

// ---------------------------------------------------------------- levels

#[test]
fn a_silent_override_silences_everything_after_it() {
    // Mute: an override on the room id with no actions, which outranks the
    // mention rules below it.
    let rules = json!({
        "override": [
            silent(ROOM, json!([{"kind": "event_match", "key": "room_id", "pattern": ROOM}])),
            notify(".m.rule.contains_display_name", json!([{"kind": "contains_display_name"}])),
        ],
        "underride": message_default(),
    });
    assert_eq!(
        notifies(&account(rules), &msg("hi ada!"), Some(5), None),
        Some(false)
    );
}

#[test]
fn an_enabled_master_rule_silences_everything() {
    let rules = json!({
        "override": [silent(".m.rule.master", json!([]))],
        "underride": message_default(),
    });
    assert_eq!(
        notifies(&account(rules), &msg("hello"), Some(5), None),
        Some(false)
    );
}

#[test]
fn a_disabled_rule_is_skipped() {
    let rules = json!({
        "override": [{
            "rule_id": ".m.rule.master", "default": true, "enabled": false,
            "conditions": [], "actions": [],
        }],
        "underride": message_default(),
    });
    assert_eq!(
        notifies(&account(rules), &msg("hello"), Some(5), None),
        Some(true)
    );
}

// ---------------------------------------------------------------- matching

#[test]
fn a_body_pattern_globs_and_respects_word_boundaries() {
    let rules = json!({
        "content": [{
            "rule_id": "c", "default": false, "enabled": true,
            "pattern": "*foo*", "actions": ["notify"],
        }],
    });
    assert_eq!(
        notifies(&account(rules.clone()), &msg("barfoobar"), Some(5), None),
        Some(true)
    );
    let one = json!({
        "content": [{
            "rule_id": "c", "default": false, "enabled": true,
            "pattern": "a?a", "actions": ["notify"],
        }],
    });
    assert_eq!(
        notifies(&account(one.clone()), &msg("aba"), Some(5), None),
        Some(true)
    );
    assert_eq!(
        notifies(&account(one), &msg("abba"), Some(5), None),
        Some(false)
    );
}

#[test]
fn a_non_body_pattern_is_anchored() {
    let rules = json!({
        "override": [notify(
            "r",
            json!([{"kind": "event_match", "key": "type", "pattern": "m.room.*"}]),
        )],
    });
    assert_eq!(
        notifies(&account(rules.clone()), &msg("hello"), Some(5), None),
        Some(true)
    );
    let exact = json!({
        "override": [notify(
            "r",
            json!([{"kind": "event_match", "key": "type", "pattern": "room.message"}]),
        )],
    });
    assert_eq!(
        notifies(&account(exact), &msg("hello"), Some(5), None),
        Some(false)
    );
}

#[test]
fn contains_display_name_matches_a_whole_word_only() {
    let rules = json!({
        "override": [notify(
            ".m.rule.contains_display_name",
            json!([{"kind": "contains_display_name"}]),
        )],
    });
    assert_eq!(
        notifies(&account(rules.clone()), &msg("hi ada!"), Some(5), None),
        Some(true)
    );
    assert_eq!(
        notifies(&account(rules.clone()), &msg("adalovelace"), Some(5), None),
        Some(false)
    );
    let nameless = Account {
        display_name: None,
        ..account(rules)
    };
    assert_eq!(
        notifies(&nameless, &msg("hi ada!"), Some(5), None),
        Some(false)
    );
}

#[test]
fn an_intentional_user_mention_matches_by_property() {
    let rules = json!({
        "override": [notify(
            ".m.rule.is_user_mention",
            json!([{
                "kind": "event_property_contains",
                "key": r"content.m\.mentions.user_ids",
                "value": ADA,
            }]),
        )],
    });
    let mine = mentioning("hey", json!({"user_ids": [ADA]}));
    assert_eq!(
        notifies(&account(rules.clone()), &mine, Some(5), None),
        Some(true)
    );
    let theirs = mentioning("hey", json!({"user_ids": [BOB]}));
    assert_eq!(
        notifies(&account(rules), &theirs, Some(5), None),
        Some(false)
    );
}

#[test]
fn a_room_mention_needs_the_sender_to_have_the_power() {
    let rules = json!({
        "override": [notify(
            ".m.rule.is_room_mention",
            json!([
                {"kind": "event_property_is", "key": r"content.m\.mentions.room", "value": true},
                {"kind": "sender_notification_permission", "key": "room"},
            ]),
        )],
    });
    let at_room = mentioning("everyone", json!({"room": true}));
    let powerless = json!({"users": {BOB: 0}, "users_default": 0, "notifications": {"room": 50}});
    assert_eq!(
        notifies(&account(rules.clone()), &at_room, Some(5), Some(&powerless)),
        Some(false)
    );
    let powerful = json!({"users": {BOB: 50}, "users_default": 0, "notifications": {"room": 50}});
    assert_eq!(
        notifies(&account(rules.clone()), &at_room, Some(5), Some(&powerful)),
        Some(true)
    );
    // Unknown power fails open: the fetch failed, and silence would be
    // invisible.
    assert_eq!(
        notifies(&account(rules), &at_room, Some(5), None),
        Some(true)
    );
}

// ---------------------------------------------------------------- undecidable

#[test]
fn unparsable_rules_json_is_none_not_false() {
    assert!(account_from_json("{{{").is_none());
    assert!(
        account_from_json(r#"{"rules": {}}"#).is_none(),
        "no user_id"
    );
}

#[test]
fn a_well_formed_file_parses() {
    let file = json!({
        "user_id": ADA, "display_name": "ada", "written_at": 1_700_000_000_000i64,
        "rules": {"underride": message_default()},
    })
    .to_string();
    let parsed = account_from_json(&file).expect("parses");
    assert_eq!(parsed.user_id, ADA);
    assert_eq!(parsed.display_name.as_deref(), Some("ada"));
    assert_eq!(notifies(&parsed, &msg("hello"), Some(5), None), Some(true));
}

#[test]
fn a_ruleset_that_is_not_an_object_is_none() {
    assert_eq!(
        notifies(&account(json!("nope")), &msg("hi"), Some(5), None),
        None
    );
}

#[test]
fn an_event_without_content_is_none() {
    let event = json!({"type": "m.room.message", "room_id": ROOM, "sender": BOB});
    assert_eq!(notifies(&account(json!({})), &event, Some(5), None), None);
}

// ---------------------------------------------------------------- C ABI

#[test]
fn the_c_abi_maps_the_verdict_to_one_zero_and_minus_one() {
    use loaf_push::loaf_push_notifies;
    use std::ffi::CString;

    let file = json!({
        "user_id": ADA, "rules": {"underride": message_default()},
    })
    .to_string();
    let rules = CString::new(file).unwrap();
    let event = CString::new(msg("hello").to_string()).unwrap();
    let verdict =
        unsafe { loaf_push_notifies(rules.as_ptr(), event.as_ptr(), 5, std::ptr::null()) };
    assert_eq!(verdict, 1);

    let muted = CString::new(
        json!({"user_id": ADA, "rules": {"override": [silent(".m.rule.master", json!([]))]}})
            .to_string(),
    )
    .unwrap();
    assert_eq!(
        unsafe { loaf_push_notifies(muted.as_ptr(), event.as_ptr(), 5, std::ptr::null()) },
        0
    );

    let bad = CString::new("{{{").unwrap();
    assert_eq!(
        unsafe { loaf_push_notifies(bad.as_ptr(), event.as_ptr(), 5, std::ptr::null()) },
        -1
    );
    assert_eq!(
        unsafe { loaf_push_notifies(std::ptr::null(), event.as_ptr(), 5, std::ptr::null()) },
        -1
    );
    assert_eq!(
        unsafe { loaf_push_notifies(rules.as_ptr(), std::ptr::null(), 5, std::ptr::null()) },
        -1
    );
}

#[test]
fn the_c_abi_reads_a_negative_member_count_as_unknown() {
    use loaf_push::loaf_push_notifies;
    use std::ffi::CString;

    let file = json!({
        "user_id": ADA,
        "rules": {"underride": [notify(
            ".m.rule.room_one_to_one",
            json!([{"kind": "room_member_count", "is": "2"}]),
        )]},
    })
    .to_string();
    let rules = CString::new(file).unwrap();
    let event = CString::new(msg("hello").to_string()).unwrap();
    assert_eq!(
        unsafe { loaf_push_notifies(rules.as_ptr(), event.as_ptr(), -1, std::ptr::null()) },
        1
    );
    assert_eq!(
        unsafe { loaf_push_notifies(rules.as_ptr(), event.as_ptr(), 3, std::ptr::null()) },
        0
    );
}

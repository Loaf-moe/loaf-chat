// The fixture is written by test/push/storage_pin_test.dart from a real
// SDK database: if this fails after an SDK upgrade, so would the phone.
use std::fs;

#[test]
fn decrypts_what_the_sdk_stored() {
    let raw = fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/fixtures/sdk.json"
    ))
    .unwrap();
    let f: serde_json::Value = serde_json::from_str(&raw).unwrap();
    let row: serde_json::Value = serde_json::from_str(f["session_row"].as_str().unwrap()).unwrap();
    let plain = loaf_push::decrypt(
        row["pickle"].as_str().unwrap(),
        f["user_id"].as_str().unwrap(),
        f["event_content"]["ciphertext"].as_str().unwrap(),
    )
    .expect("the SDK's pickle decrypts");
    let event: serde_json::Value = serde_json::from_str(&plain).unwrap();
    assert_eq!(event["content"]["body"], f["plaintext_body"]);
    assert_eq!(event["room_id"], f["room_id"]);
}

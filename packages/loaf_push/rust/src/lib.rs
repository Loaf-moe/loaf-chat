//! Decrypts one Megolm message for the iOS Notification Service Extension,
//! from a room key as the matrix SDK pickles it into loaf.sqlite. The
//! extension dlopens this from the app's Frameworks; there is no header,
//! so the two C functions below are the whole contract.

use std::ffi::{CStr, CString, c_char};
use vodozemac::megolm::{InboundGroupSession, InboundGroupSessionPickle, MegolmMessage};

/// The SDK's `String.toPickleKey()`: Dart's UTF-16 code units, each kept
/// to its low byte by `Uint8List.fromList`, cut or zero-padded to 32.
pub fn pickle_key(user_id: &str) -> [u8; 32] {
    let mut key = [0u8; 32];
    for (slot, unit) in key.iter_mut().zip(user_id.encode_utf16()) {
        *slot = unit as u8;
    }
    key
}

fn unpickle(pickle: &str, user_id: &str) -> Option<InboundGroupSession> {
    if let Ok(p) = InboundGroupSessionPickle::from_encrypted(pickle, &pickle_key(user_id)) {
        return Some(InboundGroupSession::from_pickle(p));
    }
    // Keys stored before the SDK moved to vodozemac's format; the SDK reads
    // these with the user id's UTF-8 as the key, and so does this.
    InboundGroupSession::from_libolm_pickle(pickle, user_id.as_bytes()).ok()
}

pub fn decrypt(pickle: &str, user_id: &str, ciphertext: &str) -> Option<String> {
    let mut session = unpickle(pickle, user_id)?;
    let message = MegolmMessage::from_base64(ciphertext).ok()?;
    let plain = session.decrypt(&message).ok()?;
    String::from_utf8(plain.plaintext).ok()
}

unsafe fn arg<'a>(p: *const c_char) -> Option<&'a str> {
    if p.is_null() {
        return None;
    }
    unsafe { CStr::from_ptr(p) }.to_str().ok()
}

/// The plaintext event JSON, to be freed with [loaf_push_free]; null when
/// anything is missing or wrong. Never panics across the boundary: the
/// release profile aborts on panic, and nothing here unwraps.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_push_decrypt(
    pickle: *const c_char,
    user_id: *const c_char,
    ciphertext: *const c_char,
) -> *mut c_char {
    let plain = unsafe { (arg(pickle), arg(user_id), arg(ciphertext)) };
    let (Some(p), Some(u), Some(c)) = plain else { return std::ptr::null_mut() };
    decrypt(p, u, c)
        .and_then(|s| CString::new(s).ok())
        .map_or(std::ptr::null_mut(), CString::into_raw)
}

#[unsafe(no_mangle)]
pub unsafe extern "C" fn loaf_push_free(p: *mut c_char) {
    if !p.is_null() {
        drop(unsafe { CString::from_raw(p) });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use vodozemac::megolm::{GroupSession, InboundGroupSession, SessionConfig};

    // Bytes from Dart: '@é:x'.toPickleKey(). é is U+00E9; one code unit, kept as 0xE9.
    #[test]
    fn pickle_key_truncates_code_units_like_dart() {
        let k = pickle_key("@é:x");
        assert_eq!(&k[..4], &[0x40, 0xE9, 0x3A, 0x78]);
        assert!(k[4..].iter().all(|b| *b == 0));
    }

    #[test]
    fn pickle_key_cuts_at_32() {
        let id = "@a-very-long-user-name-indeed:loaf.moe";
        assert_eq!(&pickle_key(id)[..], &id.as_bytes()[..32]);
    }

    #[test]
    fn astral_char_is_two_code_units() {
        // U+1F35E (🍞) is D83C DF5E in UTF-16; Dart keeps the low bytes 0x3C, 0x5E.
        assert_eq!(&pickle_key("🍞")[..2], &[0x3C, 0x5E]);
    }

    fn sealed(user: &str) -> (String, String) {
        let mut out = GroupSession::new(SessionConfig::version_1());
        let inbound = InboundGroupSession::new(&out.session_key(), SessionConfig::version_1());
        let pickle = inbound.pickle().encrypt(&pickle_key(user));
        let msg = out.encrypt(r#"{"type":"m.room.message","content":{"body":"hi"}}"#);
        (pickle, msg.to_base64())
    }

    #[test]
    fn decrypts_a_native_pickle() {
        let (pickle, ct) = sealed("@chris:loaf.moe");
        let plain = decrypt(&pickle, "@chris:loaf.moe", &ct).unwrap();
        assert!(plain.contains(r#""body":"hi""#));
    }

    #[test]
    fn wrong_user_is_none_not_a_panic() {
        let (pickle, ct) = sealed("@chris:loaf.moe");
        assert_eq!(decrypt(&pickle, "@mochi:loaf.moe", &ct), None);
    }

    #[test]
    fn garbage_is_none() {
        assert_eq!(decrypt("nope", "@a:b", "nope"), None);
    }

    #[test]
    fn c_abi_round_trip_and_null_inputs() {
        use std::ffi::{CStr, CString};
        let (pickle, ct) = sealed("@a:b");
        let (p, u, c) = (CString::new(pickle).unwrap(), CString::new("@a:b").unwrap(), CString::new(ct).unwrap());
        let out = unsafe { loaf_push_decrypt(p.as_ptr(), u.as_ptr(), c.as_ptr()) };
        assert!(!out.is_null());
        assert!(unsafe { CStr::from_ptr(out) }.to_str().unwrap().contains("hi"));
        unsafe { loaf_push_free(out) };
        assert!(unsafe { loaf_push_decrypt(std::ptr::null(), u.as_ptr(), c.as_ptr()) }.is_null());
    }
}

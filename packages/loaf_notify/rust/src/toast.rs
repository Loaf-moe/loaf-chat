//! What a message's toast says, as Windows' toast XML. Pure, so it is
//! tested on any host.

/// Windows shows nothing for a toast whose XML is over about 5 KB, and
/// says nothing about it. The whole document is kept under this, in bytes.
const MAX_XML_BYTES: usize = 5 * 1024;

/// An avatar path whose escaped URI is longer than this is left off: the
/// text matters more than the picture.
const MAX_IMAGE_BYTES: usize = 1024;

/// One notification. [avatar] is a picture on disk, drawn as the toast's
/// round logo.
pub struct Toast<'a> {
    pub title: &'a str,
    pub body: &'a str,
    pub room_id: &'a str,
    pub event_id: &'a str,
    pub avatar: Option<&'a str>,
}

/// Appends [c] XML-escaped, or nothing for the characters XML 1.0 can't
/// hold at all: a message may carry any of them, and one would sink the
/// toast.
fn push_escaped(out: &mut String, c: char) {
    match c {
        '&' => out.push_str("&amp;"),
        '<' => out.push_str("&lt;"),
        '>' => out.push_str("&gt;"),
        '"' => out.push_str("&quot;"),
        '\'' => out.push_str("&apos;"),
        '\t' | '\n' | '\r' => out.push(c),
        c if c < ' ' || c == '\u{fffe}' || c == '\u{ffff}' => {}
        c => out.push(c),
    }
}

/// XML-escaped [text], without the characters XML 1.0 can't hold at all.
pub fn escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        push_escaped(&mut out, c);
    }
    out
}

/// [text] escaped, and, if that is over [max] bytes, cut on a char
/// boundary with a trailing `…` so the result is within [max].
fn clip(text: &str, max: usize) -> String {
    let whole = escape(text);
    if whole.len() <= max {
        return whole;
    }
    const ELLIPSIS: char = '…';
    // Not even the ellipsis fits.
    if max < ELLIPSIS.len_utf8() {
        return String::new();
    }
    let room = max.saturating_sub(ELLIPSIS.len_utf8());
    let mut out = String::with_capacity(max);
    let mut piece = String::new();
    for c in text.chars() {
        piece.clear();
        push_escaped(&mut piece, c);
        if out.len() + piece.len() > room {
            break;
        }
        out.push_str(&piece);
    }
    out.push(ELLIPSIS);
    out
}

/// What a click hands back: the room and the event, split by a space,
/// which Matrix ids never contain.
pub fn launch(room_id: &str, event_id: &str) -> String {
    format!("{room_id} {event_id}")
}

pub fn parse_launch(args: &str) -> Option<(&str, &str)> {
    let (room, event) = args.split_once(' ')?;
    (!room.is_empty() && !event.is_empty() && !event.contains(' ')).then_some((room, event))
}

/// `C:\a b\c.png` as `file:///C:/a%20b/c.png`, the form a toast's image takes.
pub fn file_uri(path: &str) -> String {
    let mut uri = String::from("file:///");
    for c in path.chars() {
        match c {
            '\\' => uri.push('/'),
            ' ' => uri.push_str("%20"),
            '%' => uri.push_str("%25"),
            '#' => uri.push_str("%23"),
            '?' => uri.push_str("%3F"),
            c => uri.push(c),
        }
    }
    uri
}

/// A toast's group (by room) and tag (by event). Windows caps both at 64
/// characters, and a room id may be longer. FNV-1a 64 is stable across
/// runs and builds, so a toast left from an earlier run can still be
/// withdrawn.
pub fn key(id: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in id.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{hash:016x}")
}

/// The toast's XML, under [MAX_XML_BYTES] whatever the text: the title and
/// body are clipped (with `…`) to what the rest of the document leaves.
pub fn xml(toast: &Toast) -> String {
    let image = toast
        .avatar
        .map(|path| {
            format!(
                r#"<image placement="appLogoOverride" hint-crop="circle" src="{}"/>"#,
                escape(&file_uri(path))
            )
        })
        .filter(|image| image.len() <= MAX_IMAGE_BYTES)
        .unwrap_or_default();
    let launch = escape(&launch(toast.room_id, toast.event_id));
    let frame = format!(
        r#"<toast launch="{launch}"><visual><binding template="ToastGeneric"><text></text><text></text>{image}</binding></visual><audio silent="true"/></toast>"#,
    );
    // One byte under the limit, so "under 5 KB" holds strictly.
    let room = (MAX_XML_BYTES - 1).saturating_sub(frame.len());
    let title = clip(toast.title, room / 4);
    let body = clip(toast.body, room - title.len());
    format!(
        r#"<toast launch="{launch}"><visual><binding template="ToastGeneric"><text>{title}</text><text>{body}</text>{image}</binding></visual><audio silent="true"/></toast>"#,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    fn toast<'a>(body: &'a str, avatar: Option<&'a str>) -> Toast<'a> {
        Toast { title: "Ada in #general · Loaf", body, room_id: "!r:x", event_id: "$e", avatar }
    }

    #[test]
    fn text_is_escaped() {
        let xml = xml(&toast(r#"<b>"hi"</b> & 'co'"#, None));
        assert!(xml.contains("<text>&lt;b&gt;&quot;hi&quot;&lt;/b&gt; &amp; &apos;co&apos;</text>"));
    }

    #[test]
    fn control_characters_are_dropped() {
        assert_eq!(escape("a\u{1}b\u{1b}c\td\ne"), "abc\td\ne");
    }

    #[test]
    fn a_toast_is_silent_and_launches_its_message() {
        let xml = xml(&toast("hi", None));
        assert!(xml.contains(r#"<audio silent="true"/>"#));
        assert!(xml.starts_with(r#"<toast launch="!r:x $e">"#));
        assert!(!xml.contains("<image"));
    }

    #[test]
    fn the_avatar_is_a_round_logo_by_file_uri() {
        let xml = xml(&toast("hi", Some(r"C:\Users\Chris T\AppData\Local\Temp\a#1.png")));
        assert!(xml.contains(
            r#"<image placement="appLogoOverride" hint-crop="circle" src="file:///C:/Users/Chris%20T/AppData/Local/Temp/a%231.png"/>"#
        ));
    }

    #[test]
    fn launch_round_trips() {
        assert_eq!(parse_launch(&launch("!r:x", "$e")), Some(("!r:x", "$e")));
        assert_eq!(parse_launch("nothing"), None);
        assert_eq!(parse_launch(" $e"), None);
        assert_eq!(parse_launch("!r:x "), None);
    }

    #[test]
    fn keys_are_stable_and_fit_windows_limits() {
        let long = "!".repeat(300);
        assert_eq!(key(&long).len(), 16);
        assert_eq!(key("!r:x"), key("!r:x"));
        assert_ne!(key("!r:x"), key("!r:y"));
        // FNV-1a 64 of the empty string: pinned, so a build can't change it
        // and strand toasts from an earlier run.
        assert_eq!(key(""), "cbf29ce484222325");
    }

    #[test]
    fn a_long_body_still_makes_a_toast_under_5_kb() {
        // Dart cuts bodies at 400 characters; every one of them might
        // escape to six bytes.
        let body = "&".repeat(400);
        assert!(xml(&toast(&body, Some(r"C:\a.png"))).len() < 5 * 1024);
    }

    #[test]
    fn a_body_of_family_emoji_is_clipped_by_bytes_on_a_char_boundary() {
        // Dart cuts at 400 graphemes, not bytes: 400 families are ~10 KB.
        let body = "👨‍👩‍👧‍👦".repeat(400);
        let title = "T".repeat(300);
        let t = Toast { title: &title, body: &body, room_id: "!r:x", event_id: "$e", avatar: Some(r"C:\a.png") };
        let out = xml(&t);
        assert!(out.len() < 5 * 1024, "{} bytes", out.len());
        // Still whole, valid UTF-8 (a String is), and the body ends in …
        let body_text = out.split("<text>").nth(2).unwrap_or_default();
        assert!(body_text.starts_with("👨‍👩‍👧‍👦"), "{out}");
        assert!(body_text.ends_with("…</text><image placement=\"appLogoOverride\" hint-crop=\"circle\" src=\"file:///C:/a.png\"/></binding></visual><audio silent=\"true\"/></toast>"), "{out}");
        assert!(out.ends_with("</toast>"));
    }

    #[test]
    fn a_long_title_is_clipped_too() {
        let title = "&".repeat(5000);
        let t = Toast { title: &title, body: "hi", room_id: "!r:x", event_id: "$e", avatar: None };
        assert!(xml(&t).len() < 5 * 1024);
    }

    #[test]
    fn nothing_fits_in_less_than_an_ellipsis() {
        assert_eq!(clip("abc", 0), "");
        assert_eq!(clip("abc", 2), "");
    }

    #[test]
    fn a_huge_room_id_leaves_the_text_empty_not_an_ellipsis() {
        let room = format!("!{}:x", "r".repeat(6000));
        let t = Toast { title: "Ada", body: "hi", room_id: &room, event_id: "$e", avatar: None };
        assert!(xml(&t).contains("<text></text><text></text>"));
    }
}

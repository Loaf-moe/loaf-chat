//! The Media Engine reading a download through the byte stream while it is
//! written: the Windows twin of linux/rust/tests/playback.rs.
#![cfg(windows)]

use std::ffi::c_void;
use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;
use std::time::{Duration, Instant};

use loaf_media_win::player::{self, Player};
use loaf_streams::{self as streams, Progress, Reader};

fn sample() -> Vec<u8> {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../../assets/mock/media/proof.mp4");
    fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn part(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("loaf_media_win_playback");
    fs::create_dir_all(&dir).unwrap();
    dir.join(format!("{name}-{}.mp4.part", std::process::id()))
}

fn progress(received: u64, total: u64, complete: bool) -> Progress {
    Progress {
        received,
        total: Some(total),
        complete,
        failed: false,
    }
}

/// Writes [data] 32 KB at a time, reporting each step as the download
/// would, then completes and renames it, with the player still reading.
fn download(id: &str, path: PathBuf, data: Vec<u8>, step: Duration) -> thread::JoinHandle<()> {
    fs::write(&path, b"").unwrap();
    let total = data.len() as u64;
    streams::begin(id, path.clone(), progress(0, total, false));
    let id = id.to_owned();
    thread::spawn(move || {
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        let mut written = 0;
        for chunk in data.chunks(32 * 1024) {
            file.write_all(chunk).unwrap();
            written += chunk.len() as u64;
            let complete = written == total;
            if complete {
                drop(file);
                fs::rename(&path, path.with_extension("")).unwrap();
                streams::progress(&id, progress(written, total, true)).unwrap();
                return;
            }
            streams::progress(&id, progress(written, total, false)).unwrap();
            thread::sleep(step);
        }
    })
}

extern "C" fn count(user: *mut c_void) {
    // SAFETY: every test passes a &'static AtomicUsize.
    unsafe { &*(user as *const AtomicUsize) }.fetch_add(1, Ordering::SeqCst);
}

fn player(id: &str, calls: &'static AtomicUsize) -> Player {
    player::init().unwrap();
    let stream = streams::lookup(id).expect("begun");
    Player::new(
        Reader::new(stream),
        id,
        "mp4",
        count,
        calls as *const AtomicUsize as *mut c_void,
    )
    .unwrap()
}

fn wait_for(what: &str, timeout: Duration, mut done: impl FnMut() -> bool) {
    let start = Instant::now();
    while !done() {
        assert!(start.elapsed() < timeout, "timed out waiting for {what}");
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn plays_a_download_as_it_arrives() {
    static CALLS: AtomicUsize = AtomicUsize::new(0);
    let id = "win-play";
    let writer = download(id, part(id), sample(), Duration::from_millis(5));
    let p = player(id, &CALLS);

    wait_for("ready", Duration::from_secs(30), || p.ready() || p.failed());
    assert!(!p.failed(), "the sample did not load");
    p.play().unwrap();
    wait_for("a frame", Duration::from_secs(30), || {
        p.take_frame().is_some()
    });
    let frame = p.take_frame().unwrap();
    assert!(frame.width > 0 && frame.height > 0);
    wait_for("time to pass", Duration::from_secs(30), || {
        p.state().position_ms > 0
    });
    assert!(CALLS.load(Ordering::SeqCst) > 0);

    writer.join().unwrap();
    drop(p);
    // A frame Flutter still holds outlives the player.
    assert!(frame.width > 0);
    streams::end(id).unwrap();
}

#[test]
fn a_download_that_stops_does_not_hang_disposal() {
    static CALLS: AtomicUsize = AtomicUsize::new(0);
    let id = "win-stall";
    let path = part(id);
    let data = sample();
    // A little of the file, then nothing: the engine waits on a read.
    fs::write(&path, &data[..4096]).unwrap();
    streams::begin(id, path, progress(4096, data.len() as u64, false));
    let p = player(id, &CALLS);
    thread::sleep(Duration::from_millis(500));

    // Signing out ends every stream; disposing must then return promptly.
    streams::end(id).unwrap();
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        drop(p);
        let _ = tx.send(());
    });
    rx.recv_timeout(Duration::from_secs(10))
        .expect("disposing a player blocked on a stalled download hung");
}

#[test]
fn something_that_is_not_a_video_fails() {
    static CALLS: AtomicUsize = AtomicUsize::new(0);
    let id = "win-junk";
    let path = part(id);
    let junk: Vec<u8> = (0..200_000u32).map(|i| (i * 7919 % 251) as u8).collect();
    fs::write(&path, &junk).unwrap();
    streams::begin(
        id,
        path,
        progress(junk.len() as u64, junk.len() as u64, true),
    );
    let p = player(id, &CALLS);
    wait_for("the error", Duration::from_secs(30), || p.failed());
    assert!(p.state().error);
    drop(p);
    streams::end(id).unwrap();
}

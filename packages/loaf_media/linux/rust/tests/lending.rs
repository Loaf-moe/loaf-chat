//! The frame-lending contract the texture relies on: a frame taken through
//! the C API is the caller's own reference, whole and unchanging until it
//! is released, however the player moves on or goes.

use std::ffi::{CString, c_void};
use std::path::PathBuf;
use std::ptr;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::thread;
use std::time::{Duration, Instant};

use loaf_media_rs::ffi::*;
use loaf_media_rs::streams::{self, Progress};

fn sample_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../../assets/mock/media/proof.mp4")
}

/// The whole sample, already downloaded, as stream [id].
fn whole(id: &str) {
    let path = sample_path();
    let size = std::fs::metadata(&path).unwrap().len();
    streams::begin(
        id,
        path,
        Progress {
            received: size,
            total: Some(size),
            complete: true,
            failed: false,
        },
    );
}

unsafe extern "C" fn ignore(_: *mut c_void) {}

struct Taken {
    frame: *const LoafRsFrame,
    rgba: *const u8,
    len: usize,
}

fn take(player: *mut c_void) -> Option<Taken> {
    let (mut rgba, mut width, mut height) = (ptr::null(), 0u32, 0u32);
    let frame = unsafe { loaf_rs_player_take_frame(player, &mut rgba, &mut width, &mut height) };
    (!frame.is_null()).then(|| Taken {
        frame,
        rgba,
        len: (width * height * 4) as usize,
    })
}

fn checksum(t: &Taken) -> u64 {
    let bytes = unsafe { std::slice::from_raw_parts(t.rgba, t.len) };
    bytes.iter().enumerate().fold(0u64, |sum, (i, b)| {
        sum.wrapping_mul(31).wrapping_add(*b as u64 ^ i as u64)
    })
}

fn new_player(id: &str) -> *mut c_void {
    let cid = CString::new(id).unwrap();
    let player = unsafe { loaf_rs_player_new(cid.as_ptr(), Some(ignore), ptr::null_mut()) };
    assert!(!player.is_null());
    player
}

fn first_frame(player: *mut c_void) -> Taken {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(t) = take(player) {
            return t;
        }
        assert!(Instant::now() < deadline, "a frame within 20 s");
        thread::sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_taken_frame_outlives_its_player() {
    whole("lend-1");
    let player = new_player("lend-1");
    let frame = first_frame(player);
    let before = checksum(&frame);

    // The player goes, with GStreamer's threads and its own frames.
    unsafe { loaf_rs_player_free(player) };

    assert_eq!(checksum(&frame), before, "still whole and unchanged");
    unsafe { loaf_rs_frame_release(frame.frame) };
    streams::end("lend-1").unwrap();
}

#[test]
fn taken_frames_stay_whole_while_newer_ones_arrive() {
    whole("lend-2");
    let player = new_player("lend-2");
    let _ = first_frame(player);
    unsafe {
        loaf_rs_player_set_muted(player, 1);
        loaf_rs_player_play(player);
    }

    // Takers on other threads, as the raster thread is, while the streaming
    // thread keeps replacing the newest frame.
    let stop = Arc::new(AtomicBool::new(false));
    let address = player as usize;
    let takers: Vec<_> = (0..4)
        .map(|_| {
            let stop = Arc::clone(&stop);
            thread::spawn(move || {
                let mut taken = 0;
                while !stop.load(Ordering::Relaxed) {
                    let Some(t) = take(address as *mut c_void) else {
                        continue;
                    };
                    let first = checksum(&t);
                    thread::yield_now();
                    assert_eq!(checksum(&t), first, "a lent frame never changes");
                    unsafe { loaf_rs_frame_release(t.frame) };
                    taken += 1;
                }
                taken
            })
        })
        .collect();
    thread::sleep(Duration::from_millis(1500));
    stop.store(true, Ordering::Relaxed);
    let taken: usize = takers.into_iter().map(|t| t.join().unwrap()).sum();

    unsafe { loaf_rs_player_free(player) };
    streams::end("lend-2").unwrap();
    assert!(taken > 0);
}

#[test]
fn the_status_says_ready_once_prerolled_and_error_for_an_unknown_id() {
    whole("lend-3");
    let status = |player| {
        let (mut ready, mut error) = (0, 0);
        assert_eq!(
            unsafe { loaf_rs_player_status(player, &mut ready, &mut error) },
            0
        );
        (ready, error)
    };
    let wait = |player, want: fn((i32, i32)) -> bool| {
        let deadline = Instant::now() + Duration::from_secs(20);
        while !want(status(player)) {
            assert!(Instant::now() < deadline, "in time: {:?}", status(player));
            thread::sleep(Duration::from_millis(20));
        }
        status(player)
    };

    let good = new_player("lend-3");
    assert_eq!(wait(good, |(ready, _)| ready == 1), (1, 0));
    unsafe { loaf_rs_player_free(good) };
    streams::end("lend-3").unwrap();

    let bad = new_player("lend-nope");
    assert_eq!(wait(bad, |(_, error)| error == 1), (0, 1));
    unsafe { loaf_rs_player_free(bad) };
}

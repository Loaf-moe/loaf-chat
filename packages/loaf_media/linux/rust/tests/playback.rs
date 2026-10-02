//! `loafsrc` inside a real `playbin`, reading a file while it is written.

use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

use gst::prelude::*;
use loaf_media_rs::player::Player;
use loaf_media_rs::streams::{self, Progress};

fn sample() -> Vec<u8> {
    let path =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../../assets/mock/media/proof.mp4");
    fs::read(&path).unwrap_or_else(|e| panic!("{}: {e}", path.display()))
}

fn part(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join("loaf_media_rs_playback");
    fs::create_dir_all(&dir).unwrap();
    dir.join(format!("{name}-{}.mp4.part", std::process::id()))
}

/// Writes [data] to [path] 32 KB at a time, reporting each step as the
/// download would, then completes and renames it as the download does.
fn download(id: &str, path: PathBuf, data: Vec<u8>, step: Duration) -> thread::JoinHandle<()> {
    fs::write(&path, b"").unwrap();
    let total = data.len() as u64;
    streams::begin(
        id,
        path.clone(),
        Progress {
            received: 0,
            total: Some(total),
            complete: false,
            failed: false,
        },
    );
    let id = id.to_owned();
    thread::spawn(move || {
        let mut file = fs::OpenOptions::new().append(true).open(&path).unwrap();
        let mut written = 0;
        for chunk in data.chunks(32 * 1024) {
            file.write_all(chunk).unwrap();
            written += chunk.len() as u64;
            let complete = written == total;
            if complete {
                fs::rename(&path, path.with_extension("")).unwrap();
            }
            streams::progress(
                &id,
                Progress {
                    received: written,
                    total: Some(total),
                    complete,
                    failed: false,
                },
            )
            .unwrap();
            // Done the moment the last bytes are reported, so a test can
            // tell whether something happened while the file was arriving.
            if !complete {
                thread::sleep(step);
            }
        }
    })
}

fn playbin(id: &str) -> gst::Element {
    loaf_media_rs::init().unwrap();
    let fake = |name| {
        gst::ElementFactory::make("fakesink")
            .name(name)
            .build()
            .unwrap()
    };
    gst::ElementFactory::make("playbin")
        .property("uri", format!("loaf-media://{id}"))
        .property("video-sink", fake("video"))
        .property("audio-sink", fake("audio"))
        .build()
        .unwrap()
}

/// The first EOS or error on the bus, or None if neither came in [within].
fn outcome(pipeline: &gst::Element, within: Duration) -> Option<Result<(), String>> {
    let bus = pipeline.bus().unwrap();
    let deadline = std::time::Instant::now() + within;
    loop {
        let left = deadline.checked_duration_since(std::time::Instant::now())?;
        let msg = bus.timed_pop(gst::ClockTime::from_nseconds(left.as_nanos() as u64))?;
        match msg.view() {
            gst::MessageView::Eos(_) => return Some(Ok(())),
            gst::MessageView::Error(e) => {
                return Some(Err(format!("{} ({:?})", e.error(), e.debug())));
            }
            _ => {}
        }
    }
}

#[test]
fn plays_a_sample_through_loafsrc() {
    let path = part("t1");
    let writer = download("t1", path.clone(), sample(), Duration::from_millis(40));

    let pipeline = playbin("t1");
    pipeline.set_state(gst::State::Playing).unwrap();
    let got = outcome(&pipeline, Duration::from_secs(20));
    pipeline.set_state(gst::State::Null).unwrap();
    writer.join().unwrap();
    streams::end("t1").unwrap();
    let _ = fs::remove_file(path.with_extension(""));

    assert_eq!(got, Some(Ok(())), "playback reaches the end");
}

#[test]
fn refuses_an_unknown_id() {
    let pipeline = playbin("nope");
    // Failing to start may fail the state change itself; the bus says why.
    let _ = pipeline.set_state(gst::State::Paused);
    let got = outcome(&pipeline, Duration::from_secs(5));
    pipeline.set_state(gst::State::Null).unwrap();

    assert!(matches!(got, Some(Err(_))), "an error, not a hang: {got:?}");
}

#[test]
fn the_player_draws_frames_and_reports_the_end() {
    let path = part("p1");
    let writer = download("p1", path.clone(), sample(), Duration::from_millis(40));

    let (tx, rx) = mpsc::channel();
    let player = Player::new("p1", move || {
        let _ = tx.send(());
    })
    .unwrap();
    player.set_muted(true).unwrap();
    player.play().unwrap();

    // Notified for frames, then for the end.
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let mut frame = None;
    let mut state = player.state();
    while !state.ended && !state.error {
        let left = deadline
            .checked_duration_since(std::time::Instant::now())
            .expect("the end within 20 s");
        rx.recv_timeout(left).expect("notified");
        if frame.is_none() {
            frame = player.frame().map(|f| (f.width, f.height, f.rgba.len()));
        }
        state = player.state();
    }
    writer.join().unwrap();

    assert!(!state.error, "it played");
    let (width, height, len) = frame.expect("a frame was drawn");
    assert!(width > 0 && height > 0);
    assert_eq!(len, (width * height * 4) as usize, "tightly packed RGBA");
    assert!(state.duration_ms.is_some_and(|d| d > 0));

    drop(player);
    streams::end("p1").unwrap();
    let _ = fs::remove_file(path.with_extension(""));
}

#[test]
fn starts_before_the_download_finishes() {
    let path = part("s1");
    // About 4 s for the whole file.
    let writer = download("s1", path.clone(), sample(), Duration::from_millis(300));

    let (tx, rx) = mpsc::channel();
    let player = Player::new("s1", move || {
        let _ = tx.send(());
    })
    .unwrap();
    // The first frame, prerolled while paused.
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    while player.frame().is_none() && !player.state().error {
        let left = deadline
            .checked_duration_since(std::time::Instant::now())
            .expect("a frame within 20 s");
        rx.recv_timeout(left).expect("notified");
    }
    let downloading = !writer.is_finished();
    drop(player);
    writer.join().unwrap();
    streams::end("s1").unwrap();
    let _ = fs::remove_file(path.with_extension(""));

    assert!(
        downloading,
        "the first frame showed while the file was still arriving"
    );
}

/// The sample remuxed with its index (`moov`) after the media, as camera
/// originals are.
fn index_at_the_end() -> Vec<u8> {
    loaf_media_rs::init().unwrap();
    let src =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../../assets/mock/media/proof.mp4");
    let out = part("moov-at-end").with_extension("remuxed");
    let pipeline = gst::parse::launch(&format!(
        "filesrc location={} ! qtdemux name=d \
         d.video_0 ! queue ! mux.video_0 \
         d.audio_0 ! queue ! mux.audio_0 \
         mp4mux name=mux faststart=false ! filesink location={}",
        src.display(),
        out.display()
    ))
    .unwrap();
    pipeline.set_state(gst::State::Playing).unwrap();
    assert_eq!(outcome(&pipeline, Duration::from_secs(20)), Some(Ok(())));
    pipeline.set_state(gst::State::Null).unwrap();
    let data = fs::read(&out).unwrap();
    let _ = fs::remove_file(&out);

    // Top-level atoms, to be sure the index really comes after the media.
    let mut atoms = vec![];
    let mut at = 0;
    while at + 8 <= data.len() {
        let size = u32::from_be_bytes(data[at..at + 4].try_into().unwrap()) as usize;
        atoms.push(String::from_utf8_lossy(&data[at + 4..at + 8]).into_owned());
        if size < 8 {
            break;
        }
        at += size;
    }
    let at = |name| atoms.iter().position(|a| a == name);
    assert!(at("moov") > at("mdat"), "{atoms:?}");
    data
}

#[test]
fn plays_a_file_with_its_index_at_the_end() {
    let path = part("m1");
    let writer = download(
        "m1",
        path.clone(),
        index_at_the_end(),
        Duration::from_millis(40),
    );

    let pipeline = playbin("m1");
    pipeline.set_state(gst::State::Playing).unwrap();
    let got = outcome(&pipeline, Duration::from_secs(20));
    pipeline.set_state(gst::State::Null).unwrap();
    writer.join().unwrap();
    streams::end("m1").unwrap();
    let _ = fs::remove_file(path.with_extension(""));

    assert_eq!(got, Some(Ok(())), "playback reaches the end");
}

#[test]
fn seeks_ahead_of_the_download_and_plays_on() {
    let path = part("k1");
    let writer = download("k1", path.clone(), sample(), Duration::from_millis(200));

    let (tx, rx) = mpsc::channel();
    let player = Player::new("k1", move || {
        let _ = tx.send(());
    })
    .unwrap();
    player.set_muted(true).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(20);
    let wait = |done: &dyn Fn() -> bool| {
        while !done() {
            let left = deadline
                .checked_duration_since(std::time::Instant::now())
                .expect("in time");
            let _ = rx.recv_timeout(left.min(Duration::from_millis(100)));
        }
    };
    wait(&|| player.frame().is_some() || player.state().error);
    // Past what has arrived: the seek waits for the bytes, then plays on.
    player.seek(3000).unwrap();
    player.play().unwrap();
    wait(&|| player.state().ended || player.state().error);
    let state = player.state();
    writer.join().unwrap();
    drop(player);
    streams::end("k1").unwrap();
    let _ = fs::remove_file(path.with_extension(""));

    assert!(!state.error, "it played");
    assert!(state.position_ms.is_some_and(|p| p >= 3000), "{state:?}");
}

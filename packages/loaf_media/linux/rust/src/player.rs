//! One inline video: `playbin` reading `loaf-media://<id>` through
//! `loafsrc`, with an `appsink` keeping the newest RGBA frame for the
//! Flutter texture to copy.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::thread::JoinHandle;

use gst::glib;
use gst::prelude::*;
use gst_video::prelude::*;

/// Asks the bus thread to stop. Posted as the player goes.
const STOP: &str = "loaf-media-stop";

#[derive(Debug)]
pub struct PlayerError(pub String);

impl std::fmt::Display for PlayerError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for PlayerError {}

impl From<glib::BoolError> for PlayerError {
    fn from(e: glib::BoolError) -> Self {
        PlayerError(e.to_string())
    }
}

impl From<gst::StateChangeError> for PlayerError {
    fn from(e: gst::StateChangeError) -> Self {
        PlayerError(e.to_string())
    }
}

/// A video frame, tightly packed RGBA.
pub struct Frame {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PlayerState {
    pub position_ms: Option<u64>,
    pub duration_ms: Option<u64>,
    pub playing: bool,
    pub error: bool,
    pub ended: bool,
}

type Notify = Box<dyn Fn() + Send + Sync>;

/// What the streaming and bus threads share with the player's owner.
struct Shared {
    frame: Mutex<Option<Arc<Frame>>>,
    error: AtomicBool,
    ended: AtomicBool,
    /// Something new to show: a frame, the first preroll, an error or the
    /// end. Called on GStreamer's threads.
    notify: Notify,
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

pub struct Player {
    playbin: gst::Element,
    shared: Arc<Shared>,
    bus_thread: Option<JoinHandle<()>>,
    /// The frame last lent to C, kept alive until the next lend or drop.
    last_lent: Mutex<Option<Arc<Frame>>>,
}

impl Player {
    /// Starts prerolling `loaf-media://<id>` paused, so the first frame
    /// shows and Dart hears the video can play before anyone presses play.
    pub fn new(id: &str, notify: impl Fn() + Send + Sync + 'static) -> Result<Player, PlayerError> {
        crate::init().map_err(PlayerError)?;
        let shared = Arc::new(Shared {
            frame: Mutex::new(None),
            error: AtomicBool::new(false),
            ended: AtomicBool::new(false),
            notify: Box::new(notify),
        });

        let caps = gst_video::VideoCapsBuilder::new()
            .format(gst_video::VideoFormat::Rgba)
            .build();
        let sink = gst_app::AppSink::builder()
            .caps(&caps)
            // Only the newest frame matters to a texture that copies on
            // demand; older ones are dropped rather than queued.
            .max_buffers(1)
            .drop(true)
            .sync(true)
            .build();
        let on_sample = Arc::clone(&shared);
        let on_preroll = Arc::clone(&shared);
        sink.set_callbacks(
            gst_app::AppSinkCallbacks::builder()
                .new_sample(move |sink| {
                    let sample = sink.pull_sample().map_err(|_| gst::FlowError::Eos)?;
                    keep(&on_sample, &sample);
                    Ok(gst::FlowSuccess::Ok)
                })
                // Paused, and after a seek while paused: the frame to show.
                .new_preroll(move |sink| {
                    let sample = sink.pull_preroll().map_err(|_| gst::FlowError::Eos)?;
                    keep(&on_preroll, &sample);
                    Ok(gst::FlowSuccess::Ok)
                })
                .build(),
        );

        let playbin = gst::ElementFactory::make("playbin")
            .property("uri", format!("loaf-media://{id}"))
            .property("video-sink", &sink)
            .build()?;
        let bus = playbin
            .bus()
            .ok_or_else(|| PlayerError("playbin has no bus".to_owned()))?;
        let watched = Arc::clone(&shared);
        let bus_thread = std::thread::Builder::new()
            .name(format!("loaf-media-bus-{id}"))
            .spawn(move || watch(&bus, &watched))
            .map_err(|e| PlayerError(e.to_string()))?;

        let player = Player {
            playbin,
            shared,
            bus_thread: Some(bus_thread),
            last_lent: Mutex::new(None),
        };
        // An unknown id fails here or on the bus; either way the bus
        // thread records it, so the player stays usable to ask.
        let _ = player.playbin.set_state(gst::State::Paused);
        Ok(player)
    }

    pub fn play(&self) -> Result<(), PlayerError> {
        // Play at the end starts again from the top, as players do.
        if self.shared.ended.swap(false, Ordering::SeqCst) {
            self.seek(0)?;
        }
        self.playbin.set_state(gst::State::Playing)?;
        Ok(())
    }

    pub fn pause(&self) -> Result<(), PlayerError> {
        self.playbin.set_state(gst::State::Paused)?;
        Ok(())
    }

    pub fn seek(&self, position_ms: u64) -> Result<(), PlayerError> {
        self.shared.ended.store(false, Ordering::SeqCst);
        // Scrubbing seeks once, on release, so the exact frame is worth
        // decoding up to.
        self.playbin.seek_simple(
            gst::SeekFlags::FLUSH | gst::SeekFlags::ACCURATE,
            gst::ClockTime::from_mseconds(position_ms),
        )?;
        Ok(())
    }

    pub fn set_muted(&self, muted: bool) -> Result<(), PlayerError> {
        self.playbin.set_property("mute", muted);
        Ok(())
    }

    pub fn state(&self) -> PlayerState {
        let (_, current, pending) = self.playbin.state(gst::ClockTime::ZERO);
        let ended = self.shared.ended.load(Ordering::SeqCst);
        PlayerState {
            position_ms: self
                .playbin
                .query_position::<gst::ClockTime>()
                .map(gst::ClockTime::mseconds),
            duration_ms: self
                .playbin
                .query_duration::<gst::ClockTime>()
                .map(gst::ClockTime::mseconds),
            // What was asked for, so the button flips as it's pressed
            // rather than when the pipeline catches up.
            playing: !ended
                && (pending == gst::State::Playing
                    || (current == gst::State::Playing && pending == gst::State::VoidPending)),
            error: self.shared.error.load(Ordering::SeqCst),
            ended,
        }
    }

    /// The newest frame.
    pub fn frame(&self) -> Option<Arc<Frame>> {
        lock(&self.shared.frame).clone()
    }

    /// The newest frame, kept alive in the player until the next lend or
    /// until the player goes, so C can borrow its bytes.
    pub fn lend(&self) -> Option<Arc<Frame>> {
        let frame = self.frame();
        *lock(&self.last_lent) = frame.clone();
        frame
    }
}

impl Drop for Player {
    fn drop(&mut self) {
        // Stops and joins the streaming threads (a blocked fill is woken by
        // unlock), so nothing notifies after this.
        let _ = self.playbin.set_state(gst::State::Null);
        let Some(bus_thread) = self.bus_thread.take() else {
            return;
        };
        let Some(bus) = self.playbin.bus() else {
            return;
        };
        // Going to NULL set the bus flushing, which would drop the stop.
        bus.set_flushing(false);
        let stop = gst::message::Application::new(gst::Structure::new_empty(STOP));
        if bus.post(stop).is_ok() {
            let _ = bus_thread.join();
        }
        // If the stop could not be posted the thread is left blocked on a
        // bus nobody posts to, rather than hanging the caller on a join.
    }
}

/// Copies a frame out of GStreamer's buffer, row by row, so the texture
/// gets tightly packed RGBA whatever stride the decoder chose.
fn keep(shared: &Shared, sample: &gst::Sample) {
    let (Some(buffer), Some(caps)) = (sample.buffer(), sample.caps()) else {
        return;
    };
    let Ok(info) = gst_video::VideoInfo::from_caps(caps) else {
        return;
    };
    let Ok(frame) = gst_video::VideoFrameRef::from_buffer_ref_readable(buffer, &info) else {
        return;
    };
    let (width, height) = (frame.width(), frame.height());
    let row = width as usize * 4;
    let Ok(plane) = frame.plane_data(0) else {
        return;
    };
    let stride = frame.plane_stride()[0] as usize;
    let mut rgba = Vec::with_capacity(row * height as usize);
    for y in 0..height as usize {
        let Some(line) = plane.get(y * stride..y * stride + row) else {
            return;
        };
        rgba.extend_from_slice(line);
    }
    *lock(&shared.frame) = Some(Arc::new(Frame {
        width,
        height,
        rgba,
    }));
    (shared.notify)();
}

/// Records what the pipeline says until the player goes.
fn watch(bus: &gst::Bus, shared: &Shared) {
    for msg in bus.iter_timed(gst::ClockTime::NONE) {
        match msg.view() {
            gst::MessageView::Error(e) => {
                eprintln!(
                    "[loaf media] can't play: {} ({})",
                    e.error(),
                    e.debug().as_deref().unwrap_or("no detail")
                );
                shared.error.store(true, Ordering::SeqCst);
                (shared.notify)();
            }
            gst::MessageView::Eos(_) => {
                shared.ended.store(true, Ordering::SeqCst);
                (shared.notify)();
            }
            // Prerolled: an audio-only file has no frame to say so.
            gst::MessageView::AsyncDone(_) => (shared.notify)(),
            gst::MessageView::Application(a) if a.structure().is_some_and(|s| s.name() == STOP) => {
                return;
            }
            _ => {}
        }
    }
}

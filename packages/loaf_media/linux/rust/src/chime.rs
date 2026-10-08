//! The chime on Linux: GStreamer's playbin on a thread of its own, so the
//! first chime's registry scan and every state change stay off the
//! platform thread.

use std::path::{Component, Path, PathBuf};
use std::sync::OnceLock;
use std::sync::mpsc::{self, Receiver, Sender};

use gst::glib;
use gst::prelude::*;

/// Where Flutter bundles [asset] for the executable at [exe]: `data/
/// flutter_assets` beside it, in a plain bundle, an AppImage and a
/// Flatpak alike. None for a key that would leave that folder.
pub fn asset_path(exe: &Path, asset: &str) -> Option<PathBuf> {
    let key = Path::new(asset);
    if key.components().any(|c| !matches!(c, Component::Normal(_))) {
        return None;
    }
    Some(exe.parent()?.join("data/flutter_assets").join(key))
}

/// Queues [asset] to play. Returns at once.
pub fn play(asset: &str) -> Result<(), String> {
    let exe = std::env::current_exe().map_err(|e| format!("exe: {e}"))?;
    let path = asset_path(&exe, asset).ok_or_else(|| format!("bad asset {asset}"))?;
    sender()
        .send(path)
        .map_err(|_| "the chime thread is gone".to_owned())
}

fn sender() -> &'static Sender<PathBuf> {
    static SENDER: OnceLock<Sender<PathBuf>> = OnceLock::new();
    SENDER.get_or_init(|| {
        let (tx, rx) = mpsc::channel();
        // If the thread can't start, `rx` drops with the closure and
        // sends fail, which play() reports.
        let _ = std::thread::Builder::new()
            .name("loaf-chime".into())
            .spawn(move || run(rx));
        tx
    })
}

fn run(rx: Receiver<PathBuf>) {
    let mut warned = false;
    // Once only: a machine with no sound output would otherwise log on
    // every message.
    let mut warn = |what: String| {
        if !warned {
            warned = true;
            eprintln!("[loaf media] chime: {what}");
        }
    };
    let mut playbin: Option<gst::Element> = None;
    while let Ok(mut path) = rx.recv() {
        // A burst plays once: only the newest request matters.
        while let Ok(newer) = rx.try_recv() {
            path = newer;
        }
        if let Err(e) = crate::init() {
            warn(e);
            continue;
        }
        if playbin.is_none() {
            match gst::ElementFactory::make("playbin").build() {
                Ok(p) => playbin = Some(p),
                Err(e) => {
                    warn(format!("playbin: {e}"));
                    continue;
                }
            }
        }
        let Some(p) = playbin.as_ref() else { continue };
        if let Err(e) = play_once(p, &path) {
            warn(e);
        }
    }
}

fn play_once(playbin: &gst::Element, path: &Path) -> Result<(), String> {
    let uri = glib::filename_to_uri(path, None).map_err(|e| format!("uri: {e}"))?;
    playbin
        .set_state(gst::State::Null)
        .map_err(|e| format!("reset: {e}"))?;
    playbin.set_property("uri", uri.as_str());
    let outcome = playbin
        .set_state(gst::State::Playing)
        .map_err(|e| format!("play: {e}"))
        .and_then(|_| {
            let bus = playbin.bus().ok_or_else(|| "no bus".to_owned())?;
            match bus.timed_pop_filtered(
                gst::ClockTime::from_seconds(5),
                &[gst::MessageType::Eos, gst::MessageType::Error],
            ) {
                Some(m) => match m.view() {
                    gst::MessageView::Error(e) => Err(format!("{}", e.error())),
                    _ => Ok(()),
                },
                None => Ok(()), // Timed out; stop it anyway.
            }
        });
    // Back to Null either way, so the sound device isn't held between chimes.
    let _ = playbin.set_state(gst::State::Null);
    outcome
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn assets_sit_in_the_bundle_beside_the_executable() {
        assert_eq!(
            asset_path(
                Path::new("/opt/loaf/loaf_native"),
                "assets/sounds/chime.wav"
            ),
            Some(PathBuf::from(
                "/opt/loaf/data/flutter_assets/assets/sounds/chime.wav"
            ))
        );
    }

    #[test]
    fn an_asset_key_cannot_climb_out_of_the_bundle() {
        assert_eq!(
            asset_path(Path::new("/opt/loaf/loaf_native"), "../../etc/passwd"),
            None
        );
        assert_eq!(
            asset_path(Path::new("/opt/loaf/loaf_native"), "/etc/passwd"),
            None
        );
    }
}

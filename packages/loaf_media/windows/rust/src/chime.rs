//! The chime on Windows: PlaySound, which plays asynchronously and cuts
//! off a chime still sounding when the next one starts. SND_SYSTEM plays it
//! as a system notification sound, at the system-sounds volume: the
//! counterpart of Apple's alert volume.

use std::path::{Component, Path, PathBuf};

/// Where Flutter bundles [asset] for the exe at [exe]: `data\flutter_assets`
/// beside it. None for a key that would leave that folder.
pub fn asset_path(exe: &Path, asset: &str) -> Option<PathBuf> {
    let mut path = exe.parent()?.join("data").join("flutter_assets");
    for part in asset.split('/') {
        let part = Path::new(part);
        if !matches!(part.components().next(), Some(Component::Normal(_)))
            || part.components().count() != 1
        {
            return None;
        }
        path.push(part);
    }
    Some(path)
}

#[cfg(windows)]
pub fn play(asset: &str) -> Result<(), String> {
    use windows::Win32::Media::Audio::{
        PlaySoundW, SND_ASYNC, SND_FILENAME, SND_NODEFAULT, SND_SYSTEM,
    };
    use windows::core::HSTRING;

    let exe = std::env::current_exe().map_err(|e| format!("exe: {e}"))?;
    let path = asset_path(&exe, asset).ok_or_else(|| format!("bad asset {asset}"))?;
    let wide = HSTRING::from(path.as_os_str());
    // SAFETY: `wide` outlives the call; SND_ASYNC copies the name before
    // returning.
    let ok = unsafe {
        PlaySoundW(
            &wide,
            None,
            SND_FILENAME | SND_ASYNC | SND_NODEFAULT | SND_SYSTEM,
        )
    };
    if ok.as_bool() {
        Ok(())
    } else {
        Err(format!("PlaySound refused {}", path.display()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Built from components, not a `C:\` literal: on a non-Windows host
    // a backslash isn't a separator, so a literal has no parent.
    fn install() -> PathBuf {
        PathBuf::from("Program Files").join("Loaf")
    }

    #[test]
    fn assets_sit_in_data_beside_the_exe() {
        assert_eq!(
            asset_path(
                &install().join("loaf_native.exe"),
                "assets/sounds/chime.wav"
            ),
            Some(
                install()
                    .join("data")
                    .join("flutter_assets")
                    .join("assets")
                    .join("sounds")
                    .join("chime.wav")
            )
        );
    }

    #[test]
    fn an_asset_key_cannot_climb_out() {
        let exe = install().join("loaf_native.exe");
        assert_eq!(asset_path(&exe, "../x.wav"), None);
        assert_eq!(asset_path(&exe, "assets/../../x.wav"), None);
        assert_eq!(asset_path(&exe, "/x.wav"), None);
        assert_eq!(asset_path(&exe, ""), None);
    }
}

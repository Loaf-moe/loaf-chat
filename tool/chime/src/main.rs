//! Writes the chime into the repository: `cargo run --manifest-path
//! tool/chime/Cargo.toml`. The outputs are checked in; run this only to
//! change the sound.

use std::path::Path;
use std::process::ExitCode;

fn main() -> ExitCode {
    // tool/chime → the repository root, wherever this is run from.
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    let samples = chime::samples();
    let outputs = [
        (root.join("assets/sounds/chime.wav"), chime::wav(&samples)),
        (root.join("ios/Runner/chime.caf"), chime::caf(&samples)),
    ];
    for (path, bytes) in outputs {
        if let Some(dir) = path.parent()
            && let Err(e) = std::fs::create_dir_all(dir)
        {
            eprintln!("chime: {}: {e}", dir.display());
            return ExitCode::FAILURE;
        }
        if let Err(e) = std::fs::write(&path, bytes) {
            eprintln!("chime: {}: {e}", path.display());
            return ExitCode::FAILURE;
        }
        println!("wrote {}", path.display());
    }
    ExitCode::SUCCESS
}

//! Checks on the gpui patch that run without a window. The vendored crates'
//! own test targets can't build outside Zed's monorepo (they read its font
//! assets and dev-dependencies), so the patch is tested from here.

use gpui::{I420Planes, VideoFrameError, VideoStream, YuvMatrix, YuvRange};
use std::sync::Arc;

struct Owned {
    width: u32,
    height: u32,
    planes: [(Vec<u8>, u32); 3],
}

impl I420Planes for Owned {
    fn width(&self) -> u32 {
        self.width
    }
    fn height(&self) -> u32 {
        self.height
    }
    fn plane(&self, index: usize) -> (&[u8], u32) {
        let (data, stride) = &self.planes[index];
        (data, *stride)
    }
}

fn owned(width: u32, height: u32, pad: u32) -> Owned {
    let (cw, ch) = (width / 2, height / 2);
    Owned {
        width,
        height,
        planes: [
            (vec![0; ((width + pad) * height) as usize], width + pad),
            (vec![0; ((cw + pad) * ch) as usize], cw + pad),
            (vec![0; ((cw + pad) * ch) as usize], cw + pad),
        ],
    }
}

fn frame(stream: &VideoStream, p: Owned) -> Result<Arc<gpui::VideoFrame>, VideoFrameError> {
    stream.frame(Arc::new(p), YuvMatrix::Bt709, YuvRange::Limited)
}

#[test]
fn frames_accept_tight_and_padded_planes_and_count_generations() {
    let stream = VideoStream::new();
    let a = frame(&stream, owned(64, 32, 0)).unwrap();
    let b = frame(&stream, owned(64, 32, 16)).unwrap();
    assert_eq!((a.generation(), b.generation()), (1, 2));
    assert_eq!(a.stream(), b.stream());
    assert_ne!(VideoStream::new().id(), stream.id());
}

#[test]
fn frames_the_renderer_would_overrun_are_rejected() {
    let stream = VideoStream::new();
    assert_eq!(
        frame(&stream, owned(63, 32, 0)).unwrap_err(),
        VideoFrameError::BadDimensions {
            width: 63,
            height: 32
        }
    );
    assert!(frame(&stream, owned(0, 0, 0)).is_err());

    let mut short = owned(64, 32, 0);
    short.planes[2].0.pop();
    assert_eq!(
        frame(&stream, short).unwrap_err(),
        VideoFrameError::BadPlane { index: 2 }
    );

    let mut narrow = owned(64, 32, 0);
    narrow.planes[0].1 = 63;
    assert_eq!(
        frame(&stream, narrow).unwrap_err(),
        VideoFrameError::BadPlane { index: 0 }
    );
}

/// The renderer compiles exactly these concatenations; see
/// `STORAGE_BUFFER_SHADERS` and `WEBGL_SHADERS` in `wgpu_renderer.rs`.
#[test]
fn shaders_validate() {
    const SHARED: &str = include_str!("../vendor/gpui-pre-wgpu/src/shaders.wgsl");
    for (name, transport) in [
        (
            "storage",
            include_str!("../vendor/gpui-pre-wgpu/src/shaders_storage.wgsl"),
        ),
        (
            "webgl",
            include_str!("../vendor/gpui-pre-wgpu/src/shaders_webgl.wgsl"),
        ),
    ] {
        let source = format!("{SHARED}{transport}");
        let module = naga::front::wgsl::parse_str(&source)
            .unwrap_or_else(|e| panic!("{name}: {}", e.emit_to_string(&source)));
        naga::valid::Validator::new(
            naga::valid::ValidationFlags::all(),
            naga::valid::Capabilities::empty(),
        )
        .validate(&module)
        .unwrap_or_else(|e| panic!("{name}: {e:?}"));
        for entry in ["vs_surface", "fs_surface"] {
            assert!(
                module.entry_points.iter().any(|e| e.name == entry),
                "{name}: no {entry}"
            );
        }
    }
}

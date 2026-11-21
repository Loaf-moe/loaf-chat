//! Decoded video frames for [`surface`](crate::surface) on renderers without a
//! platform image buffer (the wgpu renderer on Linux, and later Windows).
//!
//! A frame is planar 8-bit YUV 4:2:0 (I420), the layout software decoders and
//! libwebrtc hand out. The renderer uploads the three planes as they are and
//! converts to RGB in the fragment shader, so no CPU colour conversion or
//! repacking happens anywhere on the way to the screen.

use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// Pixels of one I420 frame. Implemented by whatever owns the decoded buffer,
/// so a decoder's own allocation can be shown without copying it first.
pub trait I420Planes: Send + Sync + 'static {
    /// Width of the luma plane in pixels.
    fn width(&self) -> u32;
    /// Height of the luma plane in pixels.
    fn height(&self) -> u32;
    /// Plane `0` (Y), `1` (U) or `2` (V): its bytes and the distance in bytes
    /// between the starts of consecutive rows.
    fn plane(&self, index: usize) -> (&[u8], u32);
}

/// Which YUV→RGB matrix a frame was encoded with.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum YuvMatrix {
    /// ITU-R BT.601, standard definition.
    Bt601,
    /// ITU-R BT.709, high definition. What WebRTC sends unless told otherwise.
    #[default]
    Bt709,
}

/// Whether a frame uses the full 0–255 range or video range (16–235 luma,
/// 16–240 chroma).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Hash)]
pub enum YuvRange {
    /// Video range, as decoders produce by default.
    #[default]
    Limited,
    /// Full range.
    Full,
}

/// Why a buffer can't be a frame.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VideoFrameError {
    /// Width or height is zero, or odd (4:2:0 needs both even here).
    BadDimensions {
        /// The width given.
        width: u32,
        /// The height given.
        height: u32,
    },
    /// A plane's stride is narrower than its row, or its data shorter than
    /// `stride * rows`.
    BadPlane {
        /// `0` (Y), `1` (U) or `2` (V).
        index: usize,
    },
}

impl fmt::Display for VideoFrameError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::BadDimensions { width, height } => {
                write!(f, "unsupported frame size {width}x{height}")
            }
            Self::BadPlane { index } => write!(f, "plane {index} is too small for its frame"),
        }
    }
}

impl std::error::Error for VideoFrameError {}

/// Identifies one stream of frames, such as one participant's camera. The
/// renderer keeps one set of textures per stream and reuses them frame to
/// frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct VideoStreamId(u64);

impl VideoStreamId {
    /// The raw id, for renderers.
    pub fn as_u64(self) -> u64 {
        self.0
    }
}

/// The producer side of a stream. Cheap to share between threads: a decoder
/// thread calls [`VideoStream::frame`] and hands the result to the UI.
#[derive(Debug)]
pub struct VideoStream {
    id: VideoStreamId,
    generation: AtomicU64,
}

impl Default for VideoStream {
    fn default() -> Self {
        Self::new()
    }
}

impl VideoStream {
    /// A stream with an id no other stream in this process has.
    pub fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        Self {
            id: VideoStreamId(NEXT.fetch_add(1, Ordering::Relaxed)),
            generation: AtomicU64::new(0),
        }
    }

    /// This stream's id.
    pub fn id(&self) -> VideoStreamId {
        self.id
    }

    /// The next frame of this stream, after checking its planes are large
    /// enough that the renderer can read them without going out of bounds.
    pub fn frame(
        &self,
        planes: Arc<dyn I420Planes>,
        matrix: YuvMatrix,
        range: YuvRange,
    ) -> Result<Arc<VideoFrame>, VideoFrameError> {
        validate(planes.as_ref())?;
        Ok(Arc::new(VideoFrame {
            stream: self.id,
            generation: self.generation.fetch_add(1, Ordering::Relaxed) + 1,
            matrix,
            range,
            planes,
        }))
    }
}

fn validate(planes: &dyn I420Planes) -> Result<(), VideoFrameError> {
    let (width, height) = (planes.width(), planes.height());
    if width == 0 || height == 0 || width % 2 != 0 || height % 2 != 0 {
        return Err(VideoFrameError::BadDimensions { width, height });
    }
    for index in 0..3 {
        let (row, rows) = if index == 0 {
            (width, height)
        } else {
            (width / 2, height / 2)
        };
        let (data, stride) = planes.plane(index);
        let needed = u64::from(stride) * u64::from(rows);
        if stride < row || (data.len() as u64) < needed {
            return Err(VideoFrameError::BadPlane { index });
        }
    }
    Ok(())
}

/// One validated frame of a [`VideoStream`].
pub struct VideoFrame {
    stream: VideoStreamId,
    generation: u64,
    matrix: YuvMatrix,
    range: YuvRange,
    planes: Arc<dyn I420Planes>,
}

impl VideoFrame {
    /// The stream this frame belongs to.
    pub fn stream(&self) -> VideoStreamId {
        self.stream
    }

    /// Increases by one with each frame of the stream; a renderer that already
    /// uploaded this generation can skip the upload.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// Luma width in pixels.
    pub fn width(&self) -> u32 {
        self.planes.width()
    }

    /// Luma height in pixels.
    pub fn height(&self) -> u32 {
        self.planes.height()
    }

    /// The encoding matrix.
    pub fn matrix(&self) -> YuvMatrix {
        self.matrix
    }

    /// The encoding range.
    pub fn range(&self) -> YuvRange {
        self.range
    }

    /// Plane `0`, `1` or `2`, already checked against the frame size.
    pub fn plane(&self, index: usize) -> (&[u8], u32) {
        self.planes.plane(index)
    }
}

impl PartialEq for VideoFrame {
    fn eq(&self, other: &Self) -> bool {
        self.stream == other.stream && self.generation == other.generation
    }
}

impl Eq for VideoFrame {}

impl fmt::Debug for VideoFrame {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("VideoFrame")
            .field("stream", &self.stream)
            .field("generation", &self.generation)
            .field("size", &(self.width(), self.height()))
            .field("matrix", &self.matrix)
            .field("range", &self.range)
            .finish()
    }
}


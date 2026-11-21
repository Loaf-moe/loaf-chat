//! Proof of concept: WebRTC-shaped video drawn by GPUI's wgpu renderer on
//! Linux, with the I420 planes uploaded as textures and converted in a shader.
//!
//! Each tile is one stream of synthetic I420 frames at a fixed rate: BT.709
//! limited-range colour bars (so a screenshot can be checked against known
//! RGB values) and a white bar that moves one step per frame. Plane strides
//! are padded the way decoders pad them. Frames are generated once up front
//! and shared, so producing a frame costs nothing and what the process spends
//! is the display path alone.
//!
//! ```text
//! gpui-video-poc [--tiles N] [--res WxH] [--fps F] [--seconds S] [--idle]
//! ```

use gpui::{
    AnyView, App, Bounds, Context, I420Planes, ObjectFit, Render, StyleRefinement, VideoFrame,
    VideoStream, Window, WindowBounds, WindowOptions, YuvMatrix, YuvRange, div, prelude::*, px,
    rgb, size, surface,
};
use gpui_platform::application;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{Duration, Instant};

/// Distinct frames per loop; the moving bar crosses the frame in this many.
const LOOP: usize = 60;
/// Extra bytes at the end of every row, as decoders leave for alignment.
const STRIDE_PAD: u32 = 32;

#[derive(Clone, Copy)]
struct Args {
    tiles: usize,
    width: u32,
    height: u32,
    fps: u32,
    seconds: u64,
    idle: bool,
}

fn parse_args() -> Args {
    let mut args = Args {
        tiles: 4,
        width: 1280,
        height: 720,
        fps: 30,
        seconds: 0,
        idle: false,
    };
    let mut it = std::env::args().skip(1);
    while let Some(flag) = it.next() {
        let mut value = || it.next().unwrap_or_else(|| panic!("{flag} needs a value"));
        match flag.as_str() {
            "--tiles" => args.tiles = value().parse().expect("--tiles N"),
            "--fps" => args.fps = value().parse().expect("--fps F"),
            "--seconds" => args.seconds = value().parse().expect("--seconds S"),
            "--res" => {
                let v = value();
                let (w, h) = v.split_once('x').expect("--res WxH");
                args.width = w.parse().expect("--res WxH");
                args.height = h.parse().expect("--res WxH");
            }
            "--idle" => args.idle = true,
            other => panic!("unknown argument {other}"),
        }
    }
    assert!(args.tiles > 0 && args.fps > 0, "--tiles and --fps must be positive");
    args
}

/// One decoded frame, owned. Stands in for a libwebrtc `I420Buffer`.
struct Planes {
    width: u32,
    height: u32,
    data: [(Vec<u8>, u32); 3],
}

impl I420Planes for Planes {
    fn width(&self) -> u32 {
        self.width
    }
    fn height(&self) -> u32 {
        self.height
    }
    fn plane(&self, index: usize) -> (&[u8], u32) {
        let (data, stride) = &self.data[index];
        (data, *stride)
    }
}

/// 100% colour bars, BT.709 limited range: white, yellow, cyan, green,
/// magenta, red, blue, black.
const BARS: [(u8, u8, u8); 8] = [
    (235, 128, 128),
    (219, 16, 138),
    (188, 154, 16),
    (173, 42, 26),
    (78, 214, 230),
    (63, 102, 240),
    (32, 240, 118),
    (16, 128, 128),
];

fn synth(width: u32, height: u32, step: usize) -> Planes {
    let (cw, ch) = (width / 2, height / 2);
    let (ys, cs) = (width + STRIDE_PAD, cw + STRIDE_PAD);
    let mut y = vec![0u8; (ys * height) as usize];
    let mut u = vec![0u8; (cs * ch) as usize];
    let mut v = vec![0u8; (cs * ch) as usize];

    let bar_x = (step as u32 * width / LOOP as u32) & !1;
    let bar_w = (width / 32).max(2) & !1;
    let bars_end = height * 2 / 3;

    let sample = |x: u32, row: u32| -> (u8, u8, u8) {
        if row < bars_end {
            BARS[(x * BARS.len() as u32 / width) as usize]
        } else if x >= bar_x && x < bar_x + bar_w {
            BARS[0]
        } else {
            // A luma ramp under the bars, so banding or a wrong range shows.
            (16 + (x * 219 / width) as u8, 128, 128)
        }
    };

    for row in 0..height {
        for x in 0..width {
            y[(row * ys + x) as usize] = sample(x, row).0;
        }
    }
    for row in 0..ch {
        for x in 0..cw {
            let (_, cb, cr) = sample(x * 2, row * 2);
            u[(row * cs + x) as usize] = cb;
            v[(row * cs + x) as usize] = cr;
        }
    }
    Planes {
        width,
        height,
        data: [(y, ys), (u, cs), (v, cs)],
    }
}

/// Paints per second across all tiles, for the summary.
static PAINTS: AtomicU64 = AtomicU64::new(0);
static DELIVERED: AtomicU64 = AtomicU64::new(0);

struct Tile {
    name: String,
    frame: Option<Arc<VideoFrame>>,
}

impl Tile {
    fn new(
        index: usize,
        loop_frames: Arc<Vec<Arc<Planes>>>,
        args: Args,
        cx: &mut Context<Self>,
    ) -> Self {
        let stream = VideoStream::new();
        let name = format!("tile {index} · {}x{} @ {} fps", args.width, args.height, args.fps);
        let first = stream
            .frame(loop_frames[0].clone(), YuvMatrix::Bt709, YuvRange::Limited)
            .ok();
        if !args.idle {
            let period = Duration::from_secs_f64(1.0 / f64::from(args.fps));
            cx.spawn(async move |this, cx| {
                // Streams start out of phase, as real participants do.
                let mut step = index * LOOP / 4;
                let mut next = Instant::now() + period;
                loop {
                    let now = Instant::now();
                    cx.background_executor()
                        .timer(next.saturating_duration_since(now))
                        .await;
                    next += period;
                    step = (step + 1) % LOOP;
                    let planes = loop_frames[step].clone();
                    let Ok(frame) = stream.frame(planes, YuvMatrix::Bt709, YuvRange::Limited)
                    else {
                        continue;
                    };
                    DELIVERED.fetch_add(1, Ordering::Relaxed);
                    let alive = this.update(cx, |tile, cx| {
                        tile.frame = Some(frame);
                        cx.notify();
                    });
                    if alive.is_err() {
                        break;
                    }
                }
            })
            .detach();
        }
        Tile { name, frame: first }
    }
}

impl Render for Tile {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        PAINTS.fetch_add(1, Ordering::Relaxed);
        div()
            .size_full()
            .relative()
            .bg(rgb(0x101010))
            .children(
                self.frame
                    .clone()
                    .map(|f| surface(f).object_fit(ObjectFit::Contain).size_full()),
            )
            .child(
                div()
                    .absolute()
                    .top_2()
                    .left_2()
                    .px_2()
                    .py_1()
                    .rounded_md()
                    .bg(gpui::black().opacity(0.6))
                    .text_color(gpui::white())
                    .text_sm()
                    .child(self.name.clone()),
            )
    }
}

struct Grid {
    tiles: Vec<AnyView>,
    columns: usize,
}

impl Render for Grid {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        let rows = self.tiles.chunks(self.columns).map(|row| {
            div().flex().flex_1().gap_1().children(row.iter().map(|tile| {
                div()
                    .flex_1()
                    .h_full()
                    // Only the tile that got a frame re-renders.
                    .child(tile.clone().cached(StyleRefinement::default().size_full()))
            }))
        });
        div()
            .size_full()
            .flex()
            .flex_col()
            .gap_1()
            .p_1()
            .bg(rgb(0x000000))
            .children(rows)
    }
}

fn main() {
    let args = parse_args();
    let started = Instant::now();
    let loop_frames: Arc<Vec<Arc<Planes>>> = Arc::new(
        (0..LOOP)
            .map(|step| Arc::new(synth(args.width, args.height, step)))
            .collect(),
    );
    eprintln!(
        "generated {LOOP} frames of {}x{} in {:?}",
        args.width,
        args.height,
        started.elapsed()
    );

    application().run(move |cx: &mut App| {
        let columns = (args.tiles as f64).sqrt().ceil() as usize;
        let bounds = Bounds::centered(None, size(px(1600.), px(900.)), cx);
        cx.open_window(
            WindowOptions {
                window_bounds: Some(WindowBounds::Windowed(bounds)),
                ..Default::default()
            },
            |_, cx| {
                cx.new(|cx| Grid {
                    tiles: (0..args.tiles)
                        .map(|i| {
                            let frames = loop_frames.clone();
                            AnyView::from(cx.new(|cx| Tile::new(i, frames, args, cx)))
                        })
                        .collect(),
                    columns,
                })
            },
        )
        .expect("open window");
        cx.activate(true);

        cx.spawn(async move |cx| {
            let mut last = (Instant::now(), 0, 0);
            let mut elapsed = 0;
            loop {
                cx.background_executor().timer(Duration::from_secs(5)).await;
                elapsed += 5;
                let (paints, delivered) = (
                    PAINTS.load(Ordering::Relaxed),
                    DELIVERED.load(Ordering::Relaxed),
                );
                let secs = last.0.elapsed().as_secs_f64();
                eprintln!(
                    "{elapsed:>4}s  frames delivered {:.1}/s  tile paints {:.1}/s",
                    (delivered - last.2) as f64 / secs,
                    (paints - last.1) as f64 / secs,
                );
                last = (Instant::now(), paints, delivered);
                if args.seconds > 0 && elapsed >= args.seconds {
                    let _ = cx.update(|cx| cx.quit());
                    break;
                }
            }
        })
        .detach();
    });
}

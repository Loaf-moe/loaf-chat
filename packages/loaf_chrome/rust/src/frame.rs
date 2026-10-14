//! The frameless window's geometry, apart from Win32 so it can be tested
//! anywhere. Every length is in the window's physical pixels unless it says
//! logical.

/// What a point in the window is for. Windows gets the matching `HT*` code.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Hit {
    Client,
    /// Loaf's own maximize button. Reporting it as the frame's is what makes
    /// Windows 11 offer snap layouts over it.
    MaxButton,
    Top,
    Bottom,
    Left,
    Right,
    TopLeft,
    TopRight,
    BottomLeft,
    BottomRight,
}

/// How thick the resize band is along each axis: the frame Windows would
/// have drawn there, so the grab feels the same as any other window's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Band {
    pub x: i32,
    pub y: i32,
}

/// A rectangle in logical pixels, as Dart reports it. Kept logical because
/// Dart reports it only when it moves, so a DPI change must not leave a
/// physical copy stale.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct LogicalRect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl LogicalRect {
    /// Whether the physical point (`x`, `y`) falls inside, at `scale`
    /// physical pixels per logical one. Edges as `PtInRect` has them: the
    /// left and top are in, the right and bottom are out.
    pub fn contains(&self, x: i32, y: i32, scale: f64) -> bool {
        // Truncated as Win32 would truncate a LONG.
        let left = (self.x * scale) as i32;
        let top = (self.y * scale) as i32;
        let right = ((self.x + self.w) * scale) as i32;
        let bottom = ((self.y + self.h) * scale) as i32;
        x >= left && x < right && y >= top && y < bottom
    }
}

/// Where the point (`x`, `y`) of a client area `width` by `height` falls.
/// The client area covers the whole window, so the resize bands lie inside
/// it and are claimed here; a maximized window has none.
pub fn hit_test(
    (x, y): (i32, i32),
    (width, height): (i32, i32),
    band: Band,
    max_button: LogicalRect,
    scale: f64,
    maximized: bool,
) -> Hit {
    // The button comes first, so its top pixels still offer snap layouts
    // rather than a resize.
    if max_button.contains(x, y, scale) {
        return Hit::MaxButton;
    }
    if maximized {
        return Hit::Client;
    }
    let top = y < band.y;
    // Top wins on a window too short for both bands.
    let bottom = !top && y >= height - band.y;
    let left = x < band.x;
    let right = !left && x >= width - band.x;
    match (top, bottom, left, right) {
        (true, _, true, _) => Hit::TopLeft,
        (true, _, _, true) => Hit::TopRight,
        (true, _, _, _) => Hit::Top,
        (_, true, true, _) => Hit::BottomLeft,
        (_, true, _, true) => Hit::BottomRight,
        (_, true, _, _) => Hit::Bottom,
        (_, _, true, _) => Hit::Left,
        (_, _, _, true) => Hit::Right,
        _ => Hit::Client,
    }
}

/// How far the client area sits inside the window on each side, as
/// (left, top, right, bottom). None at all, so Windows has no frame to draw
/// a border in; a maximized window hangs its frame off the screen, so it
/// keeps that much back to stay on it.
pub fn client_insets(maximized: bool, band: Band) -> (i32, i32, i32, i32) {
    if maximized {
        (band.x, band.y, band.x, band.y)
    } else {
        (0, 0, 0, 0)
    }
}

/// The window's state as Dart reads it: one bit each.
pub const MAXIMIZED: u32 = 1;
pub const FOCUSED: u32 = 2;
pub const MAX_HOVERED: u32 = 4;

pub fn state_bits(maximized: bool, focused: bool, max_hovered: bool) -> u32 {
    (if maximized { MAXIMIZED } else { 0 })
        | (if focused { FOCUSED } else { 0 })
        | (if max_hovered { MAX_HOVERED } else { 0 })
}

#[cfg(test)]
mod tests {
    use super::*;

    const BAND: Band = Band { x: 8, y: 8 };
    const SIZE: (i32, i32) = (800, 600);
    const BUTTON: LogicalRect = LogicalRect {
        x: 700.0,
        y: 0.0,
        w: 32.0,
        h: 28.0,
    };

    fn at(x: i32, y: i32) -> Hit {
        hit_test((x, y), SIZE, BAND, BUTTON, 1.0, false)
    }

    #[test]
    fn every_edge_and_corner_resizes() {
        assert_eq!(at(0, 0), Hit::TopLeft);
        assert_eq!(at(400, 0), Hit::Top);
        assert_eq!(at(799, 0), Hit::TopRight);
        assert_eq!(at(0, 300), Hit::Left);
        assert_eq!(at(799, 300), Hit::Right);
        assert_eq!(at(0, 599), Hit::BottomLeft);
        assert_eq!(at(400, 599), Hit::Bottom);
        assert_eq!(at(799, 599), Hit::BottomRight);
    }

    #[test]
    fn the_bands_are_exactly_the_frame_thick() {
        assert_eq!(at(7, 300), Hit::Left);
        assert_eq!(at(8, 300), Hit::Client);
        assert_eq!(at(792, 300), Hit::Right);
        assert_eq!(at(791, 300), Hit::Client);
        assert_eq!(at(400, 7), Hit::Top);
        assert_eq!(at(400, 8), Hit::Client);
        assert_eq!(at(400, 592), Hit::Bottom);
        assert_eq!(at(400, 591), Hit::Client);
    }

    #[test]
    fn the_maximize_button_outranks_the_top_edge() {
        assert_eq!(at(700, 0), Hit::MaxButton);
        assert_eq!(at(731, 27), Hit::MaxButton);
        assert_eq!(at(732, 0), Hit::Top);
        assert_eq!(at(700, 28), Hit::Client);
    }

    #[test]
    fn the_button_scales_with_the_display() {
        let hit = |x, y| hit_test((x, y), (1600, 1200), BAND, BUTTON, 2.0, false);
        assert_eq!(hit(1400, 20), Hit::MaxButton);
        assert_eq!(hit(1463, 55), Hit::MaxButton);
        assert_eq!(hit(1464, 20), Hit::Client);
    }

    #[test]
    fn maximized_has_no_resize_bands_but_keeps_the_button() {
        let hit = |x, y| hit_test((x, y), SIZE, BAND, BUTTON, 1.0, true);
        assert_eq!(hit(0, 0), Hit::Client);
        assert_eq!(hit(799, 599), Hit::Client);
        assert_eq!(hit(0, 300), Hit::Client);
        assert_eq!(hit(710, 2), Hit::MaxButton);
    }

    #[test]
    fn no_button_reported_claims_nothing() {
        let hit = hit_test((0, 0), SIZE, BAND, LogicalRect::default(), 1.0, true);
        assert_eq!(hit, Hit::Client);
    }

    #[test]
    fn where_the_bands_overlap_top_and_left_win() {
        let hit = |x, y| hit_test((x, y), (10, 10), BAND, LogicalRect::default(), 1.0, false);
        assert_eq!(hit(5, 5), Hit::TopLeft);
        assert_eq!(hit(9, 9), Hit::BottomRight);
    }

    #[test]
    fn only_a_maximized_window_keeps_an_inset() {
        assert_eq!(client_insets(false, BAND), (0, 0, 0, 0));
        assert_eq!(client_insets(true, Band { x: 8, y: 9 }), (8, 9, 8, 9));
    }

    #[test]
    fn state_packs_one_bit_each() {
        assert_eq!(state_bits(false, false, false), 0);
        assert_eq!(state_bits(true, false, false), MAXIMIZED);
        assert_eq!(state_bits(false, true, true), FOCUSED | MAX_HOVERED);
    }
}

// Where the island window goes: the default top-centre of a display, or a
// spot the user dragged it to. Pure math on physical pixels so it can be
// tested without monitors.
//
// The saved position is the island's *anchor*: the top-centre of the island
// shape. The window (full panel or wake strip) is centred on it horizontally
// and hangs down from it, so the island grows downward from the same point
// when it expands, and the wake strip sits exactly where the island was.

use serde::{Deserialize, Serialize};

/// Top-centre of the island, physical screen pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Anchor {
    pub x: i32,
    pub y: i32,
}

/// A rectangle in physical screen pixels.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rect {
    pub x: i32,
    pub y: i32,
    pub w: i32,
    pub h: i32,
}

impl Rect {
    fn contains(&self, x: i32, y: i32) -> bool {
        x >= self.x && x < self.x + self.w && y >= self.y && y < self.y + self.h
    }

    fn distance_sq(&self, x: i32, y: i32) -> i64 {
        let dx = (self.x - x).max(0).max(x - (self.x + self.w - 1)) as i64;
        let dy = (self.y - y).max(0).max(y - (self.y + self.h - 1)) as i64;
        dx * dx + dy * dy
    }
}

/// One display: its full bounds (for "which display is this on") and its work
/// area (without the taskbar — where the island may go).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Display {
    pub bounds: Rect,
    pub work: Rect,
}

/// The display a point is on, or the nearest one when it is on none (a
/// display that was unplugged, a layout that changed).
pub fn display_for(displays: &[Display], x: i32, y: i32) -> Option<usize> {
    if let Some(i) = displays.iter().position(|d| d.bounds.contains(x, y)) {
        return Some(i);
    }
    (0..displays.len()).min_by_key(|&i| displays[i].bounds.distance_sq(x, y))
}

/// Window top-left for a window of `w`×`h` hanging from `anchor`, kept inside
/// `work` (the whole window, so a expanding island never leaves the screen).
pub fn window_origin(anchor: Anchor, w: i32, h: i32, work: Rect) -> (i32, i32) {
    let x = clamp(anchor.x - w / 2, work.x, work.x + work.w - w);
    let y = clamp(anchor.y, work.y, work.y + work.h - h);
    (x, y)
}

/// The anchor a window at `(x, y)` of width `w` stands for (the inverse of
/// `window_origin` without clamping) — what a drag leaves behind.
pub fn anchor_of(x: i32, y: i32, w: i32) -> Anchor {
    Anchor { x: x + w / 2, y }
}

/// A saved anchor brought back onto a display that exists, so that the full
/// panel (`panel_w`×`panel_h`) fits its work area.
pub fn clamp_anchor(anchor: Anchor, panel_w: i32, panel_h: i32, displays: &[Display]) -> Option<Anchor> {
    let d = displays[display_for(displays, anchor.x, anchor.y)?];
    let (x, y) = window_origin(anchor, panel_w, panel_h, d.work);
    Some(anchor_of(x, y, panel_w))
}

/// Default spot: top-centre of the display's full bounds, like a notch.
pub fn default_anchor(display: &Display) -> Anchor {
    Anchor { x: display.bounds.x + display.bounds.w / 2, y: display.bounds.y }
}

/// Lower bound wins when the range is empty (window wider than the area).
fn clamp(v: i32, lo: i32, hi: i32) -> i32 {
    if hi < lo { lo } else { v.clamp(lo, hi) }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn display(x: i32, y: i32, w: i32, h: i32, taskbar: i32) -> Display {
        Display { bounds: Rect { x, y, w, h }, work: Rect { x, y, w, h: h - taskbar } }
    }

    #[test]
    fn default_is_top_centre_of_the_display() {
        let d = display(0, 0, 1920, 1080, 48);
        assert_eq!(default_anchor(&d), Anchor { x: 960, y: 0 });
        let (x, y) = window_origin(default_anchor(&d), 720, 320, d.work);
        assert_eq!((x, y), (600, 0));
        let second = display(1920, -200, 2560, 1440, 0);
        assert_eq!(default_anchor(&second), Anchor { x: 3200, y: -200 });
    }

    #[test]
    fn panel_and_strip_share_the_anchor() {
        let d = display(0, 0, 1920, 1080, 48);
        let a = Anchor { x: 500, y: 300 };
        let (px, py) = window_origin(a, 720, 320, d.work);
        let (sx, sy) = window_origin(a, 240, 6, d.work);
        assert_eq!((px + 360, py), (500, 300));
        assert_eq!((sx + 120, sy), (500, 300));
        assert_eq!(anchor_of(px, py, 720), a);
    }

    #[test]
    fn expanding_near_an_edge_stays_on_screen() {
        let d = display(0, 0, 1920, 1080, 48);
        // Dragged as a strip into the bottom-right corner.
        let a = Anchor { x: 1910, y: 1030 };
        let (x, y) = window_origin(a, 720, 320, d.work);
        assert_eq!((x, y), (1920 - 720, 1032 - 320));
        let (x, y) = window_origin(Anchor { x: -50, y: -40 }, 720, 320, d.work);
        assert_eq!((x, y), (0, 0));
    }

    #[test]
    fn window_larger_than_the_work_area_pins_to_its_corner() {
        let tiny = display(100, 100, 600, 200, 0);
        assert_eq!(window_origin(Anchor { x: 400, y: 150 }, 720, 320, tiny.work), (100, 100));
    }

    #[test]
    fn display_is_found_or_the_nearest_is_used() {
        let ds = [display(0, 0, 1920, 1080, 48), display(1920, 0, 1280, 1024, 40)];
        assert_eq!(display_for(&ds, 100, 100), Some(0));
        assert_eq!(display_for(&ds, 2000, 10), Some(1));
        assert_eq!(display_for(&ds, 5000, 10), Some(1));
        assert_eq!(display_for(&ds, -300, 500), Some(0));
        assert_eq!(display_for(&[], 0, 0), None);
    }

    #[test]
    fn unplugged_display_brings_the_island_back() {
        // Saved on a right-hand display that is gone now.
        let only = [display(0, 0, 1920, 1080, 48)];
        let back = clamp_anchor(Anchor { x: 2600, y: 400 }, 720, 320, &only).unwrap();
        assert_eq!(back, Anchor { x: 1920 - 360, y: 400 });
        // Still valid: unchanged.
        let fine = Anchor { x: 900, y: 200 };
        assert_eq!(clamp_anchor(fine, 720, 320, &only), Some(fine));
        assert_eq!(clamp_anchor(fine, 720, 320, &[]), None);
    }

    #[test]
    fn anchor_round_trips_as_json() {
        let a: Anchor = serde_json::from_str(r#"{"x":-1200,"y":34}"#).unwrap();
        assert_eq!(a, Anchor { x: -1200, y: 34 });
        assert_eq!(serde_json::to_value(a).unwrap(), serde_json::json!({ "x": -1200, "y": 34 }));
    }
}

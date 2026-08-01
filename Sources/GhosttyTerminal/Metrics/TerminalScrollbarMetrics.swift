//
//  TerminalScrollbarMetrics.swift
//  libghostty-spm
//

import GhosttyKit

/// Where the viewport sits inside the scrollback, in ROWS.
///
/// Ghostty computes this itself and pushes it out as `GHOSTTY_ACTION_SCROLLBAR`
/// whenever the geometry changes — it does not draw a scrollbar, it hands the
/// numbers to the host and lets the host decide what (if anything) to draw.
///
/// Rows, not pixels: `total` counts scrollback + viewport, so a terminal that
/// has never scrolled reports `offset == 0` and `len == total`.
public struct TerminalScrollbarMetrics: Sendable, Equatable {
    /// Total rows addressable — scrollback plus the visible viewport.
    public var total: UInt64
    /// Rows above the top of the viewport. 0 = scrolled to the very top.
    public var offset: UInt64
    /// Rows the viewport shows, i.e. the length of the thumb in row units.
    public var length: UInt64

    public init(total: UInt64, offset: UInt64, length: UInt64) {
        self.total = total
        self.offset = offset
        self.length = length
    }

    init(_ rawValue: ghostty_action_scrollbar_s) {
        // `len` in C, `length` here — `len` reads as a byte count next to
        // `total`, and these are rows.
        self.init(total: rawValue.total, offset: rawValue.offset, length: rawValue.len)
    }

    /// True when everything there is to show already fits on screen, i.e. there
    /// is nothing to scroll and a scrollbar would be decoration.
    public var fitsOnScreen: Bool {
        total <= length || total == 0
    }

    /// Thumb position as a fraction of the track, in `0...1`. Returns 0 when
    /// there is nothing to scroll rather than dividing by zero.
    public var scrollProgress: Double {
        let scrollable = total &- min(length, total)
        guard scrollable > 0 else { return 0 }
        return Double(min(offset, scrollable)) / Double(scrollable)
    }

    /// Thumb length as a fraction of the track, in `0...1`.
    public var visibleFraction: Double {
        guard total > 0 else { return 1 }
        return Double(min(length, total)) / Double(total)
    }
}

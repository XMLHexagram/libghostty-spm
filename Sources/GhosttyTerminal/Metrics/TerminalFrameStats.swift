//
//  TerminalFrameStats.swift
//  libghostty-spm
//

import Foundation

/// One second of this surface's rendering, counted rather than estimated.
///
/// The display link fires at the display's refresh rate whether or not a draw
/// keeps up, which is what makes these numbers readable as a pair: `ticks` is
/// the rate the system offered, `drawn` is the rate actually achieved, and
/// `dropped` is the gap with its reason — a frame is dropped when the previous
/// `ghostty_surface_draw` is still in flight, i.e. the GPU submit is behind.
///
/// `drawn` well below `ticks` means the renderer is the bottleneck. `ticks`
/// itself well below the refresh rate means the display link isn't running at
/// full speed — a different problem (occlusion, power state, a deliberately
/// frozen pane), and not one the renderer can fix.
public struct TerminalFrameStats: Sendable, Equatable {
    /// Frames actually drawn, per second.
    public var drawnPerSecond: Double
    /// Display-link ticks, per second — the ceiling `drawnPerSecond` is measured against.
    public var ticksPerSecond: Double
    /// Frames skipped in this window because the previous draw hadn't finished.
    public var dropped: Int
    /// Mean wall-clock time inside `ghostty_surface_draw`, in milliseconds.
    public var averageDrawMilliseconds: Double

    public init(
        drawnPerSecond: Double,
        ticksPerSecond: Double,
        dropped: Int,
        averageDrawMilliseconds: Double
    ) {
        self.drawnPerSecond = drawnPerSecond
        self.ticksPerSecond = ticksPerSecond
        self.dropped = dropped
        self.averageDrawMilliseconds = averageDrawMilliseconds
    }
}

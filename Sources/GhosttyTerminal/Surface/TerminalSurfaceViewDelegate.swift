//
//  TerminalSurfaceViewDelegate.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

@MainActor
public protocol TerminalSurfaceViewDelegate: AnyObject {}

@MainActor
public protocol TerminalSurfaceTitleDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeTitle(_ title: String)
}

@MainActor
public protocol TerminalSurfaceGridResizeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidResize(_ size: TerminalGridMetrics)
}

@MainActor
public protocol TerminalSurfaceResizeDelegate: TerminalSurfaceViewDelegate {
    func terminalDidResize(columns: Int, rows: Int)
}

@MainActor
public protocol TerminalSurfaceFocusDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangeFocus(_ focused: Bool)
}

@MainActor
public protocol TerminalSurfaceBellDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRingBell()
}

@MainActor
public protocol TerminalSurfaceCloseDelegate: TerminalSurfaceViewDelegate {
    func terminalDidClose(processAlive: Bool)
}

@MainActor
public protocol TerminalSurfacePwdDelegate: TerminalSurfaceViewDelegate {
    func terminalDidChangePwd(_ pwd: String)
}

@MainActor
public protocol TerminalSurfaceSearchDelegate: TerminalSurfaceViewDelegate {
    /// The terminal is asking the host to put its search UI up.
    ///
    /// **`needle` is what to put in it.** Empty for the `start_search` binding,
    /// which opens the UI and nothing else; the current selection for
    /// `search_selection`, which is how "use the selection for find" works —
    /// the engine hands the text over and expects the host to run the search
    /// with it. Dropping the needle made that binding open an empty field over
    /// a terminal that was not searching for anything.
    func terminalDidRequestSearch(needle: String)
    /// The terminal has torn its search down, and the host should take its
    /// search UI away.
    ///
    /// Fired by the `end_search` binding — including the one the HOST sends, so
    /// a host that closes its own UI here must be idempotent about it. Ghostty
    /// sends it "so that GUIs can clean up stale stuff", which is the only
    /// signal that a search ended without the host being the one to end it.
    func terminalDidEndSearch()
    func terminalDidUpdateSearchTotal(_ total: Int)
    func terminalDidUpdateSearchSelected(_ selected: Int)
}

/// A shell-integration command finished (OSC 133;D). `durationNanoseconds` is
/// how long the command ran, so hosts can ignore trivially short commands.
@MainActor
public protocol TerminalSurfaceCommandFinishedDelegate: TerminalSurfaceViewDelegate {
    func terminalDidFinishCommand(exitCode: Int, durationNanoseconds: UInt64)
}

/// A program requested a desktop notification (OSC 9 / OSC 777).
@MainActor
public protocol TerminalSurfaceDesktopNotificationDelegate: TerminalSurfaceViewDelegate {
    func terminalDidRequestDesktopNotification(title: String, body: String)
}

/// The viewport moved within the scrollback, or the scrollback's size changed.
///
/// Ghostty pushes this on every draw where the geometry differs from the last
/// one — it computes the numbers and leaves the drawing to the host, which is
/// the only party that knows whether this surface should show a scrollbar at
/// all. Expect it at frame rate while scrolling: coalesce or compare before
/// doing layout work.
@MainActor
public protocol TerminalSurfaceScrollbarDelegate: TerminalSurfaceViewDelegate {
    func terminalDidUpdateScrollbar(_ metrics: TerminalScrollbarMetrics)
}

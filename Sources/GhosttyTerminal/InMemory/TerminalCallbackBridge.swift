//
//  TerminalCallbackBridge.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

#if canImport(AppKit)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

/// Dispatches C runtime callbacks to a ``TerminalSurfaceViewDelegate``.
///
/// An instance of this class is passed as the `userdata` pointer in the
/// surface config so that Ghostty callbacks can route actions back to
/// the owning view.
@MainActor
final class TerminalCallbackBridge {
    weak var delegate: (any TerminalSurfaceViewDelegate)?
    /// Raw surface pointer for use in C callbacks (e.g. clipboard).
    nonisolated(unsafe) var rawSurface: ghostty_surface_t?
    var onCellSizeChange: ((UInt32, UInt32) -> Void)?

    init(delegate: (any TerminalSurfaceViewDelegate)? = nil) {
        self.delegate = delegate
    }

    /// Actions the host takes responsibility for, so ghostty must not fall back
    /// to handling them itself.
    ///
    /// Returned all the way up to `ghostty_runtime_config_s`'s action callback,
    /// whose `false` means "nobody handled this". For `SHOW_CHILD_EXITED` that
    /// answer is actively wrong here: told no, ghostty prints "Process exited.
    /// Press any key to close the terminal." into the grid and arms a keypress
    /// to close — a second, competing exit affordance on top of the host's own
    /// overlay, and it lands FIRST, so the overlay only appeared after the user
    /// had already pressed a key to dismiss ghostty's version.
    /// `nonisolated` because the C action callback answers ghostty
    /// synchronously, off any actor — the reply has to be the return value of
    /// that call, not something a hop to the main actor produces later.
    nonisolated static func handles(_ tag: ghostty_action_tag_e) -> Bool {
        tag == GHOSTTY_ACTION_SHOW_CHILD_EXITED
    }

    func handleAction(_ action: ghostty_action_s) {
        switch action.tag {
        case GHOSTTY_ACTION_SHOW_CHILD_EXITED:
            TerminalDebugLog.log(
                .lifecycle,
                "callback action=show_child_exited exit=\(action.action.child_exited.exit_code)"
            )
            // Surface the exit NOW. Ghostty otherwise only reports it through
            // `close`, which on the message path is gated behind the keypress.
            (delegate as? any TerminalSurfaceCloseDelegate)?
                .terminalDidClose(processAlive: false)

        case GHOSTTY_ACTION_SET_TITLE:
            if let cStr = action.action.set_title.title {
                let title = String(cString: cStr)
                TerminalDebugLog.log(
                    .actions,
                    "callback action=set_title title=\(TerminalDebugLog.describe(title))"
                )
                (delegate as? any TerminalSurfaceTitleDelegate)?
                    .terminalDidChangeTitle(title)
            }

        case GHOSTTY_ACTION_CELL_SIZE:
            let cellSize = action.action.cell_size
            TerminalDebugLog.log(
                .actions,
                "callback action=cell_size width=\(cellSize.width) height=\(cellSize.height)"
            )
            onCellSizeChange?(cellSize.width, cellSize.height)

        case GHOSTTY_ACTION_RING_BELL:
            TerminalDebugLog.log(.actions, "callback action=ring_bell")
            (delegate as? any TerminalSurfaceBellDelegate)?
                .terminalDidRingBell()

        case GHOSTTY_ACTION_PWD:
            if let cStr = action.action.pwd.pwd {
                let pwd = String(cString: cStr)
                TerminalDebugLog.log(
                    .actions,
                    "callback action=pwd path=\(TerminalDebugLog.describe(pwd))"
                )
                (delegate as? any TerminalSurfacePwdDelegate)?
                    .terminalDidChangePwd(pwd)
            }

        case GHOSTTY_ACTION_START_SEARCH:
            let needle = action.action.start_search.needle.map { String(cString: $0) } ?? ""
            TerminalDebugLog.log(.actions, "callback action=start_search needle=\(needle)")
            (delegate as? any TerminalSurfaceSearchDelegate)?
                .terminalDidRequestSearch()

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            TerminalDebugLog.log(.actions, "callback action=search_total total=\(total)")
            (delegate as? any TerminalSurfaceSearchDelegate)?
                .terminalDidUpdateSearchTotal(Int(total))

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            TerminalDebugLog.log(.actions, "callback action=search_selected selected=\(selected)")
            (delegate as? any TerminalSurfaceSearchDelegate)?
                .terminalDidUpdateSearchSelected(Int(selected))

        case GHOSTTY_ACTION_OPEN_URL:
            let openURL = action.action.open_url
            if let cStr = openURL.url {
                let urlString = openURL.len > 0
                    ? String(bytes: UnsafeBufferPointer(start: UnsafePointer<UInt8>(OpaquePointer(cStr)), count: Int(openURL.len)), encoding: .utf8) ?? String(cString: cStr)
                    : String(cString: cStr)
                TerminalDebugLog.log(
                    .actions,
                    "callback action=open_url url=\(TerminalDebugLog.describe(urlString))"
                )
                if let url = URL(string: urlString) {
                    #if canImport(AppKit)
                    NSWorkspace.shared.open(url)
                    #elseif canImport(UIKit)
                    UIApplication.shared.open(url)
                    #endif
                }
            }

        case GHOSTTY_ACTION_DESKTOP_NOTIFICATION:
            let note = action.action.desktop_notification
            let title = note.title.map { String(cString: $0) } ?? ""
            let body = note.body.map { String(cString: $0) } ?? ""
            TerminalDebugLog.log(
                .actions,
                "callback action=desktop_notification title=\(TerminalDebugLog.describe(title))"
            )
            (delegate as? any TerminalSurfaceDesktopNotificationDelegate)?
                .terminalDidRequestDesktopNotification(title: title, body: body)

        case GHOSTTY_ACTION_COMMAND_FINISHED:
            let finished = action.action.command_finished
            TerminalDebugLog.log(
                .actions,
                "callback action=command_finished exit=\(finished.exit_code) duration=\(finished.duration)"
            )
            (delegate as? any TerminalSurfaceCommandFinishedDelegate)?
                .terminalDidFinishCommand(
                    exitCode: Int(finished.exit_code),
                    durationNanoseconds: finished.duration
                )

        default:
            let category: TerminalDebugCategory =
                action.tag == GHOSTTY_ACTION_RENDER ? .render : .actions
            TerminalDebugLog.log(
                category,
                "callback action=\(TerminalDebugLog.describe(action.tag))"
            )
        }
    }

    func handleClose(processAlive: Bool) {
        TerminalDebugLog.log(
            .lifecycle,
            "callback close processAlive=\(processAlive)"
        )
        (delegate as? any TerminalSurfaceCloseDelegate)?
            .terminalDidClose(processAlive: processAlive)
    }
}

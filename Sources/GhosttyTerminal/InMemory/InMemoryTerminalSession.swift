//
//  InMemoryTerminalSession.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

public final class InMemoryTerminalSession: @unchecked Sendable {
    private let lock = NSLock()
    private var surface: ghostty_surface_t?
    private var lastResize: InMemoryTerminalViewport?
    /// The size currently being handed to `resizeHandler`. Only non-nil for the
    /// duration of that call — see `dispatchResize` for why the record moved
    /// after the handler and what this covers while it is in flight.
    private var inFlightResize: InMemoryTerminalViewport?
    private let writeHandler: @Sendable (Data) -> Void
    private let resizeHandler: @Sendable (InMemoryTerminalViewport) -> Void

    /// Bytes that arrived while `surface == nil`. When the surface is (re)built
    /// we flush these in order instead of having dropped them — the fix for the
    /// "blank pane after resume" bug, where zmx's reattach re-emit races ahead of
    /// the surface being (re)attached (proven: with the surface-attach artificially
    /// delayed, dropping → permanent blank pane, buffering → clean recovery).
    /// Bounded by `pendingCap`: past the cap we stop buffering and mark
    /// `pendingOverflowed`, so a long-detached, output-spewing boite (surface freed
    /// while hidden) can't grow this without limit — those fall back to the reattach
    /// nudge / a fresh re-emit.
    private var pendingWhileDetached = Data()
    private var pendingOverflowed = false
    private static let pendingCap = 4 * 1024 * 1024  // 4 MB

    /// Buffer-on-nil-surface fix. On by default; kill-switch (reverts to the old
    /// silent drop) via
    ///   defaults write uint8.dev.boite.app BoiteTermDisableNilBuffer -bool YES
    private static let bufferWhileDetached =
        !UserDefaults.standard.bool(forKey: "BoiteTermDisableNilBuffer")

    public init(
        write: @escaping @Sendable (Data) -> Void,
        resize: @escaping @Sendable (InMemoryTerminalViewport) -> Void
    ) {
        writeHandler = write
        resizeHandler = resize
    }

    // MARK: - Surface Lifecycle

    func setSurface(_ surface: ghostty_surface_t?) {
        lock.lock()
        defer { lock.unlock() }
        self.surface = surface

        // Detaching invalidates the resize dedup. `lastResize` means "the child
        // already has this size", and that claim is only as good as the surface
        // that produced it: while detached the view keeps laying out and the
        // window can be resized, all of it unobservable here (the coordinator
        // logs `synchronizeMetrics skipped: missing surface` and returns before
        // it reaches us). When a surface comes back, the first size it computes
        // has to be dispatched even if it matches what we last sent — the child
        // may well have been resized out from under that record in between.
        //
        // The coordinator already drops its own `lastMetrics` on free; this is
        // the same reset one layer down. Without it the two guards have
        // different lifetimes, and a size that ever lands in `lastResize`
        // without reaching the child becomes permanently undeliverable: every
        // future return to that exact size is swallowed here as "unchanged".
        // That is the reported bug — the pane renders at the right width while
        // the shell keeps laying out for the old one.
        if surface == nil {
            lastResize = nil
            inFlightResize = nil
        }

        // Flush whatever queued up while detached — unless we overflowed the
        // cap (a truncated stream would replay a partial frame, so skip it and
        // let the nudge / re-emit repaint instead).
        if surface != nil, !pendingWhileDetached.isEmpty {
            if pendingOverflowed {
                TerminalDebugLog.log(
                    .lifecycle,
                    "in-memory session dropped \(pendingWhileDetached.count) buffered bytes (overflowed)"
                )
            } else {
                pendingWhileDetached.withUnsafeBytes { buffer in
                    if let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) {
                        ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
                    }
                }
                TerminalDebugLog.log(
                    .lifecycle,
                    "in-memory session flushed \(pendingWhileDetached.count) buffered bytes"
                )
            }
            pendingWhileDetached.removeAll(keepingCapacity: false)
            pendingOverflowed = false
        }

        TerminalDebugLog.log(
            .lifecycle,
            "in-memory session surface=\(surface == nil ? "nil" : "set")"
        )
    }

    func updateViewport(_ size: TerminalGridMetrics) {
        TerminalDebugLog.log(.metrics, "in-memory viewport update \(size.debugSummary)")
        dispatchResize(InMemoryTerminalViewport(
            columns: size.columns,
            rows: size.rows,
            widthPixels: size.widthPixels,
            heightPixels: size.heightPixels,
            cellWidthPixels: size.cellWidthPixels,
            cellHeightPixels: size.cellHeightPixels
        ))
    }

    /// Force a reattached full-screen TUI (Claude Code / vim / htop / …) to
    /// repaint by nudging ONLY the child's reported viewport — one row down,
    /// then back — without touching ghostty's display grid.
    ///
    /// On reattach the surface is recreated at the SAME size the session
    /// already had, so no resize *delta* ever reaches the child: both dedup
    /// guards (this session's `lastResize` and the coordinator's `lastMetrics`)
    /// swallow an identical re-send. Ink-style TUIs only repaint on input or a
    /// genuine SIGWINCH delta, so the reattached frame stays stale — and worse,
    /// at the child's stale size — until the user types AND resizes by hand.
    ///
    /// Two winsize deltas the child cannot dedup (rows-1, then the true rows)
    /// deliver two real SIGWINCHes → a clean redraw at the correct size. Ghostty's
    /// grid is untouched, so there is no visible reflow of the pane; only the
    /// child re-emits. Restore is deferred a tick so the child observes two
    /// distinct winsizes rather than one coalesced set. No-op until a first
    /// real viewport has been dispatched (nothing to nudge from yet).
    public func nudgeChildViewportToForceRedraw() {
        lock.lock()
        guard let base = lastResize, base.rows > 1 else {
            lock.unlock()
            return
        }
        lock.unlock()

        let shrunk = InMemoryTerminalViewport(
            columns: base.columns,
            rows: base.rows - 1,
            widthPixels: base.widthPixels,
            heightPixels: base.heightPixels,
            cellWidthPixels: base.cellWidthPixels,
            cellHeightPixels: base.cellHeightPixels
        )
        dispatchResize(shrunk)
        DispatchQueue.main.async { [weak self] in
            self?.dispatchResize(base)
        }
    }

    // MARK: - Receiving Data

    /// Feed data into the terminal from the host backend.
    public func receive(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard let surface else {
            guard Self.bufferWhileDetached else {
                TerminalDebugLog.log(
                    .output,
                    "terminal <- host dropped \(TerminalDebugLog.describe(data))"
                )
                return
            }
            if pendingOverflowed { return }
            if pendingWhileDetached.count + data.count > Self.pendingCap {
                pendingOverflowed = true
                pendingWhileDetached.removeAll(keepingCapacity: false)
                TerminalDebugLog.log(
                    .output,
                    "terminal <- host buffer overflow at cap=\(Self.pendingCap); dropping until reattach"
                )
                return
            }
            pendingWhileDetached.append(data)
            TerminalDebugLog.log(
                .output,
                "terminal <- host buffered \(TerminalDebugLog.describe(data)) pending=\(pendingWhileDetached.count)"
            )
            return
        }

        TerminalDebugLog.log(
            .output,
            "terminal <- host \(TerminalDebugLog.describe(data))"
        )

        data.withUnsafeBytes { buffer in
            guard let ptr = buffer.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            ghostty_surface_write_buffer(surface, ptr, UInt(buffer.count))
        }
    }

    /// Feed a UTF-8 string into the terminal from the host backend.
    public func receive(_ string: String) {
        guard let data = string.data(using: .utf8) else { return }
        receive(data)
    }

    /// Inject input bytes directly into the host-side consumer.
    ///
    /// This bypasses `ghostty_surface_key` translation and is intended for
    /// control sequences that the in-memory backend must interpret itself.
    public func sendInput(_ data: Data) {
        TerminalDebugLog.log(
            .input,
            "host <- direct input \(TerminalDebugLog.describe(data))"
        )
        writeHandler(data)
    }

    // MARK: - Process Exit

    /// Signal that the host-managed process has exited.
    public func finish(exitCode: UInt32, runtimeMilliseconds: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard let surface else {
            TerminalDebugLog.log(
                .lifecycle,
                "process exit ignored: missing surface exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
            )
            return
        }

        TerminalDebugLog.log(
            .lifecycle,
            "process exit exitCode=\(exitCode) runtimeMs=\(runtimeMilliseconds)"
        )
        ghostty_surface_process_exit(surface, exitCode, runtimeMilliseconds)
    }

    // MARK: - C Callbacks

    static let receiveBufferCallback: ghostty_surface_receive_buffer_cb = { userdata, ptr, len in
        guard let userdata, let ptr else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        let data = Data(bytes: ptr, count: len)
        TerminalDebugLog.log(
            .input,
            "host <- terminal \(TerminalDebugLog.describe(data))"
        )
        session.writeHandler(data)
    }

    static let receiveResizeCallback: ghostty_surface_receive_resize_cb = { userdata, cols, rows, widthPx, heightPx in
        guard let userdata else { return }
        let session = Unmanaged<InMemoryTerminalSession>
            .fromOpaque(userdata)
            .takeUnretainedValue()
        TerminalDebugLog.log(
            .metrics,
            "receive resize cols=\(cols) rows=\(rows) pixels=\(widthPx)x\(heightPx)"
        )
        session.dispatchResize(InMemoryTerminalViewport(
            columns: cols,
            rows: rows,
            widthPixels: widthPx,
            heightPixels: heightPx
        ))
    }

    private func dispatchResize(_ resize: InMemoryTerminalViewport) {
        lock.lock()
        let mergedResize = mergedResize(resize)
        // `inFlightResize` covers the window this method opens by recording
        // late: between unlocking and the handler returning, `lastResize` still
        // holds the previous size, so a re-entrant or concurrent call carrying
        // the SAME size would otherwise sail past the guard — and a handler
        // that synchronously dispatches back would recurse without end.
        guard mergedResize != lastResize, mergedResize != inFlightResize else {
            lock.unlock()
            TerminalDebugLog.log(
                .metrics,
                "resize unchanged cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
            )
            return
        }
        inFlightResize = mergedResize
        lock.unlock()

        TerminalDebugLog.log(
            .metrics,
            "resize dispatched cols=\(mergedResize.columns) rows=\(mergedResize.rows) pixels=\(mergedResize.widthPixels)x\(mergedResize.heightPixels) cell=\(mergedResize.cellWidthPixels)x\(mergedResize.cellHeightPixels)"
        )
        resizeHandler(mergedResize)

        // Record AFTER the handler, not before.
        //
        // `lastResize` is a claim that the child has this size, and the only
        // thing that can make it true is `resizeHandler`. Setting it first meant
        // the claim was filed whether or not the handler did anything — and it
        // can do nothing: it hops to the main actor, and every backend's
        // implementation begins by unwrapping a weak reference that is gone
        // once the panel's backend has been torn down. One dropped delivery
        // used to be permanent, because the record said "sent" and every
        // identical retry hit the guard above.
        //
        // Recording afterwards costs a redundant re-send in the case where the
        // handler DID deliver but something later diverged; the previous
        // ordering cost a size that could never be delivered again.
        lock.lock()
        lastResize = mergedResize
        inFlightResize = nil
        lock.unlock()
    }

    private func mergedResize(_ resize: InMemoryTerminalViewport) -> InMemoryTerminalViewport {
        guard let lastResize else { return resize }

        return InMemoryTerminalViewport(
            columns: resize.columns,
            rows: resize.rows,
            widthPixels: resize.widthPixels == 0 ? lastResize.widthPixels : resize.widthPixels,
            heightPixels: resize.heightPixels == 0 ? lastResize.heightPixels : resize.heightPixels,
            cellWidthPixels: resize.cellWidthPixels == 0 ? lastResize.cellWidthPixels : resize.cellWidthPixels,
            cellHeightPixels: resize.cellHeightPixels == 0 ? lastResize.cellHeightPixels : resize.cellHeightPixels
        )
    }
}

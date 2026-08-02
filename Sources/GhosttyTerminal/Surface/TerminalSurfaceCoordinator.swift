//
//  TerminalSurfaceCoordinator.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit

/// Shared terminal state and logic used by both UIKit and AppKit views.
///
/// Platform views own a `TerminalSurfaceCoordinator` instance and set platform-specific
/// hooks via closures. The core handles surface lifecycle, metrics
/// synchronization, and frame rendering via display link.
@MainActor
final class TerminalSurfaceCoordinator {
    weak var delegate: (any TerminalSurfaceViewDelegate)? {
        didSet { bridge.delegate = delegate }
    }

    var controller: TerminalController? {
        didSet {
            guard controller !== oldValue else { return }
            rebuildIfReady(removingBridgeFrom: oldValue)
        }
    }

    var configuration: TerminalSurfaceOptions = .init() {
        didSet {
            guard !configuration.isEquivalent(to: oldValue) else { return }
            rebuildIfReady()
        }
    }

    var surface: TerminalSurface?
    let bridge = TerminalCallbackBridge()

    // MARK: - Platform Hooks

    var isAttached: () -> Bool = { false }
    var scaleFactor: () -> Double = { 2.0 }
    /// The view the frame clock should follow. Asked for at start time rather
    /// than stored, so the coordinator owns no reference back to its view — and
    /// so the link re-times itself against whatever screen the view is on now.
    var displayLinkHost: () -> PlatformViewForDisplayLink? = { nil }
    var viewSize: () -> (width: Double, height: Double) = { (0, 0) }
    var platformSetup: ((inout ghostty_surface_config_s) -> Void)?
    var onMetricsUpdate: (() -> Void)?
    var onCellSizeDidChange: (() -> Void)?

    /// Called after every display-link render (`tick`).
    ///
    /// When `synchronizeMetrics` sends a new pixel size to ghostty via
    /// `setSize`, the underlying IOSurface is not rebuilt synchronously.
    /// Until the next full render pass ghostty still uses the **old**
    /// IOSurface, so it derives an incorrect `contentsScale` for the
    /// IOSurfaceLayer (e.g. old-pixel-height / new-point-height → 4.62
    /// instead of the expected 3.0). This causes a visible "jump" on
    /// every layout change (keyboard show/hide, rotation, color-scheme
    /// toggle, etc.).
    ///
    /// Platform views use this hook to silently enforce the correct
    /// `contentsScale` and `frame` on sublayers after each render,
    /// correcting any drift introduced by ghostty within a single frame.
    var onPostRender: (() -> Void)?
    /// Fires once per second with this surface's measured frame rate.
    var onFrameStats: ((TerminalFrameStats) -> Void)?

    private var lastMetrics: TerminalViewportMetrics?

    // MARK: - Off-main rendering

    /// Dedicated serial queue that owns `ghostty_surface_draw` for THIS
    /// surface. On macOS every surface's display-link tick is marshalled to
    /// the main thread, so with N live surfaces the main thread runs N
    /// synchronous Metal draws per frame — and a single draw that blocks in
    /// `nextDrawable`/`waitUntilCompleted` (drawable/IOSurface starvation once
    /// many surfaces are live) freezes the whole UI. Moving the draw off-main
    /// means a blocked GPU submit stalls only this surface's render queue, not
    /// the main thread. Mirrors the official Ghostty app's per-surface render
    /// thread (input/resize on main, draw on its own thread; libghostty locks
    /// the two internally).
    private let renderQueue = DispatchQueue(
        label: "dev.boite.terminal.surface.render",
        qos: .userInteractive
    )
    /// True while a draw dispatched to `renderQueue` has not yet completed.
    /// The display link fires every frame; if the previous frame's draw is
    /// still in flight (slow GPU) we DROP this frame instead of enqueuing,
    /// bounding the backlog to at most one in-flight draw and letting a slow
    /// surface simply render at a lower rate rather than accumulate work.
    private var drawInFlight = false

    // MARK: - Display Link

    private var displayLink: TerminalDisplayLink?

    /// Frames-per-second ceiling, or nil for the display's own rate. Applied
    /// live: this is a preference about how hard to work, not part of the
    /// surface's identity, so it must never reach `TerminalSurfaceOptions` —
    /// changing that rebuilds the surface, and rebuilding a surface to change a
    /// frame rate would restart the shell under it.
    var preferredFrameRate: Int? {
        didSet {
            guard preferredFrameRate != oldValue else { return }
            displayLink?.preferredFrameRate = preferredFrameRate
        }
    }

    init() {
        bridge.onCellSizeChange = { [weak self] width, height in
            self?.handleCellSizeChange(width: width, height: height)
        }
    }

    func startDisplayLink() {
        guard displayLink == nil else { return }
        TerminalDebugLog.log(.lifecycle, "display link start")
        let link = TerminalDisplayLink(
            host: { [weak self] in self?.displayLinkHost() },
            onTick: { [weak self] in self?.tick() }
        )
        link.preferredFrameRate = preferredFrameRate
        link.start()
        displayLink = link
    }

    func stopDisplayLink() {
        TerminalDebugLog.log(.lifecycle, "display link stop")
        displayLink?.stop()
        displayLink = nil
    }

    // MARK: - Surface Lifecycle

    func rebuildIfReady(removingBridgeFrom previousController: TerminalController? = nil) {
        tearDownSurface(removingBridgeFrom: previousController ?? controller)
        guard let controller else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: missing controller")
            return
        }
        guard isAttached() else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild skipped: view detached")
            return
        }

        let scale = scaleFactor()
        TerminalDebugLog.log(
            .lifecycle,
            "surface rebuild scale=\(String(format: "%.2f", scale)) \(configuration.debugSummary)"
        )
        let rawSurface = controller.createSurface(
            bridge: bridge,
            configuration: configuration,
            platformSetup: { [self] config in
                platformSetup?(&config)
                config.scale_factor = scale
            }
        )
        guard let rawSurface else {
            TerminalDebugLog.log(.lifecycle, "surface rebuild failed")
            return
        }

        bridge.rawSurface = rawSurface
        surface = TerminalSurface(rawSurface)
        TerminalDebugLog.log(.lifecycle, "surface rebuild succeeded")
        synchronizeMetrics()
    }

    // MARK: - Metrics

    func synchronizeMetrics() {
        guard let surface else {
            TerminalDebugLog.log(.metrics, "synchronizeMetrics skipped: missing surface")
            return
        }

        let scale = scaleFactor()
        let size = viewSize()
        guard size.width > 0, size.height > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid view size=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height))"
            )
            return
        }

        let pixelWidth = UInt32((size.width * scale).rounded(.down))
        let pixelHeight = UInt32((size.height * scale).rounded(.down))
        guard pixelWidth > 0, pixelHeight > 0 else {
            TerminalDebugLog.log(
                .metrics,
                "synchronizeMetrics skipped: invalid pixel size=\(pixelWidth)x\(pixelHeight)"
            )
            return
        }

        TerminalDebugLog.log(
            .metrics,
            "sync view=\(String(format: "%.2f", size.width))x\(String(format: "%.2f", size.height)) scale=\(String(format: "%.2f", scale)) pixels=\(pixelWidth)x\(pixelHeight)"
        )

        surface.setContentScale(x: scale, y: scale)
        surface.setSize(width: pixelWidth, height: pixelHeight)

        guard let surfaceSize = surface.size(),
              surfaceSize.columns > 0, surfaceSize.rows > 0
        else {
            TerminalDebugLog.log(.metrics, "sync missing grid metrics after resize")
            onMetricsUpdate?()
            return
        }

        let metrics = TerminalViewportMetrics(surfaceSize: surfaceSize, scale: scale)
        guard metrics != lastMetrics else {
            TerminalDebugLog.log(
                .metrics,
                "sync unchanged \(metrics.debugSummary)"
            )
            onMetricsUpdate?()
            return
        }

        lastMetrics = metrics
        TerminalDebugLog.log(.metrics, "sync updated \(metrics.debugSummary)")
        configuration.inMemorySession?.updateViewport(surfaceSize)
        if let delegate = delegate as? any TerminalSurfaceGridResizeDelegate {
            delegate.terminalDidResize(surfaceSize)
        } else if let delegate = delegate as? any TerminalSurfaceResizeDelegate {
            delegate.terminalDidResize(
                columns: Int(surfaceSize.columns),
                rows: Int(surfaceSize.rows)
            )
        }
        onMetricsUpdate?()
    }

    func fitToSize() {
        synchronizeMetrics()
    }

    /// Force a reattached `.exec` TUI (Claude Code / vim / … running under
    /// `zmx attach`, where **ghostty** owns the PTY) to repaint after a
    /// persisted restore. Reattach recreates the surface at the same size, so
    /// no resize delta reaches the child and full-screen programs come back
    /// stale/blank until the user resizes by hand.
    ///
    /// Unlike the host-managed path — which nudges only the child's reported
    /// viewport without touching ghostty's grid (see
    /// `InMemoryTerminalSession.nudgeChildViewportToForceRedraw`) — under exec
    /// the only lever we have is ghostty's own surface size. We shrink it by
    /// one row so ghostty issues a real `TIOCSWINSZ` + `SIGWINCH` to the child,
    /// then restore the true size on a later runloop turn (a real time gap is
    /// required — back-to-back `setSize` calls coalesce to a net no-op and emit
    /// no winsize change). The child sees two genuine SIGWINCHes and repaints.
    /// The one-row shrink reflows a blank grid (nothing to see); if the frame
    /// happened to have content it's a brief one-row blip — the same tradeoff
    /// the host-managed nudge accepts, minus the grid-decoupling it can't do here.
    func nudgeSurfaceResizeForRedraw() {
        guard let surface else {
            TerminalDebugLog.log(.metrics, "exec reattach nudge skipped: missing surface")
            return
        }
        let scale = scaleFactor()
        let size = viewSize()
        guard size.width > 0, size.height > 0 else {
            TerminalDebugLog.log(.metrics, "exec reattach nudge skipped: invalid view size")
            return
        }
        let pixelWidth = UInt32((size.width * scale).rounded(.down))
        let pixelHeight = UInt32((size.height * scale).rounded(.down))
        guard pixelWidth > 0, pixelHeight > 1 else {
            TerminalDebugLog.log(.metrics, "exec reattach nudge skipped: invalid pixel size")
            return
        }
        // Shrink by a full cell height where we can derive it, so the child
        // observes a whole-row delta; fall back to a single pixel otherwise.
        var delta: UInt32 = 1
        if let grid = surface.size(), grid.rows > 0 {
            delta = max(1, pixelHeight / UInt32(grid.rows))
        }
        let shrunk = pixelHeight > delta ? pixelHeight - delta : pixelHeight - 1
        TerminalDebugLog.log(.metrics, "exec reattach nudge: \(pixelWidth)x\(pixelHeight) -> \(pixelWidth)x\(shrunk) -> restore")
        surface.setSize(width: pixelWidth, height: shrunk)
        // Restore the true size on a later turn so ghostty processes the shrink
        // (and emits its SIGWINCH) before the restore emits the second one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self, let surface = self.surface else { return }
            surface.setSize(width: pixelWidth, height: pixelHeight)
            // Re-run the normal sync so Boite-side metrics bookkeeping stays
            // consistent with the surface's now-restored size.
            self.synchronizeMetrics()
        }
    }

    // MARK: - Frame Rendering

    // MARK: Frame instrumentation
    //
    // Answers "is this surface actually hitting the display's refresh rate?"
    // with counted frames rather than an impression. The display link fires at
    // the refresh rate whether or not we manage to draw, so ticks are the
    // denominator and completed draws the numerator; the gap is `dropped`,
    // which is the interesting number — a frame is dropped when the PREVIOUS
    // draw is still in flight, i.e. the GPU submit is not keeping up.
    //
    // Costs a few integer adds per frame and one log line per second, only
    // while the `.render` debug category is on.
    private var fpsWindowStart: UInt64 = 0
    private var fpsTicks = 0
    private var fpsDraws = 0
    private var fpsDropped = 0
    private var fpsDrawNanos: UInt64 = 0

    private func recordFrameStats() {
        let now = DispatchTime.now().uptimeNanoseconds
        if fpsWindowStart == 0 { fpsWindowStart = now; return }
        let elapsed = now - fpsWindowStart
        guard elapsed >= 1_000_000_000 else { return }
        let seconds = Double(elapsed) / 1_000_000_000
        let drawn = fpsDraws
        let avgMs = drawn > 0
            ? Double(fpsDrawNanos) / Double(drawn) / 1_000_000
            : 0
        // `.metrics`, not `.render`: the render category logs a line per tick,
        // which at 120 Hz buries a once-a-second summary in its own noise.
        let stats = TerminalFrameStats(
            drawnPerSecond: Double(drawn) / seconds,
            ticksPerSecond: Double(fpsTicks) / seconds,
            dropped: fpsDropped,
            averageDrawMilliseconds: avgMs
        )
        onFrameStats?(stats)
        TerminalDebugLog.log(
            .metrics,
            String(
                format: "fps drawn=%.1f/s ticks=%.1f/s dropped=%d avgDraw=%.2fms",
                Double(drawn) / seconds,
                Double(fpsTicks) / seconds,
                fpsDropped,
                avgMs
            )
        )
        fpsWindowStart = now
        fpsTicks = 0
        fpsDraws = 0
        fpsDropped = 0
        fpsDrawNanos = 0
    }

    func tick() {
        TerminalDebugLog.log(.render, "tick")
        fpsTicks += 1
        recordFrameStats()
        // App + surface bookkeeping stays on the main actor: `ghostty_app_tick`
        // drains the process-wide app mailbox (shared across ALL surfaces) and
        // `refresh` is a cheap dirty-state update. Only the expensive,
        // possibly GPU-blocking `ghostty_surface_draw` is dispatched off-main.
        controller?.tick()
        surface?.refresh()

        // Drop this frame if the previous draw is still running — never let
        // draws pile up on the render queue.
        guard !drawInFlight, let raw = surface?.rawValue else {
            // Only a real drop: no surface at all isn't a dropped frame.
            if drawInFlight { fpsDropped += 1 }
            return
        }
        drawInFlight = true
        let drawStart = DispatchTime.now().uptimeNanoseconds
        let handle = RawSurfaceHandle(surface: raw)
        renderQueue.async { [weak self] in
            // `ghostty_surface_draw` is a plain C entry point safe to call off
            // the main thread; the surface pointer stays valid because
            // teardown drains this queue before `ghostty_surface_free`.
            //
            // Wrap in an autorelease pool: the draw allocates autoreleased
            // Metal objects (drawables, command buffers). On the main thread
            // the run loop drains these each frame; a bare GCD serial queue
            // does not drain per block, so without this the objects pile up.
            // (The display link's own callback does this too — see
            // `TerminalDisplayLink`.)
            autoreleasepool {
                ghostty_surface_draw(handle.surface)
            }
            terminalRunOnMain { [weak self] in
                guard let self else { return }
                // Layer geometry correction (contentsScale/frame) is
                // CoreAnimation state — back on the main actor after the draw.
                self.onPostRender?()
                self.drawInFlight = false
                self.fpsDraws += 1
                self.fpsDrawNanos += DispatchTime.now().uptimeNanoseconds - drawStart
            }
        }
    }

    // MARK: - Focus

    func setFocus(_ focused: Bool) {
        TerminalDebugLog.log(.lifecycle, "focus=\(focused)")
        surface?.setFocus(focused)
        (delegate as? any TerminalSurfaceFocusDelegate)?
            .terminalDidChangeFocus(focused)
    }

    // MARK: - Occlusion

    /// Tell ghostty whether this surface is visible. An occluded
    /// (`visible == false`) surface skips drawing in ghostty's OWN
    /// renderer thread — so a live-but-hidden surface that still receives
    /// PTY output (a build, a server, an agent) doesn't keep rendering.
    /// Pair with `stopDisplayLink()` (which stops the embedder-driven draw)
    /// to fully quiesce a hidden surface. Mirrors ghostty's occlusion model.
    func setOcclusion(_ visible: Bool) {
        surface?.setOcclusion(visible)
    }

    // MARK: - Cleanup

    func freeSurface() {
        TerminalDebugLog.log(.lifecycle, "free surface")
        tearDownSurface(removingBridgeFrom: controller)
    }

    deinit {
        // Surface lifetime is now bound to the coordinator (and therefore
        // to the owning NSView) — not to window attachment. Tear it down
        // here so the surface lives exactly as long as the NSView, the
        // same shape as the upstream ghostty Mac app. Without this, the
        // surface (and its C-side allocations) would leak on view dealloc
        // now that `viewDidMoveToWindow(nil)` no longer calls freeSurface.
        //
        // `deinit` is `nonisolated` even on `@MainActor` classes, so we
        // can't call the actor-isolated `tearDownSurface(...)` directly.
        // Inline the teardown here using `nonisolated(unsafe)` accesses —
        // surface and bridge are accessed only from the main thread under
        // normal operation, and a deinit on a main-actor class with no
        // outstanding Tasks is itself main-thread-bound in practice.
        TerminalDebugLog.log(.lifecycle, "coordinator deinit — tearing down surface")
        MainActor.assumeIsolated {
            tearDownSurface(removingBridgeFrom: controller)
            displayLink = nil
        }
    }

    private func tearDownSurface(removingBridgeFrom controller: TerminalController?) {
        TerminalDebugLog.log(.lifecycle, "tear down surface")
        configuration.inMemorySession?.setSurface(nil)
        bridge.rawSurface = nil
        surface?.setFocus(false)
        // Barrier: wait for any in-flight off-main draw to finish before we
        // free the surface, so `ghostty_surface_draw` can never touch a
        // pointer that `ghostty_surface_free` has already released (the
        // Ghostty teardown use-after-free). At most one draw is ever in
        // flight (see `drawInFlight`), so this waits one frame at most.
        if surface != nil { renderQueue.sync {} }
        drawInFlight = false
        surface?.free()
        surface = nil
        lastMetrics = nil
        controller?.remove(bridge)
    }

    private func handleCellSizeChange(width: UInt32, height: UInt32) {
        TerminalDebugLog.log(
            .metrics,
            "cell size changed width=\(width) height=\(height)"
        )
        synchronizeMetrics()
        onCellSizeDidChange?()
    }
}

// MARK: - RawSurfaceHandle

/// Carries a raw `ghostty_surface_t` (a `void*`, non-`Sendable`) across the
/// main → render-queue boundary. The unchecked hand-off is sound because the
/// surface's lifetime is fenced: teardown drains `renderQueue` before
/// `ghostty_surface_free`, so the pointer is always valid for the duration of
/// the off-main `ghostty_surface_draw`.
private struct RawSurfaceHandle: @unchecked Sendable {
    let surface: ghostty_surface_t
}

/// Bridges the `nonisolated` display link callback back to `@MainActor`
/// TerminalSurfaceCoordinator. Stored as a separate object because `TerminalSurfaceCoordinator` itself
/// is `@MainActor` and cannot directly conform to `nonisolated` protocol.

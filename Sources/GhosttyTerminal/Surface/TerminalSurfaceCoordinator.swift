//
//  TerminalSurfaceCoordinator.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import Foundation
import GhosttyKit
import MSDisplayLink

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

    private var displayLink: DisplayLink?
    private let displayLinkTarget = DisplayLinkTarget()

    init() {
        bridge.onCellSizeChange = { [weak self] width, height in
            self?.handleCellSizeChange(width: width, height: height)
        }
    }

    func startDisplayLink() {
        guard displayLink == nil else { return }
        TerminalDebugLog.log(.lifecycle, "display link start")
        displayLinkTarget.core = self
        let link = DisplayLink()
        link.delegatingObject(displayLinkTarget)
        displayLink = link
    }

    func stopDisplayLink() {
        TerminalDebugLog.log(.lifecycle, "display link stop")
        displayLink = nil
        displayLinkTarget.core = nil
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

    // MARK: - Frame Rendering

    func tick() {
        TerminalDebugLog.log(.render, "tick")
        // App + surface bookkeeping stays on the main actor: `ghostty_app_tick`
        // drains the process-wide app mailbox (shared across ALL surfaces) and
        // `refresh` is a cheap dirty-state update. Only the expensive,
        // possibly GPU-blocking `ghostty_surface_draw` is dispatched off-main.
        controller?.tick()
        surface?.refresh()

        // Drop this frame if the previous draw is still running — never let
        // draws pile up on the render queue.
        guard !drawInFlight, let raw = surface?.rawValue else { return }
        drawInFlight = true
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
            // (The main-thread path did this too — see MSDisplayLink's
            // `displayLinkCallback`.)
            autoreleasepool {
                ghostty_surface_draw(handle.surface)
            }
            terminalRunOnMain { [weak self] in
                guard let self else { return }
                // Layer geometry correction (contentsScale/frame) is
                // CoreAnimation state — back on the main actor after the draw.
                self.onPostRender?()
                self.drawInFlight = false
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

// MARK: - DisplayLinkTarget

/// Bridges the `nonisolated` display link callback back to `@MainActor`
/// TerminalSurfaceCoordinator. Stored as a separate object because `TerminalSurfaceCoordinator` itself
/// is `@MainActor` and cannot directly conform to `nonisolated` protocol.
private final class DisplayLinkTarget: DisplayLinkDelegate, @unchecked Sendable {
    @MainActor var core: TerminalSurfaceCoordinator?

    nonisolated func synchronization(context _: DisplayLinkCallbackContext) {
        terminalRunOnMain { [weak self] in
            self?.core?.tick()
        }
    }
}

//
//  AppTerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    public final class AppTerminalView: NSView {
        let core = TerminalSurfaceCoordinator()
        var metalLayer: CAMetalLayer?
        var inputHandler: TerminalKeyEventHandler?

        public weak var delegate: (any TerminalSurfaceViewDelegate)? {
            get { core.delegate }
            set { core.delegate = newValue }
        }

        public var controller: TerminalController? {
            get { core.controller }
            set { core.controller = newValue }
        }

        public var configuration: TerminalSurfaceOptions {
            get { core.configuration }
            set { core.configuration = newValue }
        }

        /// Frames-per-second ceiling for this surface, or nil for the display's
        /// own rate.
        ///
        /// Deliberately not part of `configuration`: that struct is the
        /// surface's identity and setting it rebuilds the surface, which for an
        /// exec backend means restarting the shell. A frame rate is a statement
        /// about how hard to work, and applies to the link that is already
        /// running.
        public var preferredFrameRate: Int? {
            get { core.preferredFrameRate }
            set { core.preferredFrameRate = newValue }
        }

        public var surface: TerminalSurface? {
            core.surface
        }

        /// Execute a ghostty binding action (e.g. "copy_to_clipboard", "toggle_split_zoom").
        @discardableResult
        public func performAction(_ action: String) -> Bool {
            core.surface?.performBindingAction(action) ?? false
        }

        /// Pause rendering for a hidden/inactive surface. Stops BOTH draw
        /// drivers: the embedder-driven display link AND ghostty's own
        /// renderer thread (via occlusion). Without the occlusion half, a
        /// hidden surface that keeps getting PTY output (a build, a server,
        /// an agent) would keep rendering on its own thread. Live-but-hidden
        /// surfaces keep their PTY + grid; they just stop drawing — so many
        /// boites can stay live without N surfaces all hammering the GPU.
        public func pauseRendering() {
            core.stopDisplayLink()
            core.setOcclusion(false)
        }

        /// Resume rendering when the surface becomes visible/active. Marks it
        /// visible to ghostty again, then restarts the display link.
        ///
        /// If the surface was FREED while hidden (`releaseSurfaceForHiding`,
        /// e.g. the window was minimized / occluded), rebuild it here first —
        /// mirroring `viewDidMoveToWindow`'s `surface == nil` rebuild. That path
        /// is the usual trigger, but it only fires when the view actually leaves
        /// and re-enters a window; an occluded-then-revealed view never moves,
        /// so without this it would come back to a `nil` surface (blank, dead)
        /// until an unrelated view remount rebuilt it.
        ///
        /// Returns `true` iff a freed surface was actually rebuilt here. A
        /// rebuild is a *restore* — for exec the old surface's `zmx attach` was
        /// SIGHUP'd on free and a brand-new one is spawned on rebuild, so the
        /// caller must run the same reattach-repaint nudge a cold restore does
        /// (a reattached full-screen TUI won't repaint without a SIGWINCH).
        @discardableResult
        public func resumeRendering() -> Bool {
            let rebuilt = core.surface == nil
            if rebuilt {
                core.rebuildIfReady()
                updateColorScheme()
            }
            core.setOcclusion(true)
            core.startDisplayLink()
            return rebuilt
        }

        /// Efficiency-mode freeze for a VISIBLE-but-unfocused split pane —
        /// the exact ghostty model. We do NOT occlude (the pane stays on-screen
        /// and "visible" to ghostty); we just:
        ///   1. stop the continuous embedder display link — no per-vsync draws;
        ///   2. mark the surface unfocused to ghostty — which pauses the cursor
        ///      blink (hollow cursor) and drops the render thread to a lower
        ///      priority, exactly like ghostty's own unfocused splits.
        /// Because the surface stays visible, ghostty's change-driven renderer
        /// still repaints on PTY output — a background build in an unfocused
        /// pane keeps updating, just not at vsync cadence. This mirrors
        /// ghostty's `visible AND focused` display-link gating.
        public func freezeForEfficiency() {
            core.stopDisplayLink()
            core.surface?.setFocus(false)
        }

        /// Undo `freezeForEfficiency()` — refocus the surface (restores the
        /// blinking cursor / render priority) and restart the display link.
        public func unfreezeForEfficiency() {
            core.surface?.setFocus(true)
            core.startDisplayLink()
        }

        // MARK: - Cursor focus reconciliation

        /// Tracked ourselves because `window?.firstResponder` isn't updated to
        /// (or away from) `self` until AFTER `becomeFirstResponder` /
        /// `resignFirstResponder` return — so we can't read it inside those
        /// overrides. Kept in sync by those two handlers.
        var isTerminalFirstResponder = false

        /// When `true`, this surface keeps its ghostty cursor "focused" (a
        /// blinking, active cursor) even while it is NOT the window's first
        /// responder — for a host that highlights "typing lands here" on one
        /// pane while keyboard focus sits elsewhere (e.g. a sidebar list). Does
        /// NOT change key routing: keystrokes still go to the real first
        /// responder. Setting it re-reconciles focus immediately.
        public var keepsCursorFocusWhenNotFirstResponder = false {
            didSet {
                guard oldValue != keepsCursorFocusWhenNotFirstResponder else { return }
                reconcileCursorFocus()
            }
        }

        /// Single decision point for the surface's ghostty focus: focused iff the
        /// window is key AND (we're first responder OR the sticky hint is on).
        /// Every focus-affecting AppKit callback routes through here so they can't
        /// disagree, and so a freshly-attached, never-focused surface can't linger
        /// at ghostty's default (which would blink alongside the real focus).
        func reconcileCursorFocus() {
            let focused = (window?.isKeyWindow == true)
                && (isTerminalFirstResponder || keepsCursorFocusWhenNotFirstResponder)
            core.setFocus(focused)
        }

        /// Release the ghostty GPU surface for a boite that's been switched
        /// away from. Frees the surface's IOSurfaces / render targets — and,
        /// critically, the WindowServer presentation backing that is the bulk
        /// of the per-pane memory — WITHOUT touching the PTY/backend, which
        /// live on the panel state, not the surface. Occlusion or a stopped
        /// display link only pause DRAWING; the backing stays resident as long
        /// as the surface exists, so a merely-hidden pane keeps its full GPU
        /// footprint. Only `surface.free()` actually reclaims it — the same
        /// call the close path uses, minus the backend teardown.
        ///
        /// The view + coordinator stay alive (so this cached NSView, its
        /// controller, and the live session all persist). When the boite is
        /// shown again the cached view re-attaches to a window and
        /// `viewDidMoveToWindow` sees `surface == nil` and rebuilds, redrawing
        /// the reconnected backend's current screen. This is ghostty's
        /// off-screen unrealize expressed through the embedder API: GPU
        /// reclaimed, session kept, seamless return.
        public func releaseSurfaceForHiding() {
            core.stopDisplayLink()
            core.freeSurface()
        }

        /// Notify the terminal that its view size has changed.
        /// Updates the PTY window size so programs (including zmx) receive SIGWINCH.
        public func notifySizeChanged() {
            core.synchronizeMetrics()
        }

        /// Force a reattached host-managed TUI (Claude Code / vim / … under zmx)
        /// to repaint after a persisted restore / surface rebuild. Reattach
        /// recreates the surface at the same size, so no resize delta reaches the
        /// child and the frame comes back stale until the user types AND resizes
        /// by hand.
        ///
        /// Host-managed panes nudge the child's viewport one row and back — two
        /// real SIGWINCHes — without touching ghostty's display grid (no visible
        /// reflow). Exec panes (ghostty owns the PTY; no in-memory session) have
        /// no such decoupled lever, so they nudge ghostty's surface size instead.
        /// Both end up delivering the child a genuine winsize delta so a
        /// full-screen TUI repaints. See
        /// `InMemoryTerminalSession.nudgeChildViewportToForceRedraw` and
        /// `TerminalSurfaceCoordinator.nudgeSurfaceResizeForRedraw`.
        public func forceReattachRedraw() {
            if let session = core.configuration.inMemorySession {
                session.nudgeChildViewportToForceRedraw()
            } else {
                core.nudgeSurfaceResizeForRedraw()
            }
        }

        override public init(frame: NSRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func commonInit() {
            wantsLayer = true

            let metal = CAMetalLayer()
            metal.device = MTLCreateSystemDefaultDevice()
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            metal.isOpaque = false
            metal.backgroundColor = NSColor.clear.cgColor
            layer = metal
            metalLayer = metal
            layer?.backgroundColor = NSColor.clear.cgColor

            inputHandler = TerminalKeyEventHandler(view: self)
            setupTrackingArea()
            registerForDraggedTypes([.fileURL])

            core.isAttached = { [weak self] in self?.window != nil }
            core.displayLinkHost = { [weak self] in self }
            core.scaleFactor = { [weak self] in
                Double(
                    self?.window?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor ?? 2.0
                )
            }
            core.viewSize = { [weak self] in
                guard let self else { return (0, 0) }
                return (bounds.width, bounds.height)
            }
            core.platformSetup = { [weak self] config in
                guard let self else { return }
                config.platform_tag = GHOSTTY_PLATFORM_MACOS
                config.platform = ghostty_platform_u(
                    macos: ghostty_platform_macos_s(
                        nsview: Unmanaged.passUnretained(self).toOpaque()
                    )
                )
            }
            core.onMetricsUpdate = { [weak self] in
                self?.updateMetalLayerMetrics()
            }
            core.onPostRender = { [weak self] in
                self?.enforceMetalLayerScale()
            }
            core.onFrameStats = { [weak self] stats in
                self?.onFrameStats?(stats)
            }
        }

        /// Measured frame rate for this surface, once per second.
        ///
        /// Always computed (a few integer adds per frame); a host that doesn't
        /// set this just never hears about it.
        public var onFrameStats: ((TerminalFrameStats) -> Void)?

        override public func layout() {
            super.layout()
            // Notify ghostty of the new size so it can update the PTY window size
            // and reflow terminal content. Called after layout is complete so
            // bounds reflects the final size.
            let size = bounds.size
            guard size.width > 0, size.height > 0 else { return }
            if let metalLayer {
                let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
                metalLayer.drawableSize = CGSize(
                    width: size.width * scale,
                    height: size.height * scale
                )
            }
            core.synchronizeMetrics()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif

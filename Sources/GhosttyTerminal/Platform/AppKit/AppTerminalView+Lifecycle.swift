//
//  AppTerminalView+Lifecycle.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    public extension AppTerminalView {
        internal func setupTrackingArea() {
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ]
            let area = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            setupTrackingArea()
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            isTerminalFirstResponder = true
            reconcileCursorFocus()
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            isTerminalFirstResponder = false
            // Reconcile (NOT unconditional setFocus(false)): if this pane is the
            // host's sticky "typing lands here" hint, it must keep blinking even
            // after yielding first responder (e.g. to a sidebar).
            reconcileCursorFocus()
            return result
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // Before anything reads it: the cache may have gone stale while we
            // were out of the hierarchy. See `resyncFirstResponderCache`.
            resyncFirstResponderCache()
            if window != nil {
                // If a surface already exists (we were detached then
                // re-attached, e.g. SwiftUI tree restructure for a split
                // pane) skip the rebuild — it would tear down the live
                // surface and create a fresh one, losing scrollback,
                // cursor, and any in-progress command. Only build the
                // surface on first attachment.
                let survivingSurface = core.surface != nil
                if !survivingSurface {
                    core.rebuildIfReady()
                }
                updateColorScheme()
                core.startDisplayLink()
                // A freshly-built surface defaults to ghostty's own focus state;
                // reconcile so a non-focused pane doesn't come up blinking.
                reconcileCursorFocus()
                if survivingSurface {
                    // A rebuild already synchronized; a SURVIVOR did not, and
                    // nothing else will. Re-attaching into the same slot is the
                    // same size in points, so `setFrameSize` doesn't fire and
                    // `layout()` is never marked — the one moment a pane can
                    // return to a window on a different display than the one it
                    // left (a boite switched away from, a screen not showing,
                    // the drop-down summoned onto another monitor) is also the
                    // one moment nothing asks about the scale.
                    updateLayerMetrics()
                    core.synchronizeMetrics()
                }
                pushDisplayID()

                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidBecomeKey),
                    name: NSWindow.didBecomeKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidResignKey),
                    name: NSWindow.didResignKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidChangeScreen),
                    name: NSWindow.didChangeScreenNotification,
                    object: window
                )
            } else {
                // View was removed from its window. Stop the display link
                // (no point rendering into a void) but DON'T free the
                // surface — the same NSView is often reattached moments
                // later when SwiftUI re-shapes its host tree (e.g. a
                // sibling pane splits or closes, restructuring the
                // recursive split-tree view hierarchy). Freeing here
                // would destroy scrollback / cursor / current command
                // for every survivor of an unrelated pane operation —
                // exactly the behavior the upstream ghostty Mac app
                // avoids by tying surface lifetime to the NSView (deinit)
                // rather than to window attachment. The surface is freed
                // when the coordinator deinits (see TerminalSurfaceCoordinator).
                core.stopDisplayLink()
                NotificationCenter.default.removeObserver(self)
            }
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            // A re-parent WITHIN one window doesn't change `window`, so
            // `viewDidMoveToWindow` never fires for it. Covered here so there is
            // no hierarchy move the cache can survive incorrectly.
            resyncFirstResponderCache()
        }

        /// Re-read first-responder status from the window, which is the only
        /// authority once we are outside `becomeFirstResponder` /
        /// `resignFirstResponder`.
        ///
        /// **Why the cache cannot be trusted across a hierarchy move.** MEASURED:
        /// when a view that holds first responder is removed from its superview,
        /// AppKit silently points the window's `firstResponder` back at the
        /// window and **never sends `resignFirstResponder`**. So the flag those
        /// two handlers maintain stays `true` for the rest of the view's life.
        ///
        /// That is not cosmetic here. `reconcileCursorFocus` ORs this flag with
        /// the sticky hint, so a detached-then-readopted pane reports itself
        /// focused to ghostty alongside the pane that really has focus — two
        /// blinking cursors. A host that re-parents a cached surface to preserve
        /// scrollback across a split (the whole reason the surface outlives the
        /// view tree) therefore leaks one extra blinking cursor per split.
        ///
        /// Deliberately a re-read rather than an unconditional clear: a view can
        /// also be re-parented while it legitimately still holds first responder,
        /// and clearing would then be the same bug in the other direction.
        private func resyncFirstResponderCache() {
            isTerminalFirstResponder = (window?.firstResponder === self)
        }

        @objc internal func windowDidBecomeKey(_: Notification) {
            reconcileCursorFocus()
        }

        @objc internal func windowDidResignKey(_: Notification) {
            // Not key → reconcile resolves to unfocused (never blink off-key).
            reconcileCursorFocus()
        }

        /// The window moved to another display.
        ///
        /// AppKit does send `viewDidChangeBackingProperties` for this, but not
        /// dependably *after* the window has adopted the new screen's
        /// `backingScaleFactor` — so the scale read there can still be the
        /// display we left, and unlike a resize nothing comes along later to
        /// correct it: a move changes no point-sized frame, so `setFrameSize`
        /// never fires and `layout()` is never marked. The surface goes on
        /// rendering at the old DPI until the window is resized by hand.
        ///
        /// Upstream ghostty hits the same thing and answers it the same way
        /// (ghostty-org/ghostty#2731): re-run the backing-properties path one
        /// hop through the main queue, by which time the value is right.
        @objc internal func windowDidChangeScreen(_ notification: Notification) {
            guard let window, (notification.object as? NSWindow) === window else { return }
            pushDisplayID()
            DispatchQueue.main.async { [weak self] in
                self?.viewDidChangeBackingProperties()
            }
        }

        /// Tell ghostty which display it is drawing on, so its renderer times
        /// itself against that one's refresh rate. Nothing else carries this.
        internal func pushDisplayID() {
            guard let displayID = window?.screen?.terminalDisplayID else { return }
            core.surface?.setDisplayID(displayID)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            core.synchronizeMetrics()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateLayerMetrics()
            core.synchronizeMetrics()
        }

        func fitToSize() {
            core.fitToSize()
        }

        /// The layer ghostty actually presents into — **not** the one
        /// `commonInit` made.
        ///
        /// MEASURED, and the reason a display change survived every fix aimed
        /// at it. `commonInit` builds a `CAMetalLayer` and assigns it, but
        /// ghostty does not render into a `CAMetalLayer` at all: it draws into
        /// an `IOSurface` and hands it to a `CALayer` subclass of its own. On
        /// macOS it installs that layer by making this view **layer-hosting** —
        /// `renderer/Metal.zig` does `view.setProperty("layer", ioSurfaceLayer)`
        /// and then `wantsLayer = true` — so the moment a surface exists, the
        /// layer we made is an orphan holding no pixels, and everything written
        /// to it is a no-op on screen.
        ///
        /// Read `layer` fresh every time. A surface rebuild
        /// (`releaseSurfaceForHiding` → `resumeRendering`) installs a NEW one,
        /// so this can never be cached — caching it is the original bug.
        internal var presentedLayer: CALayer? { layer }

        /// `contentsScale` on the presented layer is not a hint. On macOS it is
        /// the ONLY thing that tells ghostty how many pixels to render.
        ///
        /// `renderer/Metal.zig`'s `surfaceSize()` returns
        /// `layer.bounds × layer.contentsScale`, and `generic.zig` re-reads it
        /// at the top of EVERY frame, overwriting its own `size.screen` with
        /// the answer. `ghostty_surface_set_size` only ever reaches the terminal
        /// side (grid, PTY, reflow); the renderer's pixel count comes from here.
        ///
        /// And nothing else will set it. AppKit maintains `contentsScale` for
        /// layer-BACKED views; this one is layer-HOSTING, and for those the
        /// embedder owns it. So a window moved to a display with a different
        /// backing scale renders at the scale its surface was born with until
        /// this runs — magnified by the compositor and, because ghostty's layer
        /// draws `contentsGravity = topLeft`, pinned into the corner rather
        /// than stretched.
        ///
        /// The transaction is not decoration: without it Core Animation
        /// animates the change, turning a cross-display move into a visible
        /// scale-up-and-settle of the whole terminal. Upstream ghostty disables
        /// it here for the same reason.
        private func applyContentsScale(_ scale: CGFloat) {
            guard let presentedLayer, presentedLayer.contentsScale != scale else { return }
            TerminalDebugLog.log(
                .metrics,
                "layer contentsScale \(String(format: "%.2f", presentedLayer.contentsScale)) -> \(String(format: "%.2f", scale)) on \(type(of: presentedLayer))"
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            presentedLayer.contentsScale = scale
            CATransaction.commit()
        }

        /// `core.onMetricsUpdate` — the surface has just been told a new size.
        internal func updateLayerMetrics() {
            applyContentsScale(core.scaleFactor())
        }

        /// `core.onPostRender` — runs after every frame, which makes it the
        /// place a backing scale that changed without anybody telling us
        /// converges. See `resynchronizeIfScaleDrifted`.
        internal func enforcePresentedLayerScale() {
            core.resynchronizeIfScaleDrifted()
            applyContentsScale(core.scaleFactor())
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColorScheme()
        }

        internal func updateColorScheme() {
            let scheme: TerminalColorScheme = switch effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: .dark
            default: .light
            }
            surface?.setColorScheme(scheme.ghosttyValue)
            controller?.setColorScheme(scheme)
        }
    }

    extension NSScreen {
        /// The `CGDirectDisplayID` behind this screen. AppKit only publishes it
        /// through the device description, under a key it does not name.
        var terminalDisplayID: UInt32? {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            return (deviceDescription[key] as? NSNumber)?.uint32Value
        }
    }
#endif

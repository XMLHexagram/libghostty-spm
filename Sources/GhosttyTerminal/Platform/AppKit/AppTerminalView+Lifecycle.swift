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
            if window != nil {
                // If a surface already exists (we were detached then
                // re-attached, e.g. SwiftUI tree restructure for a split
                // pane) skip the rebuild — it would tear down the live
                // surface and create a fresh one, losing scrollback,
                // cursor, and any in-progress command. Only build the
                // surface on first attachment.
                if core.surface == nil {
                    core.rebuildIfReady()
                }
                updateColorScheme()
                core.startDisplayLink()
                // A freshly-built surface defaults to ghostty's own focus state;
                // reconcile so a non-focused pane doesn't come up blinking.
                reconcileCursorFocus()

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

        @objc internal func windowDidBecomeKey(_: Notification) {
            reconcileCursorFocus()
        }

        @objc internal func windowDidResignKey(_: Notification) {
            // Not key → reconcile resolves to unfocused (never blink off-key).
            reconcileCursorFocus()
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            core.synchronizeMetrics()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateMetalLayerMetrics()
            core.synchronizeMetrics()
        }

        func fitToSize() {
            core.fitToSize()
        }

        internal func updateMetalLayerMetrics() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = core.scaleFactor()
            metalLayer?.contentsScale = scale
            metalLayer?.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }

        internal func enforceMetalLayerScale() {
            guard let metalLayer else { return }
            let scale = core.scaleFactor()
            if metalLayer.contentsScale != scale {
                metalLayer.contentsScale = scale
            }
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
#endif

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    @testable import GhosttyTerminal
    import Testing

    /// `AppTerminalView.isTerminalFirstResponder` is a cache, and its comment used
    /// to claim it was "kept in sync by `becomeFirstResponder` /
    /// `resignFirstResponder`". It is not: AppKit does **not** send
    /// `resignFirstResponder` when a first-responder view is removed from its
    /// superview — it silently points the window's `firstResponder` back at the
    /// window.
    ///
    /// That matters because `reconcileCursorFocus` is
    /// `isKeyWindow && (isTerminalFirstResponder || keepsCursorFocus…)`. A stale
    /// `true` therefore reports the surface as focused to ghostty forever, and a
    /// host that detaches and re-adopts a cached surface to preserve scrollback
    /// across a split ends up with one extra blinking cursor per split.
    @MainActor
    struct TerminalFirstResponderCacheTests {
        /// Builds the window off-screen; `makeFirstResponder` does not need a key
        /// window, so nothing here depends on the test process being activated.
        private func makeHost() -> (NSWindow, NSView) {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled],
                backing: .buffered,
                defer: false
            )
            let content = NSView(frame: window.contentLayoutRect)
            window.contentView = content
            return (window, content)
        }

        /// The split path: the surviving pane's cached surface is detached from
        /// the view tree and re-adopted under its new parent.
        @Test
        func detachingAFirstResponderSurfaceClearsItsCachedClaim() {
            let (window, content) = makeHost()
            let view = AppTerminalView(frame: .zero)
            content.addSubview(view)

            #expect(window.makeFirstResponder(view))
            #expect(view.isTerminalFirstResponder)

            // Exactly what a host does to move a cached surface to a new parent.
            view.removeFromSuperview()
            content.addSubview(view)

            // AppKit gave first responder back to the window without telling us.
            #expect(window.firstResponder !== view)
            #expect(!view.isTerminalFirstResponder)
        }

        /// The other direction, and why the fix re-reads instead of clearing:
        /// MEASURED — re-parenting within one window *keeps* the view as first
        /// responder, and `viewDidMoveToWindow` never fires for it (the window
        /// did not change), so only `viewDidMoveToSuperview` sees this move.
        @Test
        func reparentingWithinAWindowKeepsAGenuineFirstResponderClaim() {
            let (window, content) = makeHost()
            let left = NSView(frame: .zero)
            let right = NSView(frame: .zero)
            content.addSubview(left)
            content.addSubview(right)

            let view = AppTerminalView(frame: .zero)
            left.addSubview(view)
            #expect(window.makeFirstResponder(view))

            right.addSubview(view)

            #expect(view.superview === right)
            #expect(window.firstResponder === view)
            #expect(view.isTerminalFirstResponder)
        }

        /// Two surfaces must never both claim it. Without the resync this is the
        /// user-visible bug: pane A is detached and re-adopted by the split, pane
        /// B is then given focus, and both report themselves focused to ghostty.
        @Test
        func onlyOneSurfaceClaimsFirstResponderAfterASplit() {
            let (window, content) = makeHost()
            let paneA = AppTerminalView(frame: .zero)
            content.addSubview(paneA)
            #expect(window.makeFirstResponder(paneA))

            // Split: A is re-adopted under the new tree, B is created and focused.
            paneA.removeFromSuperview()
            content.addSubview(paneA)
            let paneB = AppTerminalView(frame: .zero)
            content.addSubview(paneB)
            #expect(window.makeFirstResponder(paneB))

            #expect(!paneA.isTerminalFirstResponder)
            #expect(paneB.isTerminalFirstResponder)
        }
    }
#endif

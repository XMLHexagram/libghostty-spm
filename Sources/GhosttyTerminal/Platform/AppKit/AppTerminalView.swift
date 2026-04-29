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

        public var surface: TerminalSurface? {
            core.surface
        }

        /// Execute a ghostty binding action (e.g. "copy_to_clipboard", "toggle_split_zoom").
        @discardableResult
        public func performAction(_ action: String) -> Bool {
            core.surface?.performBindingAction(action) ?? false
        }

        /// Pause the display link to stop Metal rendering.
        /// Call this when the terminal view is hidden/inactive to save CPU.
        public func pauseRendering() {
            core.stopDisplayLink()
        }

        /// Resume the display link to restart Metal rendering.
        /// Call this when the terminal view becomes visible/active.
        public func resumeRendering() {
            core.startDisplayLink()
        }

        /// Notify the terminal that its view size has changed.
        /// Updates the PTY window size so programs (including zmx) receive SIGWINCH.
        public func notifySizeChanged() {
            core.synchronizeMetrics()
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
        }

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

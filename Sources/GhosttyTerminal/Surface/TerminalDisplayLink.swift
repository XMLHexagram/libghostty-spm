//
//  TerminalDisplayLink.swift
//  libghostty-spm
//

import Foundation
import QuartzCore

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

/// The frame clock for one surface.
///
/// Replaces MSDisplayLink, which on macOS resolved to `CVDisplayLink` — and
/// that carried three problems, only one of which was visible:
///
/// * **No rate control.** `CVDisplayLink` runs at the display's rate and offers
///   no way to ask for less. A cap implemented by skipping ticks lowers GPU work
///   but leaves the CPU waking at full refresh, so it saves heat and not much
///   battery. `CADisplayLink.preferredFrameRateRange` is the only mechanism that
///   lets the system actually slow the clock down — and on ProMotion, the panel
///   with it.
/// * **One link for every surface.** It was built with
///   `CVDisplayLinkCreateWithActiveCGDisplays` behind a process-wide singleton,
///   so every surface ticked together at whatever rate that link picked. A view
///   dragged onto a 60 Hz display kept being driven at 120. The AppKit path here
///   asks the VIEW for its link, which follows the screen the view is actually
///   on and re-times itself when it moves.
/// * **Deprecated** since macOS 15.
///
/// The macOS 13 fallback keeps a `CVDisplayLink`, because `NSView.displayLink`
/// arrived in 14 and this package still supports 13. On that path a rate cap is
/// honoured by dropping ticks, which is the lesser mechanism — noted here rather
/// than silently delivering a worse result under the same setting.
@MainActor
final class TerminalDisplayLink {
    /// Frames per second ceiling. `nil` — the default — means the display's own
    /// rate, which is what a terminal should do unless someone asks otherwise.
    var preferredFrameRate: Int? {
        didSet {
            guard preferredFrameRate != oldValue else { return }
            applyFrameRate()
        }
    }

    private let onTick: () -> Void
    private var target: Target?

    /// Typed `AnyObject` because `CADisplayLink` is itself macOS 14+ and this
    /// package still declares 13 — a stored property cannot carry availability,
    /// so the type is erased here and recovered behind `#available` at each of
    /// the three places that touch it. If the package floor ever moves to 14,
    /// this and the whole legacy branch below collapse to one `CADisplayLink?`.
    private var link: AnyObject?

    #if canImport(AppKit) && !canImport(UIKit)
        private var legacyLink: CVDisplayLink?
        /// Only used by the macOS 13 fallback — see the type doc.
        private var lastTickTime: CFTimeInterval = 0
    #endif

    /// `host` is asked for a view at start time rather than held, so this owns
    /// nothing that could outlive the surface.
    init(host: @escaping () -> PlatformViewForDisplayLink?, onTick: @escaping () -> Void) {
        self.onTick = onTick
        self.host = host
    }

    private let host: () -> PlatformViewForDisplayLink?

    deinit {
        // `invalidate` is main-actor work and deinit is nonisolated; the owner
        // (`TerminalSurfaceCoordinator`) always calls `stop()` before dropping
        // this, so there is nothing left to tear down here.
    }

    func start() {
        stop()
        let target = Target { [weak self] in self?.tick() }
        self.target = target

        #if canImport(UIKit)
            let created = CADisplayLink(target: target, selector: #selector(Target.fire))
            created.add(to: .main, forMode: .common)
            link = created
        #elseif canImport(AppKit)
            if #available(macOS 14.0, *), let view = host() {
                let created = view.displayLink(target: target, selector: #selector(Target.fire))
                created.add(to: .main, forMode: .common)
                link = created
            } else {
                startLegacyLink(target: target)
            }
        #endif
        applyFrameRate()
    }

    func stop() {
        if #available(macOS 14.0, iOS 3.1, *) {
            (link as? CADisplayLink)?.invalidate()
        }
        link = nil
        #if canImport(AppKit) && !canImport(UIKit)
            if let legacyLink { CVDisplayLinkStop(legacyLink) }
            legacyLink = nil
        #endif
        target = nil
    }

    private func tick() {
        #if canImport(AppKit) && !canImport(UIKit)
            // Rate limiting for the legacy path only. On the CADisplayLink path
            // the system is already delivering at the requested rate, and
            // second-guessing it here would drop frames it had every intention
            // of honouring.
            if link == nil, let cap = preferredFrameRate, cap > 0 {
                let now = CACurrentMediaTime()
                guard now - lastTickTime >= 1.0 / Double(cap) - 0.001 else { return }
                lastTickTime = now
            }
        #endif
        onTick()
    }

    private func applyFrameRate() {
        if #available(macOS 14.0, iOS 15.0, *) {
            guard let link = link as? CADisplayLink else { return }
            guard let cap = preferredFrameRate, cap > 0 else {
                // An all-zero range is the documented "no preference" value —
                // NOT a range of 0…0, which would ask for no frames at all.
                link.preferredFrameRateRange = CAFrameRateRange.default
                return
            }
            // `maximum` is the ceiling that matters; `preferred` tells the
            // system where to sit inside the range, and a minimum of 1 lets it
            // drop further when nothing is moving rather than pinning the clock.
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 1, maximum: Float(cap), preferred: Float(cap)
            )
        }
    }

    #if canImport(AppKit) && !canImport(UIKit)
        private func startLegacyLink(target: Target) {
            var created: CVDisplayLink?
            CVDisplayLinkCreateWithActiveCGDisplays(&created)
            guard let created else { return }
            // The callback runs off the main thread; hop before touching
            // anything, and wrap in a pool because a bare CV callback has no
            // run loop to drain the autoreleased Metal objects a draw makes.
            let box = Unmanaged.passUnretained(target).toOpaque()
            CVDisplayLinkSetOutputCallback(created, { _, _, _, _, _, context in
                guard let context else { return kCVReturnSuccess }
                let target = Unmanaged<Target>.fromOpaque(context).takeUnretainedValue()
                DispatchQueue.main.async { autoreleasepool { target.fire() } }
                return kCVReturnSuccess
            }, box)
            CVDisplayLinkStart(created)
            legacyLink = created
        }
    #endif

    /// `CADisplayLink` needs an `@objc` selector target, and the link retains
    /// it — so it can't be the coordinator without making a cycle.
    @MainActor
    private final class Target: NSObject {
        private let body: () -> Void
        init(_ body: @escaping () -> Void) { self.body = body }
        @objc nonisolated func fire() {
            MainActor.assumeIsolated { body() }
        }
    }
}

#if canImport(UIKit)
    typealias PlatformViewForDisplayLink = UIView
#elseif canImport(AppKit)
    typealias PlatformViewForDisplayLink = NSView
#endif

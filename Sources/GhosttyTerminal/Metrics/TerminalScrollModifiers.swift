//
//  TerminalScrollModifiers.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
#endif

public struct TerminalScrollModifiers: Sendable {
    public let rawValue: ghostty_input_scroll_mods_t

    public init(rawValue: ghostty_input_scroll_mods_t = 0) {
        self.rawValue = rawValue
    }

    public init(precision: Bool, momentum: Momentum = .none) {
        var value: Int32 = 0
        if precision { value |= 1 }
        value |= (momentum.rawValue & 0x7) << 1
        rawValue = value
    }

    public var precision: Bool {
        (rawValue & 1) != 0
    }

    public var momentum: Momentum {
        Momentum(rawValue: (rawValue >> 1) & 0x7) ?? .none
    }

    /// Mirrors ghostty's `input.ScrollMods.Momentum`, which is `enum(u3)` — all
    /// SEVEN cases, and three bits.
    ///
    /// This used to model four and mask two bits, so `.ended` and `.cancelled`
    /// were folded into `.none` on the way out and the core could never tell a
    /// finished fling from an ordinary event. Nothing consumed momentum yet, so
    /// it cost nothing — but it is the signal any settle-on-gesture-end
    /// behaviour has to hang off, and a silently truncated enum is a bad thing
    /// to discover later.
    public enum Momentum: Int32, Sendable {
        case none = 0
        case began = 1
        case stationary = 2
        case changed = 3
        case ended = 4
        case cancelled = 5
        case mayBegin = 6
    }

    #if canImport(AppKit) && !canImport(UIKit)
        static func momentumFrom(phase: NSEvent.Phase) -> Momentum {
            if phase.contains(.began) { return .began }
            if phase.contains(.stationary) { return .stationary }
            if phase.contains(.changed) { return .changed }
            if phase.contains(.ended) { return .ended }
            if phase.contains(.cancelled) { return .cancelled }
            if phase.contains(.mayBegin) { return .mayBegin }
            return .none
        }
    #endif
}

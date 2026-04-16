//
//  AppTerminalView+Input.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    public extension AppTerminalView {
        /// Intercepts key equivalents to prevent the menu system from
        /// stealing keys meant for the terminal (Cmd+C for SIGINT, etc.).
        ///
        /// Returns `true` for modifier key combos that the terminal should
        /// handle, preventing the menu bar from consuming them.
        /// Returns `false` for plain keys (backspace, arrows) — these go
        /// through normal `keyDown:` dispatch.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard window?.firstResponder === self
                || window?.firstResponder === inputContext
            else { return false }
            guard event.type == .keyDown, let rawSurface = surface?.rawValue else { return false }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let hasActionMod = flags.contains(.command)
                || flags.contains(.control) || flags.contains(.option)
            guard hasActionMod else { return false }

            // Check if this is a Ghostty keybinding
            let keyEvent = event.buildKeyInput(action: event.isARepeat
                ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS)
            if ghostty_surface_key_is_binding(rawSurface, keyEvent, nil) {
                inputHandler?.handleKeyDown(with: event)
                return true
            }

            return false
        }

        override func keyDown(with event: NSEvent) {
            inputHandler?.handleKeyDown(with: event)
        }

        override func keyUp(with event: NSEvent) {
            inputHandler?.handleKeyUp(with: event)
        }

        override func flagsChanged(with event: NSEvent) {
            inputHandler?.handleFlagsChanged(with: event)
        }

        override func doCommand(by selector: Selector) {
            inputHandler?.handleTextCommand(selector)
        }

        internal func mousePoint(from event: NSEvent) -> (x: CGFloat, y: CGFloat) {
            let point = convert(event.locationInWindow, from: nil)
            return (point.x, bounds.height - point.y)
        }

        override func mouseDown(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override func mouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_LEFT,
                mods: mods.ghosttyMods
            )
        }

        override func rightMouseDown(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override func rightMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_RIGHT,
                mods: mods.ghosttyMods
            )
        }

        override func otherMouseDown(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_PRESS,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override func otherMouseUp(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
            surface?.sendMouseButton(
                state: GHOSTTY_MOUSE_RELEASE,
                button: GHOSTTY_MOUSE_MIDDLE,
                mods: mods.ghosttyMods
            )
        }

        override func mouseMoved(with event: NSEvent) {
            let (x, y) = mousePoint(from: event)
            let mods = TerminalInputModifiers(from: event.modifierFlags)
            surface?.sendMousePos(x: x, y: y, mods: mods.ghosttyMods)
        }

        override func mouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            mouseMoved(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            let scrollMods = TerminalScrollModifiers(
                precision: event.hasPreciseScrollingDeltas,
                momentum: TerminalScrollModifiers.momentumFrom(phase: event.momentumPhase)
            )
            surface?.sendMouseScroll(
                x: event.scrollingDeltaX,
                y: event.scrollingDeltaY,
                mods: scrollMods.rawValue
            )
        }
    }
#endif

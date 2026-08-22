//
//  TerminalKeyEventHandler@AppKit.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    final class TerminalKeyEventHandler {
        private weak var view: AppTerminalView?
        var inputMethodHandler: TerminalTextInputHandler?

        init(view: AppTerminalView) {
            self.view = view
            inputMethodHandler = TerminalTextInputHandler(view: view)
        }

        func handleKeyDown(with event: NSEvent) {
            // First statement, before every guard: "nothing in the log" then
            // means the key never arrived here, which is a different bug from
            // anything that happens below.
            TerminalDebugLog.log(
                .input,
                "keyDown enter code=\(event.keyCode) mods=\(Self.describe(event.modifierFlags))"
            )
            guard let view, let surface = view.surface else { return }

            if handleDirectInputIfNeeded(event) {
                return
            }

            let action: ghostty_input_action_e = event.isARepeat
                ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            guard !event.modifierFlags.contains(.command) else {
                sendKeyEvent(for: event, action: action, to: surface, includeText: false)
                return
            }

            // Track whether we had marked text (IME composition) BEFORE
            // interpretKeyEvents, because it may clear the marked text
            // during processing. If it does, we must not send the raw key
            // to ghostty — otherwise Delete after single-char IME input
            // would both cancel the composition AND delete a real character.
            let hadMarkedText = inputMethodHandler?.hasMarkedText == true

            inputMethodHandler?.startCollectingText()
            // **Composition runs on the mods the ENGINE says to translate
            // with**, which is not always the ones the user is holding.
            //
            // `macos-option-as-alt` lives on this line and nowhere else. macOS
            // composes ⌥s into `ß` inside `interpretKeyEvents`, before the
            // engine sees anything, so a config that says "Option is Alt" had
            // no effect at all: what arrived was a character, and a character
            // cannot be a modifier. Asking `ghostty_surface_key_translation_mods`
            // strips Option from the set used for composition — the same call
            // Ghostty's own macOS app makes at the same point — so the text
            // comes out `s`, while the key event still carries Option and the
            // core encodes it as `ESC s`.
            let forComposition = translationEvent(for: event, surface: surface)
            // **Shape, not content.** The host writes these into a log a user
            // can send us, so a line may say which key and which modifiers —
            // and never what was typed. `sameText` is the diagnostic that
            // matters anyway: when composition ran with Option taken out, the
            // text it produces DIFFERS from what the key would otherwise have
            // typed, and that difference is the whole mechanism.
            TerminalDebugLog.log(
                .input,
                "keyDown code=\(event.keyCode)"
                    + " mods=\(Self.describe(event.modifierFlags))"
                    + " translateWith=\(Self.describe(forComposition.modifierFlags))"
                    + " sameText=\(event.characters == forComposition.characters)"
            )
            view.interpretKeyEvents([forComposition])

            if inputMethodHandler?.consumeHandledTextCommand() == true {
                return
            }

            if let collected = inputMethodHandler?.finishCollectingText() {
                TerminalDebugLog.log(
                    .input,
                    "keyDown sending pieces=\(collected.count)"
                        + " bytes=\(collected.joined().utf8.count)"
                )
                var input = event.buildKeyInput(
                    action: action, translationMods: forComposition.modifierFlags
                )
                for text in collected {
                    text.withCString { ptr in
                        input.text = ptr
                        surface.sendKeyEvent(input)
                    }
                }
                return
            }

            guard inputMethodHandler?.hasMarkedText != true else { return }

            // If we had marked text before but don't now, the key event
            // (e.g. Delete) was used to clear the composition. Don't
            // forward it to ghostty as a real terminal input.
            if hadMarkedText { return }

            sendKeyEvent(
                for: event, action: action, to: surface, includeText: true,
                translationMods: forComposition.modifierFlags
            )
        }

        func handleTextCommand(_ selector: Selector) {
            inputMethodHandler?.handleCommand(selector)
        }

        /// Modifier flags as four letters, for the log.
        private static func describe(_ flags: NSEvent.ModifierFlags) -> String {
            var out = ""
            if flags.contains(.shift) { out += "S" }
            if flags.contains(.control) { out += "C" }
            if flags.contains(.option) { out += "O" }
            if flags.contains(.command) { out += "M" }
            return out.isEmpty ? "-" : out
        }

        /// The event to run composition on: `event` with any modifier the
        /// engine excludes from translation taken off.
        ///
        /// **Reuses the original event when nothing changes**, deliberately.
        /// AppKit's input method appears to hold identity somewhere — Ghostty's
        /// own comment says Korean input breaks without this — so a rebuilt
        /// event is only ever used when it has to be.
        private func translationEvent(for event: NSEvent, surface: TerminalSurface) -> NSEvent {
            guard let raw = surface.rawValue else { return event }
            let wanted = TerminalInputModifiers(
                rawValue: ghostty_surface_key_translation_mods(
                    raw, TerminalInputModifiers(from: event.modifierFlags).ghosttyMods
                ).rawValue
            )
            // The event carries hidden bits that some dead keys depend on, so
            // the flags are edited rather than rebuilt from scratch — again as
            // the reference implementation does.
            var mods = event.modifierFlags
            for (flag, mod) in [
                (NSEvent.ModifierFlags.shift, TerminalInputModifiers.shift),
                (.control, .ctrl),
                (.option, .alt),
                (.command, .super_),
            ] {
                if wanted.contains(mod) { mods.insert(flag) } else { mods.remove(flag) }
            }
            guard mods != event.modifierFlags else { return event }
            return NSEvent.keyEvent(
                with: event.type,
                location: event.locationInWindow,
                modifierFlags: mods,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: event.characters(byApplyingModifiers: mods) ?? "",
                charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            ) ?? event
        }

        func handleKeyUp(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }
            if shouldBypassGhosttyForDirectInput(event) {
                return
            }
            var input = event.buildKeyInput(action: GHOSTTY_ACTION_RELEASE)
            input.text = nil
            surface.sendKeyEvent(input)
        }

        func handleFlagsChanged(with event: NSEvent) {
            guard let view, let surface = view.surface else { return }

            let action: ghostty_input_action_e = isModifierPress(event)
                ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE

            var input = event.buildKeyInput(action: action)
            input.text = nil
            surface.sendKeyEvent(input)
        }

        private func isModifierPress(_ event: NSEvent) -> Bool {
            let flags = event.modifierFlags
            switch event.keyCode {
            case 56, 60: return flags.contains(.shift)
            case 58, 61: return flags.contains(.option)
            case 59, 62: return flags.contains(.control)
            case 55, 54: return flags.contains(.command)
            case 57: return flags.contains(.capsLock)
            default: return false
            }
        }

        private func sendKeyEvent(
            for event: NSEvent,
            action: ghostty_input_action_e,
            to surface: TerminalSurface,
            includeText: Bool,
            translationMods: NSEvent.ModifierFlags? = nil
        ) {
            var input = event.buildKeyInput(action: action, translationMods: translationMods)
            // Only include text for printable characters (>= 0x20).
            // Control characters (e.g. \u{19} for Shift+Tab) must NOT be sent
            // as text — ghostty needs to translate the keycode+mods itself
            // (e.g. Tab+Shift → ESC[Z).
            // **The characters composition would produce**, which is not what
            // the held modifiers produce once Option has been taken out of the
            // translation: `s`, not `ß`.
            guard includeText,
                  let chars = event.filteredCharacters(applying: translationMods),
                  !chars.isEmpty,
                  let firstByte = chars.utf8.first, firstByte >= 0x20
            else {
                surface.sendKeyEvent(input)
                return
            }

            chars.withCString { ptr in
                input.text = ptr
                surface.sendKeyEvent(input)
            }
        }

        private func handleDirectInputIfNeeded(_ event: NSEvent) -> Bool {
            guard let view else { return false }
            // During IME composition, AppKit needs to keep ownership of editing
            // commands so marked text can shrink, cancel, and move correctly.
            guard inputMethodHandler?.hasMarkedText != true else { return false }
            guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else {
                return false
            }
            let delivery = TerminalHardwareKeyRouter.routeAppKit(
                keyCode: event.keyCode,
                backend: view.configuration.backend
            )
            guard case let .data(sequence) = delivery else { return false }
            guard case let .inMemory(session) = view.configuration.backend else { return false }

            session.sendInput(sequence)
            return true
        }

        private func shouldBypassGhosttyForDirectInput(_ event: NSEvent) -> Bool {
            guard let view else { return false }
            return TerminalHardwareKeyRouter.routeAppKit(
                keyCode: event.keyCode,
                backend: view.configuration.backend
            ).isDirectInput
        }
    }

    // MARK: - NSEvent Terminal Input Helpers

    extension NSEvent {
        /// - Parameter translationMods: the modifiers COMPOSITION ran with, when
        ///   they differ from the ones held. See `consumed_mods` below.
        func buildKeyInput(
            action: ghostty_input_action_e,
            translationMods: NSEvent.ModifierFlags? = nil
        ) -> ghostty_input_key_s {
            var input = ghostty_input_key_s()
            input.action = action
            // Use raw AppKit keyCode directly — the Ghostty C API expects
            // platform-native keyCodes, not ghostty_input_key_e enum values.
            input.keycode = UInt32(keyCode)
            input.composing = false
            input.text = nil

            let mods = TerminalInputModifiers(from: modifierFlags)
            input.mods = mods.ghosttyMods

            // **Consumed modifiers: the ones TEXT GENERATION used up**, so the
            // core knows which are left to encode with. macOS offers no way to
            // ask, so the heuristic is the reference implementation's: control
            // and command never contribute to text, assume everything else did.
            //
            // "Everything else" is measured against the modifiers COMPOSITION
            // RAN WITH, not the ones held. They are the same key press until
            // `macos-option-as-alt` takes Option out of the translation — and
            // then they are the whole difference between the two behaviours.
            // Reading the held modifiers here reported Option as consumed even
            // when composition had been told to ignore it, so the core saw
            // "text `s`, and the Option is already accounted for" and sent a
            // bare `s`. Option as Alt did strip the character; nothing encoded
            // the Alt, which is why ⌥s stopped typing `ß` and never became
            // `ESC s`.
            let consumed = (translationMods ?? modifierFlags).subtracting([.control, .command])
            input.consumed_mods = TerminalInputModifiers(from: consumed).ghosttyMods

            if type == .keyDown || type == .keyUp,
               let chars = characters(byApplyingModifiers: []),
               let codepoint = chars.unicodeScalars.first
            {
                input.unshifted_codepoint = codepoint.value
            }

            return input
        }

        var filteredCharacters: String? { filteredCharacters(applying: nil) }

        /// - Parameter mods: the modifiers to read the characters under, when
        ///   they are not the ones held. Composition may have been told to
        ///   ignore Option — this is the same text it was told to produce.
        func filteredCharacters(applying mods: NSEvent.ModifierFlags?) -> String? {
            let characters = mods.map { characters(byApplyingModifiers: $0) ?? "" } ?? characters
            guard let characters else { return nil }
            guard characters.count == 1,
                  let scalar = characters.unicodeScalars.first
            else {
                return characters
            }

            // macOS encodes function keys as Private Use Area scalars —
            // these have no printable representation.
            if TerminalInputText.isPrivateUseFunctionKey(scalar) {
                return nil
            }

            // When the control modifier produces a raw control character,
            // re-derive printable text without the control modifier so
            // Ghostty can map the physical key correctly.
            if scalar.isASCIIControl {
                var flags = modifierFlags
                flags.remove(.control)
                return self.characters(byApplyingModifiers: flags)
            }

            return characters
        }
    }

    extension UnicodeScalar {
        var isASCIIControl: Bool {
            value < 0x20
        }
    }
#endif

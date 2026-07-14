//
//  TerminalSessionBackend.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

public enum TerminalSessionBackend: Sendable {
    /// Ghostty owns the PTY and fork+execs its globally-configured shell.
    case exec
    /// Ghostty owns the PTY and fork+execs a specific command (with optional
    /// environment overrides) instead of the configured shell — e.g. running
    /// `zmx attach <session>` directly so ghostty's native exec path drives a
    /// persisted session, no host-side byte bridge. The command is set on the
    /// surface config's `command` field and `env` on `env_vars`.
    case execCommand(command: String, env: [String: String])
    case inMemory(InMemoryTerminalSession)

    func isEquivalent(to other: TerminalSessionBackend) -> Bool {
        switch (self, other) {
        case (.exec, .exec):
            true
        case let (.execCommand(lc, le), .execCommand(rc, re)):
            lc == rc && le == re
        case let (.inMemory(lhs), .inMemory(rhs)):
            lhs === rhs
        default:
            false
        }
    }
}

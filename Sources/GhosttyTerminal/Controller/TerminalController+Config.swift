//
//  TerminalController+Config.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

extension TerminalController {
    @discardableResult
    public func updateConfigSource(_ source: ConfigSource) -> Bool {
        guard source != configSource else { return true }

        let prepared: PreparedConfig
        switch Self.prepareConfig(source: source) {
        case let .success(value):
            prepared = value

        case let .failure(issue):
            lastConfigurationIssue = issue.description
            Self.reportConfigurationIssue(issue.description)
            return false
        }

        let previousConfig = config
        let previousManagedConfigURL = managedConfigURL
        let nextConfig = prepared.rawValue

        if let app {
            ghostty_app_update_config(app, nextConfig)
        }

        for bridge in retainedBridges {
            guard let surface = bridge.rawSurface else { continue }
            ghostty_surface_update_config(surface, nextConfig)
            // Theme / palette / background changes don't dirty the cell
            // grid the way text writes do — ghostty accepts the new
            // config but its Metal renderer can sit on the previously
            // submitted frame until the next external draw request,
            // making live config updates look like they "didn't apply"
            // (you have to scroll or type for the colors to flip).
            // Forcing a refresh per surface schedules a redraw with the
            // new config immediately. Cheap (single CADisplayLink-style
            // tick), and it's the same call sites use after any other
            // config change anyway.
            ghostty_surface_refresh(surface)
        }

        applyPreparedConfig(prepared, source: source)

        if let previousConfig {
            ghostty_config_free(previousConfig)
        }

        if let previousManagedConfigURL, previousManagedConfigURL != managedConfigURL {
            try? FileManager.default.removeItem(at: previousManagedConfigURL)
        }

        return true
    }

    func applyInitialConfig(source: ConfigSource) {
        switch Self.prepareConfig(source: source) {
        case let .success(prepared):
            applyPreparedConfig(prepared, source: source)

        case let .failure(issue):
            lastConfigurationIssue = issue.description
            Self.reportConfigurationIssue(issue.description)

            guard source != .none else { return }
            guard case let .success(fallback) = Self.prepareConfig(source: ConfigSource.none) else {
                return
            }
            applyPreparedConfig(fallback, source: .none)
        }
    }

    func createApp() {
        guard let cfg = config else { return }

        let userdata = Unmanaged.passUnretained(self).toOpaque()

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = userdata
        runtimeConfig.supports_selection_clipboard = false
        runtimeConfig.wakeup_cb = terminalControllerWakeupCallback
        runtimeConfig.action_cb = terminalControllerActionCallback
        runtimeConfig.close_surface_cb = terminalControllerCloseSurfaceCallback
        runtimeConfig.write_clipboard_cb = terminalControllerWriteClipboardCallback
        runtimeConfig.read_clipboard_cb = terminalControllerReadClipboardCallback

        app = ghostty_app_new(&runtimeConfig, cfg)
    }

    private static func prepareConfig(
        source: ConfigSource
    ) -> Result<PreparedConfig, ConfigurationIssue> {
        let resolvedContents: String
        let configPath: String
        let managedConfigURL: URL?

        switch source {
        case .none:
            resolvedContents = defaultRenderedConfig
            switch writeManagedConfig(contents: resolvedContents) {
            case let .success(url):
                managedConfigURL = url
                configPath = url.path
            case let .failure(issue):
                return .failure(issue)
            }

        case let .generated(contents):
            resolvedContents = contents
            switch writeManagedConfig(contents: contents) {
            case let .success(url):
                managedConfigURL = url
                configPath = url.path
            case let .failure(issue):
                return .failure(issue)
            }

        case let .file(path):
            do {
                resolvedContents = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                return .failure(ConfigurationIssue("failed to load ghostty config template: \(error)"))
            }
            managedConfigURL = nil
            configPath = path
        }

        guard let rawValue = ghostty_config_new() else {
            if let managedConfigURL {
                try? FileManager.default.removeItem(at: managedConfigURL)
            }
            return .failure(ConfigurationIssue("ghostty_config_new returned nil"))
        }

        ghostty_config_load_file(rawValue, configPath)
        ghostty_config_finalize(rawValue)

        let diagnostics = configDiagnostics(from: rawValue)
        guard diagnostics.isEmpty else {
            ghostty_config_free(rawValue)
            if let managedConfigURL {
                try? FileManager.default.removeItem(at: managedConfigURL)
            }
            return .failure(
                ConfigurationIssue("ghostty config diagnostics: \(diagnostics.joined(separator: " | "))")
            )
        }

        return .success(
            PreparedConfig(
                rawValue: rawValue,
                managedConfigURL: managedConfigURL,
                renderedContents: resolvedContents
            )
        )
    }

    private static func writeManagedConfig(contents: String) -> Result<URL, ConfigurationIssue> {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ghostty-config-\(UUID().uuidString)")
            .appendingPathExtension("conf")

        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
            return .success(url)
        } catch {
            return .failure(ConfigurationIssue("failed to write generated ghostty config: \(error)"))
        }
    }

    private static func configDiagnostics(from config: ghostty_config_t) -> [String] {
        let count = ghostty_config_diagnostics_count(config)
        guard count > 0 else { return [] }

        return (0 ..< count).compactMap { index in
            let diagnostic = ghostty_config_get_diagnostic(config, index)
            guard let message = diagnostic.message else { return nil }
            return String(cString: message)
        }
    }

    private static func reportConfigurationIssue(_ message: String) {
        NSLog("GhosttyTerminal configuration issue: %@", message)
    }

    private func applyPreparedConfig(_ prepared: PreparedConfig, source: ConfigSource) {
        config = prepared.rawValue
        managedConfigURL = prepared.managedConfigURL
        renderedConfigContents = prepared.renderedContents
        configSource = source
        lastConfigurationIssue = nil
    }
}

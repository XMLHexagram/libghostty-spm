//
//  TerminalController+Surface.swift
//  libghostty-spm
//

import Foundation
import GhosttyKit

extension TerminalController {
    /// Creates a new Ghostty surface with the given configuration.
    ///
    /// The `platformSetup` closure lets the caller fill in
    /// platform-specific fields (`platform_tag`, `platform`, `scale_factor`)
    /// on the raw surface config struct before the surface is created.
    func createSurface(
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        guard let app else { return nil }

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.userdata = Unmanaged.passUnretained(bridge).toOpaque()
        surfaceConfig.context = configuration.context.ghosttyValue
        configureBackend(&surfaceConfig, from: configuration)

        if let fontSize = configuration.fontSize {
            surfaceConfig.font_size = fontSize
        }

        return finalizeSurface(
            app: app,
            bridge: bridge,
            configuration: configuration,
            config: &surfaceConfig,
            workingDirectory: configuration.workingDirectory,
            platformSetup: platformSetup
        )
    }

    func retain(_ bridge: TerminalCallbackBridge) {
        retainedBridges.append(bridge)
    }

    func remove(_ bridge: TerminalCallbackBridge) {
        retainedBridges.removeAll { $0 === bridge }
    }

    var retainedBridgeCount: Int {
        retainedBridges.count
    }

    private func configureBackend(
        _ config: inout ghostty_surface_config_s,
        from options: TerminalSurfaceOptions
    ) {
        guard case let .inMemory(session) = options.backend else {
            config.backend = GHOSTTY_SURFACE_IO_BACKEND_EXEC
            return
        }

        config.backend = GHOSTTY_SURFACE_IO_BACKEND_HOST_MANAGED
        config.receive_userdata = Unmanaged.passUnretained(session).toOpaque()
        config.receive_buffer = InMemoryTerminalSession.receiveBufferCallback
        config.receive_resize = InMemoryTerminalSession.receiveResizeCallback
    }

    private func finalizeSurface(
        app: ghostty_app_t,
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        config: inout ghostty_surface_config_s,
        workingDirectory: String?,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        guard let workingDirectory else {
            return buildSurface(
                app: app,
                bridge: bridge,
                configuration: configuration,
                config: &config,
                platformSetup: platformSetup
            )
        }

        return workingDirectory.withCString { ptr in
            config.working_directory = ptr
            return buildSurface(
                app: app,
                bridge: bridge,
                configuration: configuration,
                config: &config,
                platformSetup: platformSetup
            )
        }
    }

    private func buildSurface(
        app: ghostty_app_t,
        bridge: TerminalCallbackBridge,
        configuration: TerminalSurfaceOptions,
        config: inout ghostty_surface_config_s,
        platformSetup: (inout ghostty_surface_config_s) -> Void
    ) -> ghostty_surface_t? {
        platformSetup(&config)

        // `.execCommand`: fill the surface config's `command` + `env_vars` with
        // C strings that must stay valid across `ghostty_surface_new` (ghostty
        // copies them internally, exactly like `working_directory`). We own the
        // allocations and free them the instant the call returns.
        var cCommand: UnsafeMutablePointer<CChar>?
        var cEnv: UnsafeMutablePointer<ghostty_env_var_s>?
        var cEnvStrings: [UnsafeMutablePointer<CChar>] = []
        if case let .execCommand(command, env) = configuration.backend {
            if let dup = strdup(command) {
                cCommand = dup
                config.command = UnsafePointer(dup)
            }
            if !env.isEmpty {
                let buf = UnsafeMutablePointer<ghostty_env_var_s>.allocate(capacity: env.count)
                var count = 0
                for (key, value) in env {
                    guard let k = strdup(key), let v = strdup(value) else { continue }
                    cEnvStrings.append(k)
                    cEnvStrings.append(v)
                    buf[count] = ghostty_env_var_s(key: UnsafePointer(k), value: UnsafePointer(v))
                    count += 1
                }
                cEnv = buf
                config.env_vars = buf
                config.env_var_count = count
            }
        }
        defer {
            if let cCommand { free(cCommand) }
            for s in cEnvStrings { free(s) }
            cEnv?.deallocate()
        }

        guard let surface = ghostty_surface_new(app, &config) else {
            return nil
        }

        retain(bridge)

        if case let .inMemory(session) = configuration.backend {
            session.setSurface(surface)
        }

        return surface
    }
}

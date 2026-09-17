import Foundation

/// How Herd launches and addresses its own herdr session.
struct HerdrSession {
    /// Herd's named session, separate from a plain `herdr` in any terminal.
    static let name = "herd"

    let herdrPath: String
    let configPath: String
    let socketPath: String

    static func make() -> HerdrSession? {
        guard let herdr = locateHerdr() else { return nil }
        let support = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Herd", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let config = support.appendingPathComponent("herdr-config.toml").path
        return HerdrSession(
            herdrPath: herdr,
            configPath: config,
            socketPath: HerdrClient.socketPath(session: name)
        )
    }

    /// herdr always draws one tab row at the top; Herd clips it and shows
    /// native tabs instead.
    static let hiddenTopRows = 1

    /// Shell command libghostty runs for the terminal surface.
    var command: String {
        "\(shellQuote(herdrPath)) --session \(Self.name)"
    }

    var environment: [String: String] {
        var env = [
            "HERDR_CONFIG_PATH": configPath,
            "TERM": "xterm-256color",
            "COLORTERM": "truecolor",
            "TERM_PROGRAM": "Herd",
        ]
        if let cli = Bundle.main.url(forAuxiliaryExecutable: "herd-cli")?.path {
            env["HERD_CLI"] = cli
        }
        return env
    }

    var client: HerdrClient { HerdrClient(socketPath: socketPath) }

    static func locateHerdr() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            home + "/.local/bin/herdr",
            "/opt/homebrew/bin/herdr",
            "/usr/local/bin/herdr",
            home + "/.cargo/bin/herdr",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

func shellQuote(_ value: String) -> String {
    if value.range(of: "^[A-Za-z0-9_@%+=:,./-]+$", options: .regularExpression) != nil {
        return value
    }
    return "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
}

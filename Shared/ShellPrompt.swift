import Foundation

/// Whether a pane is sitting at its shell's prompt, which is the only time
/// Herd takes the keyboard to edit the command line itself. The moment any
/// program runs — an agent, an editor, a pager — typing goes straight
/// through, so nothing can be trapped behind Herd's editor.
enum ShellPrompt {
    /// Shells Herd recognises; anything else running is a program.
    static let shells: Set<String> = [
        "zsh", "bash", "sh", "fish", "dash", "ksh", "tcsh", "csh", "nu", "xonsh", "elvish", "-zsh", "-bash", "-fish",
    ]

    /// What `pane.process_info` reports, trimmed to what matters here.
    struct ProcessInfo: Equatable {
        var shellPid: Int?
        /// name and pid of each foreground process.
        var foreground: [(name: String, pid: Int)]

        static func == (lhs: ProcessInfo, rhs: ProcessInfo) -> Bool {
            lhs.shellPid == rhs.shellPid
                && lhs.foreground.map(\.pid) == rhs.foreground.map(\.pid)
                && lhs.foreground.map(\.name) == rhs.foreground.map(\.name)
        }
    }

    static func parse(_ result: [String: Any]) -> ProcessInfo? {
        guard let info = result["process_info"] as? [String: Any] else { return nil }
        let processes = (info["foreground_processes"] as? [[String: Any]] ?? []).compactMap { raw -> (String, Int)? in
            guard let name = raw["name"] as? String, let pid = raw["pid"] as? Int else { return nil }
            return (name, pid)
        }
        return ProcessInfo(shellPid: info["shell_pid"] as? Int, foreground: processes)
    }

    /// True when the only thing in the foreground is the pane's own shell.
    static func isAtPrompt(_ info: ProcessInfo?) -> Bool {
        guard let info, !info.foreground.isEmpty else { return false }
        return info.foreground.allSatisfy { process in
            let name = process.name.hasPrefix("-") ? String(process.name.dropFirst()) : process.name
            let isShell = shells.contains(name) || shells.contains(process.name)
            return isShell && (info.shellPid == nil || process.pid == info.shellPid)
        }
    }

    /// The shell's own name, for history and quoting decisions.
    static func shellName(_ info: ProcessInfo?) -> String? {
        guard let name = info?.foreground.first?.name else { return nil }
        return name.hasPrefix("-") ? String(name.dropFirst()) : name
    }
}

import Foundation

/// Reads the checked-out branch for a directory from `.git/HEAD` without
/// spawning git. Worktree `.git` files are followed to their gitdir.
enum GitBranch {
    static func current(in directory: String) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default
        while url.path != "/" {
            let dotGit = url.appendingPathComponent(".git")
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) {
                let gitDir: URL
                if isDirectory.boolValue {
                    gitDir = dotGit
                } else if let contents = try? String(contentsOf: dotGit, encoding: .utf8),
                          let line = contents.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") }) {
                    let raw = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
                    gitDir = raw.hasPrefix("/")
                        ? URL(fileURLWithPath: raw)
                        : url.appendingPathComponent(raw)
                } else {
                    return nil
                }
                return branch(fromHead: try? String(contentsOf: gitDir.appendingPathComponent("HEAD"), encoding: .utf8))
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    static func branch(fromHead head: String?) -> String? {
        guard let head = head?.trimmingCharacters(in: .whitespacesAndNewlines), !head.isEmpty else { return nil }
        let prefix = "ref: refs/heads/"
        if head.hasPrefix(prefix) { return String(head.dropFirst(prefix.count)) }
        return String(head.prefix(7))
    }
}

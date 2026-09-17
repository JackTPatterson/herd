import Foundation

/// Resolves the project a working directory belongs to, for grouping
/// workspaces by project in the sidebar.
///
/// A project is the nearest enclosing git repository. Linked worktrees
/// (`.git` is a file pointing into `<main>/.git/worktrees/<name>`) resolve to
/// their main repository, so every worktree of one repo lands in one group.
/// The home directory and `/` never count as projects, which keeps a
/// dotfiles repo at `~` from swallowing every workspace. Outside a git
/// repository, a directory under one of `projectParentDirectories` (for
/// example `~/Developer`) resolves to that parent's direct child.
enum ProjectRootResolver {
    /// Returns the project root for `directory`, or `nil` when the directory
    /// belongs to no project.
    static func projectRoot(
        forDirectory directory: String,
        projectParentDirectories: [String] = [],
        homeDirectory: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> String? {
        projectRoot(
            forDirectory: directory,
            projectParentDirectories: projectParentDirectories,
            homeDirectory: homeDirectory,
            gitEntryKind: { path in
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return nil }
                return isDirectory.boolValue ? .directory : .file
            },
            readFile: { path in try? String(contentsOfFile: path, encoding: .utf8) }
        )
    }

    /// The kind of `.git` entry found in a directory.
    enum GitEntryKind: Sendable {
        case directory
        case file
    }

    /// File-system-injectable variant used by tests.
    static func projectRoot(
        forDirectory directory: String,
        projectParentDirectories: [String] = [],
        homeDirectory: String,
        gitEntryKind: (String) -> GitEntryKind?,
        readFile: (String) -> String?
    ) -> String? {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let home = normalized(homeDirectory)
        let start = normalized(trimmed)
        if let gitRoot = gitRepositoryRoot(for: start, gitEntryKind: gitEntryKind, readFile: readFile),
           gitRoot != home, gitRoot != "/" {
            return gitRoot
        }
        return parentDirectoryChild(for: start, parents: projectParentDirectories, home: home)
    }

    private static func gitRepositoryRoot(
        for directory: String,
        gitEntryKind: (String) -> GitEntryKind?,
        readFile: (String) -> String?
    ) -> String? {
        var url = URL(fileURLWithPath: directory, isDirectory: true)
        while url.path != "/" && !url.path.isEmpty {
            let gitPath = url.appendingPathComponent(".git").path
            if let kind = gitEntryKind(gitPath) {
                if kind == .file,
                   let contents = readFile(gitPath),
                   let mainRoot = mainRepositoryRoot(gitFileContents: contents, relativeTo: url) {
                    return normalized(mainRoot)
                }
                return normalized(url.path)
            }
            url.deleteLastPathComponent()
        }
        return nil
    }

    /// `~/Developer/app/src` → `~/Developer/app` when `~/Developer` is a
    /// project parent. The parent itself is not a project.
    private static func parentDirectoryChild(for directory: String, parents: [String], home: String) -> String? {
        let candidates = parents
            .map { expandingTilde($0, home: home) }
            .filter { $0.hasPrefix("/") && $0 != "/" && $0 != home }
            .sorted { $0.count > $1.count }
        for parent in candidates where directory.hasPrefix(parent + "/") {
            let remainder = directory.dropFirst(parent.count + 1)
            guard let child = remainder.split(separator: "/").first else { continue }
            return parent + "/" + child
        }
        return nil
    }

    private static func expandingTilde(_ path: String, home: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "~" { return home }
        if trimmed.hasPrefix("~/") { return normalized(home + trimmed.dropFirst()) }
        return trimmed.hasPrefix("/") ? normalized(trimmed) : trimmed
    }

    /// Parses a worktree `.git` file (`gitdir: <path>`) and returns the main
    /// repository root when the gitdir lives under `<main>/.git/worktrees/`.
    /// Submodules (`.git/modules/`) stay their own project.
    static func mainRepositoryRoot(gitFileContents: String, relativeTo directory: URL) -> String? {
        let prefix = "gitdir:"
        guard let line = gitFileContents
            .split(whereSeparator: \.isNewline)
            .first(where: { $0.hasPrefix(prefix) }) else { return nil }
        let rawPath = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
        guard !rawPath.isEmpty else { return nil }
        let gitDir = rawPath.hasPrefix("/")
            ? URL(fileURLWithPath: rawPath).standardizedFileURL.path
            : directory.appendingPathComponent(rawPath).standardizedFileURL.path
        guard let range = gitDir.range(of: "/.git/worktrees/") else { return nil }
        let mainRoot = String(gitDir[..<range.lowerBound])
        return mainRoot.isEmpty ? nil : mainRoot
    }

    private static func normalized(_ path: String) -> String {
        let standardized = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
        guard standardized.count > 1, standardized.hasSuffix("/") else { return standardized }
        return String(standardized.dropLast())
    }
}

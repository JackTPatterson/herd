import Foundation

// herd-cli: helpers that run inside herdr panes.
//
//   herd-cli hook claude             Claude Code PreToolUse hook (stdin JSON)
//   herd-cli agent-watch …           live subagent transcript viewer
//   herd-cli install-claude-hook     add the hook to ~/.claude/settings.json
//   herd-cli uninstall-claude-hook   remove it

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())
let environment = ProcessInfo.processInfo.environment

func option(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else { return nil }
    return args[index + 1]
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

var executablePath: String {
    URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().path
}

switch arguments.first {
case "hook":
    guard arguments.dropFirst().first == "claude" else { fail("usage: herd-cli hook claude") }
    let input = FileHandle.standardInput.readDataToEndOfFile()
    SubagentHook.handleClaudePreToolUse(
        payload: input,
        environment: environment,
        cliPath: executablePath
    )
    exit(0)

case "agent-watch":
    let args = Array(arguments.dropFirst())
    guard let directory = option("--dir", in: args) else {
        fail("usage: herd-cli agent-watch --dir <session>/subagents [--tool-use-id <id>] [--description <text>] [--title <text>]")
    }
    SubagentWatch.run(
        directory: directory,
        toolUseId: option("--tool-use-id", in: args),
        description: option("--description", in: args),
        since: option("--since", in: args).flatMap(TimeInterval.init) ?? 0,
        title: option("--title", in: args) ?? "Subagent",
        environment: environment
    )

case "install-claude-hook":
    do {
        let changed = try ClaudeHookInstaller.install(cliPath: executablePath)
        print(changed ? "Installed Herd subagent hook in ~/.claude/settings.json" : "Herd subagent hook already installed")
    } catch {
        fail("install failed: \(error)")
    }

case "uninstall-claude-hook":
    do {
        let changed = try ClaudeHookInstaller.uninstall()
        print(changed ? "Removed Herd subagent hook" : "Herd subagent hook was not installed")
    } catch {
        fail("uninstall failed: \(error)")
    }

default:
    fail("usage: herd-cli <hook claude|agent-watch|install-claude-hook|uninstall-claude-hook>")
}

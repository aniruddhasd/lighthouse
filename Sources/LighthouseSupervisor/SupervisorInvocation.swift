import Foundation

/// Where everything the supervisor process touches lives. All absolute.
public struct SupervisorPaths: Sendable, Equatable {
    public let claude: URL
    public let mcpServer: URL
    /// An empty, owner-only directory the app creates: the process's cwd, so no repo
    /// `.mcp.json` or `CLAUDE.md` can reach it (spike §10, run D).
    public let workDirectory: URL
    /// The app's config directory, handed to the MCP server so it reads the app's state.
    public let lighthouseDirectory: URL
    public let home: String
    /// The login name. The CLI finds the user's stored login by it: without `USER` a
    /// scrubbed environment reads as "Not logged in" (observed 2026-10-26).
    public let user: String
    public let path: String

    public init(
        claude: URL, mcpServer: URL, workDirectory: URL, lighthouseDirectory: URL,
        home: String, user: String, path: String
    ) {
        self.claude = claude
        self.mcpServer = mcpServer
        self.workDirectory = workDirectory
        self.lighthouseDirectory = lighthouseDirectory
        self.home = home
        self.user = user
        self.path = path
    }

    public var mcpConfig: URL { workDirectory.appendingPathComponent("mcp-config.json") }

    public func replacingClaude(_ url: URL) -> SupervisorPaths {
        SupervisorPaths(
            claude: url, mcpServer: mcpServer, workDirectory: workDirectory,
            lighthouseDirectory: lighthouseDirectory, home: home, user: user, path: path)
    }
}

/// A fully specified process launch. Plain data, so the exact flags are testable
/// without spawning anything.
public struct SupervisorInvocation: Sendable, Equatable {
    public struct SupportFile: Sendable, Equatable {
        public let url: URL
        public let contents: Data
    }
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectory: URL
    /// The user turn, fed on stdin so agent-adjacent text never appears in `ps`.
    public let stdin: String
    /// Files the runner must write (owner-only) before launching.
    public let supportFiles: [SupportFile]
}

public enum SupervisorInvocationBuilder {
    /// The MCP server's name in the generated config; tool names are `mcp__<it>__<tool>`.
    public static let mcpServerName = "lighthouse"

    public static func allowedTools() -> [String] {
        MCPServer.toolNames.map { "mcp__\(mcpServerName)__\($0)" }
    }

    /// The ONE place the supervisor's flags are spelled. Whatever is not listed here is
    /// not passed — in particular never a permission-bypass flag, `--bare`, or `--add-dir`.
    public static func build(
        settings: SupervisorSettings, paths: SupervisorPaths, turns: [PendingTurn],
        trigger: WakeTrigger, ledger: [RunRecord], now: Date
    ) -> SupervisorInvocation {
        // The environment is built from nothing: the app's own environment (which may
        // hold credentials) is not passed through.
        var env = [
            "HOME": paths.home,
            "USER": paths.user,
            "PATH": paths.path,
            "LIGHTHOUSE_CONFIG_DIR": paths.lighthouseDirectory.path,
        ]
        if let dir = settings.configDirectory { env["CLAUDE_CONFIG_DIR"] = dir }

        let args = [
            "-p",
            "--model", settings.model,
            "--effort", settings.effort,
            // No built-in tool at all (Bash included) …
            "--tools", "",
            // … only our MCP server, and only its tools, allowed to run unattended.
            "--strict-mcp-config", "--mcp-config", paths.mcpConfig.path,
            "--allowedTools", allowedTools().joined(separator: ","),
            // Replace (not append to) the default coding prompt.
            "--system-prompt", SupervisorPrompt.system,
            // Do not load the user's own settings or CLAUDE.md into the supervisor
            // (`--system-prompt` alone does not stop that; observed 2026-10-26).
            "--setting-sources", "project",
            "--no-session-persistence",
            "--output-format", "json",
            "--max-budget-usd", String(format: "%.2f", settings.maxBudgetPerRunUSD),
        ]

        return SupervisorInvocation(
            executable: paths.claude, arguments: args, environment: env,
            currentDirectory: paths.workDirectory,
            stdin: SupervisorPrompt.user(
                instructions: settings.instructions, turns: turns, trigger: trigger,
                ledger: ledger, now: now),
            supportFiles: [.init(url: paths.mcpConfig, contents: mcpConfigData(paths))])
    }

    static func mcpConfigData(_ paths: SupervisorPaths) -> Data {
        let config: [String: Any] = ["mcpServers": [mcpServerName: [
            "command": paths.mcpServer.path,
            "args": [String](),
            "env": ["LIGHTHOUSE_CONFIG_DIR": paths.lighthouseDirectory.path],
        ]]]
        // Serializing a fixed dictionary of strings cannot fail.
        return (try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted])) ?? Data()
    }
}

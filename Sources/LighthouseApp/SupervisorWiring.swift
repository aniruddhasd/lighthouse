import Foundation
import LighthouseSupervisor

/// Builds the app's `SupervisorRunner` from the real environment: the app's own state
/// directory, the MCP server that ships beside the app binary, and a `claude` found
/// without the user's shell function. Everything with logic lives in `LighthouseSupervisor`.
enum SupervisorWiring {
    static let mcpServerName = "lighthouse-supervisor-mcp"

    /// The MCP server next to the running executable: `Contents/MacOS` in the bundle, and
    /// the build directory under `swift run` (both products are built there).
    static func mcpServerURL(executable: URL? = Bundle.main.executableURL) -> URL {
        (executable?.deletingLastPathComponent() ?? URL(fileURLWithPath: "/nonexistent"))
            .appendingPathComponent(mcpServerName)
    }

    @MainActor
    static func makeRunner(directory: URL) -> SupervisorRunner {
        let home = NSHomeDirectory()
        let user = NSUserName()
        let process = FoundationProcessRunner()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let resolver: @Sendable (String?) async -> Result<ClaudeLocation, ClaudeNotFound> = { override in
            await ClaudeLocator.locate(
                override: override, home: home,
                isExecutable: { FileManager.default.isExecutableFile(atPath: $0) },
                shellProbe: {
                    await LoginShellProbe(process: process, shell: shell, home: home, user: user).probe()
                })
        }
        let paths = SupervisorPaths(
            // Replaced by the resolver on every run; the runner refuses to run if it finds none.
            claude: URL(fileURLWithPath: "/usr/bin/false"),
            mcpServer: mcpServerURL(),
            workDirectory: directory.appendingPathComponent("supervisor-work", isDirectory: true),
            lighthouseDirectory: directory, home: home, user: user,
            path: "/usr/bin:/bin:/usr/sbin:/sbin")
        return SupervisorRunner(
            directory: directory, source: FileSnapshotSource(directory: directory),
            process: process, paths: paths, claudeResolver: resolver)
    }
}

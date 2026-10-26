import Foundation

public struct ClaudeLocation: Equatable, Sendable {
    public let url: URL
    /// Where it came from, for display: `setting`, `~/.local/bin`, `login shell`, …
    public let source: String
}

public struct ClaudeNotFound: Error, Equatable, Sendable {
    public let message: String
}

/// Finds the `claude` binary WITHOUT the user's shell function (which only exists in an
/// interactive shell, so a `Process` launch never sees it). Order: an explicit setting
/// (a wrong one is an error, never a silent fallback), the usual install locations, then
/// the user's login shell. Every path is checked executable before it is trusted.
public enum ClaudeLocator {
    public static func locate(
        override: String?, home: String,
        isExecutable: @Sendable (String) -> Bool,
        shellProbe: @Sendable () async -> String?
    ) async -> Result<ClaudeLocation, ClaudeNotFound> {
        if let setting = override?.trimmingCharacters(in: .whitespacesAndNewlines), !setting.isEmpty {
            guard setting.hasPrefix("/"), isExecutable(setting) else {
                return .failure(ClaudeNotFound(message:
                    "The Claude binary path in the settings (\(setting.prefix(120))) is not an executable file."))
            }
            return .success(ClaudeLocation(url: URL(fileURLWithPath: setting), source: "setting"))
        }
        let known: [(String, String)] = [
            ("\(home)/.local/bin/claude", "~/.local/bin"),
            ("/opt/homebrew/bin/claude", "/opt/homebrew/bin"),
            ("/usr/local/bin/claude", "/usr/local/bin"),
        ]
        for (path, label) in known where isExecutable(path) {
            return .success(ClaudeLocation(url: URL(fileURLWithPath: path), source: label))
        }
        if let path = await shellProbe(), path.hasPrefix("/"), isExecutable(path) {
            return .success(ClaudeLocation(url: URL(fileURLWithPath: path), source: "login shell"))
        }
        return .failure(ClaudeNotFound(message:
            "The Claude binary was not found in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin or your login shell. Set its path in the supervisor settings."))
    }
}

/// Asks the user's login shell where `claude` is, skipping any shell function of that
/// name (`whence -p`). Rc files can print noise, so only an absolute-path line counts.
public struct LoginShellProbe: Sendable {
    private let process: ProcessRunning
    private let shell: String
    private let home: String
    private let user: String
    private let timeout: TimeInterval

    public init(process: ProcessRunning, shell: String, home: String, user: String, timeout: TimeInterval = 10) {
        self.process = process
        self.shell = shell
        self.home = home
        self.user = user
        self.timeout = timeout
    }

    public func probe() async -> String? {
        let invocation = SupervisorInvocation(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-l", "-i", "-c", "whence -p claude 2>/dev/null || type -P claude 2>/dev/null"],
            environment: ["HOME": home, "USER": user, "SHELL": shell, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"],
            currentDirectory: URL(fileURLWithPath: home), stdin: "", supportFiles: [])
        guard let output = try? await process.run(invocation, timeout: timeout), output.exitStatus == 0 else {
            return nil
        }
        return Self.parse(String(decoding: output.stdout, as: UTF8.self))
    }

    /// The last line that is an absolute path.
    static func parse(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).map(String.init)
            .last { $0.hasPrefix("/") }
    }
}

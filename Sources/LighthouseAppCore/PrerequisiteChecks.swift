import Foundation

/// Pure, testable parts of first-run prerequisite checks. The side-effecting
/// probes (running git, the login shell, touching the container) live in the
/// app layer and lean on these for the verdict.
public enum PrerequisiteChecks {
    /// Minimum git required for `checkout --conflict=zdiff3` (spec §4).
    public static let minimumGit = (major: 2, minor: 35)
    /// macOS `sun_path` cap for a Unix socket path. 104 bytes incl. the NUL;
    /// keep the path at or under 103 usable bytes.
    public static let maxSocketPathBytes = 103

    public struct GitVersion: Sendable, Equatable {
        public let major: Int
        public let minor: Int
        public var display: String { "\(major).\(minor)" }
    }

    /// Parses the leading `X.Y` from `git --version` output
    /// ("git version 2.50.1 (Apple Git-155)" → 2.50). Returns nil if no
    /// version can be found (fail loud upstream).
    public static func parseGitVersion(_ output: String) -> GitVersion? {
        // First run of digits.digits anywhere in the string.
        var numbers: [Int] = []
        var current = ""
        for ch in output {
            if ch.isNumber {
                current.append(ch)
            } else if ch == "." && !current.isEmpty {
                numbers.append(Int(current) ?? 0)
                current = ""
                if numbers.count == 2 { break }
            } else if !current.isEmpty {
                numbers.append(Int(current) ?? 0)
                break
            }
        }
        if numbers.count < 2, !current.isEmpty { numbers.append(Int(current) ?? 0) }
        guard numbers.count >= 2 else { return nil }
        return GitVersion(major: numbers[0], minor: numbers[1])
    }

    public static func gitMeetsMinimum(_ version: GitVersion) -> Bool {
        (version.major, version.minor) >= (minimumGit.major, minimumGit.minor)
    }

    /// True if the intended socket path fits under the sun_path cap.
    public static func socketPathFits(_ path: String) -> Bool {
        path.utf8.count <= maxSocketPathBytes
    }
}

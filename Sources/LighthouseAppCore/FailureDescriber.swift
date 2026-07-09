import Foundation
import LighthouseTaskEngine

/// Turns typed engine failures into honest, complete user-facing text —
/// exact repos, exact debris. Never a generic "something went wrong".
/// Pure and unit-tested; the UI only displays the result.
public enum FailureDescriber {

    public static func describe(_ failure: TaskCreationFailure) -> String {
        var lines: [String] = []
        if let repoPath = failure.repoPath {
            lines.append("Task creation failed at \(repoPath):")
        } else {
            lines.append("Task creation failed before touching any repo:")
        }
        lines.append(describe(failure.cause))

        switch failure.rollback {
        case .notNeeded:
            lines.append("No repos were modified.")
        case .completed(let removed):
            if removed.isEmpty {
                lines.append("Nothing needed rolling back.")
            } else {
                lines.append("Rolled back cleanly — no worktrees or branches were left behind in:")
                lines.append(contentsOf: removed.map { "  • \($0.repoPath)" })
            }
        case .incomplete(let removed, let debris):
            if !removed.isEmpty {
                lines.append("Rolled back:")
                lines.append(contentsOf: removed.map { "  • \($0.repoPath)" })
            }
            lines.append("ROLLBACK INCOMPLETE — clean these up manually:")
            for item in debris {
                lines.append("  • \(item.repoPath): branch '\(item.branch)', worktree \(item.worktreePath)")
                lines.append("    (\(item.failure))")
            }
        }
        return lines.joined(separator: "\n")
    }

    public static func describe(_ error: TaskEngineError) -> String {
        switch error {
        case .invalidTaskName(let name, let reason):
            return "'\(name)' is not a usable task name (\(reason))."
        case .invalidBranchName(let branch):
            return "'\(branch)' is not a valid git branch name."
        case .repoNotFound(let path):
            return "\(path) does not exist or is not a git repository."
        case .unknownRepo(let id):
            return "A workspace references an unregistered repo (\(id))."
        case .baseBranchMissing(let repoPath, let baseBranch):
            return "Base branch '\(baseBranch)' does not exist in \(repoPath)."
        case .branchAlreadyExists(let repoPath, let branch):
            return "Branch '\(branch)' already exists in \(repoPath) — it was NOT touched."
        case .worktreeDestinationOccupied(let path):
            return "Worktree destination already exists: \(path)."
        case .duplicateWorktreeDestination(let path):
            return "Two selected repos would share the worktree path \(path)."
        case .invalidEnvCopyEntry(let entry, let reason):
            return "Env copy entry '\(entry)' is invalid: \(reason)."
        case .envCopySourceMissing(let repoPath, let entry):
            return "Env file '\(entry)' not found in \(repoPath)."
        case .setupScriptNotFound(let repoPath, let script):
            return "Setup script '\(script)' not found or not executable in \(repoPath)."
        case .setupScriptFailed(let repoPath, let script, let exitCode, let stderr):
            let detail = stderr.isEmpty ? "" : "\n\(stderr)"
            return "Setup script \(script) in \(repoPath) exited \(exitCode).\(detail)"
        case .unmergedWorkPresent(let items):
            return "Unmerged work in: "
                + items.map { "\($0.repoPath) (branch '\($0.branch)')" }.joined(separator: ", ")
        case .staleConfirmation:
            return "The confirmation no longer matches the repos' current state — review again."
        case .git(let gitError):
            return String(describing: gitError)
        }
    }
}

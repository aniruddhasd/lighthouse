import Foundation
import LighthouseTaskEngine

/// The one place a supervisor-supplied task reference (id or name) becomes a task.
/// Shared by the read queries and by proposal validation so the opt-in boundary
/// cannot drift between them.
///
/// Supervised tasks only; id (UUID) or exact case-insensitive name. Zero matches and
/// "matches only an unsupervised task" produce the SAME error, so an opted-out task's
/// existence never leaks.
enum TaskLookup {
    static func resolve(_ query: String, in tasks: [TaskRecord]) throws -> TaskRecord {
        let visible = tasks.filter(\.supervised)
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: q), let hit = visible.first(where: { $0.id == uuid }) {
            return hit
        }
        let named = visible.filter { $0.name.caseInsensitiveCompare(q) == .orderedSame }
        switch named.count {
        case 1: return named[0]
        case 0: throw SupervisorToolError(message: "No supervised task matches '\(q.prefix(80))'.")
        default:
            let ids = named.map { $0.id.uuidString }.joined(separator: ", ")
            throw SupervisorToolError(
                message: "'\(q.prefix(80))' matches several supervised tasks; use an id: \(ids)")
        }
    }
}

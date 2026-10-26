import Foundation

/// What one supervisor run amounted to. Parsing is fail-closed: anything that is not a
/// well-formed successful result is a failure, and a failure never reads as "nothing to do".
public struct RunOutcome: Equatable, Sendable {
    public let ok: Bool
    /// `nil` when the CLI did not report one.
    public let costUSD: Double?
    /// The model's closing note on success, the reason on failure.
    public let note: String

    public static func parse(_ data: Data) -> RunOutcome {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              object["type"] as? String == "result"
        else { return RunOutcome(ok: false, costUSD: nil, note: "The supervisor's output was not a result object.") }
        let cost = (object["total_cost_usd"] as? NSNumber)?.doubleValue
        let subtype = object["subtype"] as? String ?? "unknown"
        let isError = object["is_error"] as? Bool ?? true
        guard subtype == "success", !isError, cost != nil else {
            // `result` carries the CLI's own message on an error ("Not logged in", …).
            let message = (object["result"] as? String).map { SupervisorState.flatten($0, limit: 300) } ?? ""
            let why = isError || subtype != "success"
                ? "The run ended with \(subtype)\(isError ? " (error)" : ""). \(message)"
                : "The run reported no cost."
            return RunOutcome(ok: false, costUSD: cost, note: why.trimmingCharacters(in: .whitespaces))
        }
        return RunOutcome(ok: true, costUSD: cost, note: object["result"] as? String ?? "")
    }
}

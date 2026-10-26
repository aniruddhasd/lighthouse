import Foundation

/// What the user configures about the supervisor. Defaults to OFF; every field that
/// reaches a command line or a budget is validated before a run (`problems`), so a bad
/// value stops the run rather than shaping a process.
public struct SupervisorSettings: Codable, Sendable, Equatable {
    public static let defaultModel = "claude-sonnet-5-5"
    public static let effortLevels = ["low", "medium", "high", "xhigh", "max"]
    public static let instructionLimit = 8_000

    public var enabled = false
    /// The user's standing instructions, free text. The only trusted text the model gets.
    public var instructions = ""
    public var model = SupervisorSettings.defaultModel
    public var effort = "medium"
    /// `CLAUDE_CONFIG_DIR` for the supervisor process. `nil` = the default config
    /// directory, i.e. the default (personal) account. The account is a per-process
    /// choice, so choosing it per calling session later means a different value here.
    public var configDirectory: String?
    public var maxBudgetPerRunUSD = 0.25
    public var maxDailySpendUSD = 5.0
    public var maxWakesPerHour = 20
    /// Consecutive failed runs after which the supervisor halts itself.
    public var failureBreaker = 3
    public var debounceSeconds: TimeInterval = 5
    public var timeoutSeconds: TimeInterval = 120

    public init() {}

    /// Everything wrong with these settings; empty means runnable.
    public var problems: [String] {
        var out: [String] = []
        if instructions.count > Self.instructionLimit {
            out.append("Instructions are longer than \(Self.instructionLimit) characters.")
        }
        if !Self.isSafeToken(model) { out.append("The model name is not a plain identifier.") }
        if !Self.effortLevels.contains(effort) {
            out.append("Effort must be one of \(Self.effortLevels.joined(separator: ", ")).")
        }
        if let dir = configDirectory,
           !(dir.hasPrefix("/") && !dir.contains("\0") && !dir.contains("\n")) {
            out.append("The config directory must be an absolute path.")
        }
        if !(0.01...5).contains(maxBudgetPerRunUSD) { out.append("Per-run budget must be $0.01–$5.") }
        if !(0.1...100).contains(maxDailySpendUSD) { out.append("Daily cap must be $0.10–$100.") }
        if maxDailySpendUSD < maxBudgetPerRunUSD { out.append("Daily cap is below the per-run budget.") }
        if !(1...120).contains(maxWakesPerHour) { out.append("Wakes per hour must be 1–120.") }
        if !(1...10).contains(failureBreaker) { out.append("The failure breaker must be 1–10.") }
        if !(0...600).contains(debounceSeconds) { out.append("Debounce must be 0–600 s.") }
        if !(10...600).contains(timeoutSeconds) { out.append("Timeout must be 10–600 s.") }
        return out
    }

    /// Letters, digits, `.`, `_`, `-`; not starting with `-` (a value must never be
    /// parsed as a flag); at most 64 characters.
    static func isSafeToken(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, first != "-", s.count <= 64 else { return false }
        return s.unicodeScalars.allSatisfy {
            ($0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0))) || $0 == "." || $0 == "_" || $0 == "-"
        }
    }
}

/// The ONE place a shell command string is ever constructed (spec §8: all
/// process execution is argument arrays; the sole exception is launching the
/// agent through the user's login shell so per-folder account selection
/// resolves as it does in a terminal).
///
/// POSIX single-quoting: wrap each word in single quotes; a literal single
/// quote becomes '\'' (close, escaped quote, reopen). Inside single quotes
/// the shell expands NOTHING — no $, backticks, globs, semicolons, newlines.
public enum ShellQuoter {

    /// Quotes one word for POSIX shells (sh, bash, zsh).
    public static func quote(_ word: String) -> String {
        if word.isEmpty { return "''" }
        return "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Renders an argument vector as a single shell command string in which
    /// every element is exactly one word.
    public static func command(_ argv: [String]) -> String {
        argv.map(quote).joined(separator: " ")
    }
}

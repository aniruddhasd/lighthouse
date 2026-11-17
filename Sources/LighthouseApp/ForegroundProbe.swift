import Darwin
import Foundation

/// Which program is in the foreground of a pty. Used by the delivery gate to tell
/// "Claude is running in this tab" from "this tab is a shell prompt" — text typed at a
/// shell prompt is not a message to an agent (and, with an Enter, would be executed).
enum ForegroundProbe {
    /// The name of the foreground process group's leader on the pty whose MASTER side is
    /// `masterFD` (`tcgetpgrp` + `proc_name`). nil when it cannot be determined — the
    /// gate treats that as "unknown", never as "yes".
    static func foregroundProcessName(masterFD: Int32) -> String? {
        guard masterFD >= 0 else { return nil }
        let group = tcgetpgrp(masterFD)
        guard group > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(group, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Claude Code's process is named `claude` (seen live under the tab's shell).
    static func isClaude(name: String?) -> Bool? {
        guard let name else { return nil }
        return name == "claude"
    }
}

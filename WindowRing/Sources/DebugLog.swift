import os

/// Swift's NSLog is redacted to `<private>` in the unified log by default on
/// this system (its whole message is passed as a single os_log `%@` argument,
/// which is private unless marked otherwise) — use this instead of NSLog for
/// anything we actually want to see via `log show`/`log stream`.
private let debugLogger = Logger(subsystem: "com.sandipchitale.WindowRing", category: "Debug")

func debugLog(_ message: String) {
    debugLogger.log("\(message, privacy: .public)")
}

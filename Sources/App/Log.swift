import os

/// An agent app has no window to print into, so anything worth diagnosing has
/// to go somewhere you can read it:
///
///     log stream --predicate 'subsystem == "com.advegaf.drawer"' --level debug
enum Log {
    static let drawer = Logger(subsystem: "com.advegaf.drawer", category: "drawer")
    static let actions = Logger(subsystem: "com.advegaf.drawer", category: "actions")
}

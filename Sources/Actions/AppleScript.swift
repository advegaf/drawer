import Foundation

enum AppleScriptError: Error, Equatable {
    case automationDenied
    case failed(String)
}

extension AppleScriptError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return "Allow Drawer in System Settings > Privacy & Security > Automation"
        case .failed(let message):
            return message
        }
    }
}

enum AppleScript {
    static let darkModeToggle =
        "tell application \"System Events\" to tell appearance preferences to set dark mode to not dark mode"
    static let startScreenSaver = "tell application \"System Events\" to start current screen saver"
    static let emptyTrash = "tell application \"Finder\" to empty trash"
    // Command Option Escape, the same chord the Apple menu's Force Quit item
    // uses. There is no scriptable command for that window.
    static let restart = "tell application \"System Events\" to restart"
    static let shutDown = "tell application \"System Events\" to shut down"
    static let logOut = "tell application \"System Events\" to log out"

    @MainActor
    static func run(_ source: String) throws {
        guard let script = NSAppleScript(source: source) else {
            throw AppleScriptError.failed("Could not parse the script.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        if let errorInfo, !errorInfo.allKeys.isEmpty {
            throw error(from: errorInfo)
        }
    }

    /// Factored out of `run` so a test can check the mapping without
    /// executing a script.
    static func error(from info: NSDictionary) -> AppleScriptError {
        let number = (info[NSAppleScript.errorNumber] as? NSNumber)?.intValue
        guard number != -1743 else { return .automationDenied }
        let message = (info[NSAppleScript.errorMessage] as? String) ?? "AppleScript failed"
        return .failed(message)
    }
}

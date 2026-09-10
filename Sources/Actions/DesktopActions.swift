import AppKit

@MainActor
final class ScreenshotCapture {
    enum Mode: CaseIterable {
        case selection, window, display

        var arguments: [String] {
            switch self {
            case .selection: return ["-i"]
            case .window: return ["-iw"]
            case .display: return ["-m"]
            }
        }
    }

    static let shared = ScreenshotCapture()
    private(set) var isRunning = false

    func capture(_ mode: Mode,
                 run: (String, [String], TimeInterval?) async throws -> ShellResult = {
                     try await Shell.run($0, $1, timeout: $2)
                 },
                 copy: (NSImage) -> Bool = { image in
                     NSPasteboard.general.clearContents()
                     return NSPasteboard.general.writeObjects([image])
                 }) async throws {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("capture.png")
        let result = try await run("/usr/sbin/screencapture", mode.arguments + [output.path], nil)
        guard result.status == 0 else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ActionError.failed(detail.isEmpty ? "Screenshot failed (\(result.status))." : detail)
        }
        // The native picker exits successfully without producing a file on Escape.
        guard FileManager.default.fileExists(atPath: output.path) else { return }
        guard let image = NSImage(contentsOf: output), image.isValid else {
            throw ActionError.failed("The screenshot could not be read.")
        }
        guard copy(image) else { throw ActionError.failed("The screenshot could not be copied.") }
    }
}

enum DesktopActions {
    static let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")
    static let missionControlExecutable = missionControlURL.appendingPathComponent("Contents/MacOS/Mission Control")

    static let canShowDesktop: Bool = {
        guard FileManager.default.isExecutableFile(atPath: missionControlExecutable.path),
              let data = try? Data(contentsOf: missionControlExecutable) else { return false }
        return data.range(of: Data("com.apple.showdesktop.awake".utf8)) != nil
    }()

    @MainActor
    static func missionControl() async throws {
        guard FileManager.default.fileExists(atPath: missionControlURL.path) else { throw ActionError.unavailable }
        _ = try await NSWorkspace.shared.openApplication(at: missionControlURL, configuration: .init())
    }

    static func showDesktop() async throws {
        guard canShowDesktop else { throw ActionError.unavailable }
        let result = try await Shell.run(missionControlExecutable.path, ["1"])
        guard result.status == 0 else { throw ActionError.failed("Show Desktop could not be opened.") }
    }
}

/// Screen recording, started and stopped by the same cell.
///
/// `screencapture -v` records until it is interrupted, so the process is
/// kept and sent an interrupt on the second click. A kill would leave the
/// file unplayable: the recorder writes its index on the way out.
@MainActor
final class ScreenRecording {
    static let shared = ScreenRecording()

    private var process: Process?
    private(set) var output: URL?
    var isRunning: Bool { process?.isRunning == true }

    /// Where a recording lands. The desktop, because a video nobody can find
    /// is a video nobody watches, and because this is where macOS puts its
    /// own screenshots.
    static func destination(date: Date = Date()) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return desktop.appendingPathComponent("Screen Recording \(formatter.string(from: date)).mov")
    }

    @discardableResult
    func toggle(destination: URL? = nil) throws -> Bool {
        if isRunning {
            stop()
            return false
        }
        let url = destination ?? Self.destination()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -v records video, -k keeps the pointer out of it.
        task.arguments = ["-v", url.path]
        do { try task.run() } catch {
            throw ActionError.failed("The recording could not be started.")
        }
        process = task
        output = url
        return true
    }

    func stop() {
        guard let process, process.isRunning else { self.process = nil; return }
        process.interrupt()
        self.process = nil
    }
}

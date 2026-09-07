import Foundation
import Darwin

struct ShellResult: Equatable {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum ShellError: Error, Equatable {
    case timedOut
}

enum ShellOutcome: Equatable {
    case ok
    case notFound
    case cancelled
    case failed(String)
}

enum Shell {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval? = 10) async throws -> ShellResult {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let outputURL = directory.appendingPathComponent("stdout")
        let errorURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        FileManager.default.createFile(atPath: errorURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let errors = try FileHandle(forWritingTo: errorURL)
        defer { try? output.close(); try? errors.close() }
        let state = ShellRunState()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.standardOutput = output
                process.standardError = errors
                process.terminationHandler = { finished in
                    let stdout = (try? Data(contentsOf: outputURL)) ?? Data()
                    let stderr = (try? Data(contentsOf: errorURL)) ?? Data()
                    guard let outcome = state.complete() else { return }
                    switch outcome {
                    case .finished:
                        continuation.resume(returning: ShellResult(
                            status: finished.terminationStatus,
                            stdout: String(data: stdout, encoding: .utf8) ?? "",
                            stderr: String(data: stderr, encoding: .utf8) ?? ""
                        ))
                    case .timedOut: continuation.resume(throwing: ShellError.timedOut)
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    }
                }
                do {
                    try state.launch(process)
                    if let timeout {
                        let timer = DispatchWorkItem { state.stop(.timedOut) }
                        state.install(timer)
                        DispatchQueue.global().asyncAfter(deadline: .now() + max(0, timeout), execute: timer)
                    }
                } catch {
                    if state.complete() != nil { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            state.stop(.cancelled)
        }
    }

    /// Starts `executable` and returns immediately. `onExit` runs on the main
    /// actor once the process has finished, after both pipes hit EOF.
    static func launchDetached(_ executable: String, _ arguments: [String], onExit: @escaping @Sendable (ShellResult) -> Void) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { finished in
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let result = ShellResult(
                status: finished.terminationStatus,
                stdout: String(data: stdoutData, encoding: .utf8) ?? "",
                stderr: String(data: stderrData, encoding: .utf8) ?? ""
            )
            Task { @MainActor in
                onExit(result)
            }
        }

        try process.run()
    }

    /// status 0 is `ok`; a "find shortcut" complaint from `shortcuts` is
    /// `notFound`; anything else is `failed` with the stderr, or the status
    /// when stderr is empty. `cancelled` is for the caller to decide, since
    /// only `screencapture` has a concept of "the user backed out".
    static func classify(_ result: ShellResult) -> ShellOutcome {
        guard result.status != 0 else { return .ok }
        if result.stderr.contains("find shortcut") { return .notFound }
        let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(trimmed.isEmpty ? "exit status \(result.status)" : trimmed)
    }

    /// `--` before the name keeps a leading-dash shortcut name from being
    /// read as another flag.
    static func shortcutsRunArguments(name: String) -> [String] {
        ["run", "--", name]
    }
}

private final class ShellRunState: @unchecked Sendable {
    enum Outcome { case finished, timedOut, cancelled }
    private let lock = NSLock()
    private var process: Process?
    private var timer: DispatchWorkItem?
    private var outcome = Outcome.finished
    private var completed = false

    func launch(_ process: Process) throws {
        lock.lock()
        defer { lock.unlock() }
        guard outcome != .cancelled else { throw CancellationError() }
        self.process = process
        try process.run()
    }

    func install(_ timer: DispatchWorkItem) {
        lock.lock()
        defer { lock.unlock() }
        if completed { timer.cancel() }
        else { self.timer = timer }
    }

    func stop(_ reason: Outcome) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed, outcome == .finished else { return }
        outcome = reason
        if let process, process.isRunning {
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
    }

    func complete() -> Outcome? {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return nil }
        completed = true
        timer?.cancel()
        timer = nil
        process = nil
        return outcome
    }
}

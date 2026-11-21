import Darwin
import Foundation

public struct CommandResult: Equatable, Sendable {
    public let output: String
    public let stderr: String
    public let terminationStatus: Int32
    public let timedOut: Bool

    public init(
        output: String,
        stderr: String = "",
        terminationStatus: Int32,
        timedOut: Bool
    ) {
        self.output = output
        self.stderr = stderr
        self.terminationStatus = terminationStatus
        self.timedOut = timedOut
    }
}

public protocol CommandRunning: Sendable {
    func run(
        executable: String,
        arguments: [String],
        timeout: Duration,
        captureStderr: Bool
    ) async throws -> CommandResult
}

public extension CommandRunning {
    func run(executable: String, arguments: [String], timeout: Duration) async throws -> CommandResult {
        try await run(executable: executable, arguments: arguments, timeout: timeout, captureStderr: false)
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(
        executable: String,
        arguments: [String],
        timeout: Duration,
        captureStderr: Bool = false
    ) async throws -> CommandResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stdoutBuffer = OutputBuffer()
        process.standardOutput = stdoutPipe

        let stderrPipe: Pipe?
        let stderrBuffer = OutputBuffer()
        if captureStderr {
            let pipe = Pipe()
            stderrPipe = pipe
            process.standardError = pipe
        } else {
            stderrPipe = nil
            process.standardError = FileHandle.nullDevice
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stdoutBuffer.append(data)
        }

        stderrPipe?.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(data)
        }

        let state = CommandState()
        let box = ProcessBox(process)

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { finished in
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    if let remaining = try? stdoutPipe.fileHandleForReading.readToEnd() {
                        stdoutBuffer.append(remaining)
                    }
                    if let stderrPipe {
                        stderrPipe.fileHandleForReading.readabilityHandler = nil
                        if let remainingErr = try? stderrPipe.fileHandleForReading.readToEnd() {
                            stderrBuffer.append(remainingErr)
                        }
                    }
                    state.finish(
                        with: CommandResult(
                            output: String(decoding: stdoutBuffer.data, as: UTF8.self),
                            stderr: String(decoding: stderrBuffer.data, as: UTF8.self),
                            terminationStatus: finished.terminationStatus,
                            timedOut: state.timedOut
                        ),
                        continuation: continuation
                    )
                }

                do {
                    try Task.checkCancellation()
                    try process.run()
                    if Task.isCancelled {
                        box.terminate()
                    }
                } catch {
                    stdoutPipe.fileHandleForReading.readabilityHandler = nil
                    stderrPipe?.fileHandleForReading.readabilityHandler = nil
                    state.finish(with: error, continuation: continuation)
                    return
                }

                Task.detached {
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    guard box.process.isRunning else { return }
                    state.markTimedOut()
                    box.terminate()
                }
            }
        } onCancel: {
            box.terminate()
        }
        try Task.checkCancellation()
        return result
    }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        process.terminate()
        Task.detached { [self] in
            try? await Task.sleep(for: .milliseconds(200))
            if process.isRunning {
                _ = Darwin.kill(pid, SIGKILL)
            }
        }
    }
}

private final class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        storage.append(data)
    }
}

private final class CommandState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var timedOutFlag = false

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return timedOutFlag
    }

    func markTimedOut() {
        lock.lock()
        defer { lock.unlock() }
        timedOutFlag = true
    }

    func finish(with result: CommandResult, continuation: CheckedContinuation<CommandResult, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume(returning: result)
    }

    func finish(with error: Error, continuation: CheckedContinuation<CommandResult, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        continuation.resume(throwing: error)
    }
}

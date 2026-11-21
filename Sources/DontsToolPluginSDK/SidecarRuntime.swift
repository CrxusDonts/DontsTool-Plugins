import Darwin
import Foundation

private struct RawIncomingHeader: Decodable {
    let id: Int?
    let method: String
}

private struct TypedIncomingRequest<Params: Decodable>: Decodable {
    let id: Int?
    let method: String
    let params: Params
}

public protocol RPCOutputWriting: Sendable {
    func writeLine(_ data: Data)
}

public final class StdoutWriter: RPCOutputWriting, @unchecked Sendable {
    private let lock = NSLock()
    private let encoder = JSONEncoder()
    private let outputHandle: FileHandle
    private let flushCStdout: Bool

    public init(outputHandle: FileHandle = .standardOutput, flushCStdout: Bool = true) {
        self.outputHandle = outputHandle
        self.flushCStdout = flushCStdout
    }

    public func writeLine(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        var line = data
        line.append(UInt8(ascii: "\n"))
        try? outputHandle.write(contentsOf: line)
        if flushCStdout {
            fflush(stdout)
        }
    }

    public func sendResult<Result: Codable & Sendable>(id: Int, result: Result) {
        sendResponse(PluginRPCResponse(id: id, result: result, error: nil))
    }

    public func sendError(id: Int, code: Int, message: String) {
        sendResponse(PluginRPCResponse<PluginEmptyParams>(
            id: id,
            result: nil,
            error: PluginRPCErrorPayload(code: code, message: message)
        ))
    }

    private func sendResponse<Result: Codable & Sendable>(_ response: PluginRPCResponse<Result>) {
        guard let data = try? encoder.encode(response) else { return }
        writeLine(data)
    }
}

public actor SidecarSession {
    private let engine: any PluginEngine
    private let writer: StdoutWriter
    private var activeTasks: [Int: Task<Void, Never>] = [:]

    public init(engine: any PluginEngine, writer: StdoutWriter = StdoutWriter()) {
        self.engine = engine
        self.writer = writer
    }

    public func handleLine(_ lineData: Data) -> Bool {
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(RawIncomingHeader.self, from: lineData) else {
            return false
        }

        switch header.method {
        case "shutdown":
            if let id = header.id {
                writer.sendResult(id: id, result: PluginEmptyParams())
            }
            return true

        case "cancel":
            if let req = try? decoder.decode(TypedIncomingRequest<PluginCancelParams>.self, from: lineData) {
                activeTasks.removeValue(forKey: req.params.id)?.cancel()
            }
            return false

        case "search":
            guard let id = header.id else { return false }
            let params: PluginSearchParams
            if let req = try? decoder.decode(TypedIncomingRequest<PluginSearchParams>.self, from: lineData) {
                params = req.params
            } else {
                writer.sendError(id: id, code: -32602, message: "无效的 search 参数")
                return false
            }

            let engine = self.engine
            let writer = self.writer
            let task = Task {
                let result = await engine.search(params)
                if !Task.isCancelled {
                    writer.sendResult(id: id, result: result)
                }
                self.finishTask(id: id)
            }
            activeTasks[id] = task
            return false

        case "execute":
            guard let id = header.id else { return false }
            guard let req = try? decoder.decode(TypedIncomingRequest<PluginExecuteParams>.self, from: lineData) else {
                writer.sendError(id: id, code: -32602, message: "无效的 execute 参数")
                return false
            }

            let engine = self.engine
            let writer = self.writer
            let task = Task {
                let result = await engine.execute(req.params)
                if !Task.isCancelled {
                    writer.sendResult(id: id, result: result)
                }
                self.finishTask(id: id)
            }
            activeTasks[id] = task
            return false

        default:
            if let id = header.id {
                writer.sendError(id: id, code: -32601, message: "不支持的方法：\(header.method)")
            }
            return false
        }
    }

    public func drainActiveTasks() async {
        while !activeTasks.isEmpty {
            let tasks = Array(activeTasks.values)
            for task in tasks {
                _ = await task.value
            }
        }
    }

    private func finishTask(id: Int) {
        activeTasks.removeValue(forKey: id)
    }
}

public enum SidecarRuntime {
    public static func excludedHostPIDs(environment: [String: String] = ProcessInfo.processInfo.environment) -> Set<Int32> {
        var excluded: Set<Int32> = [ProcessInfo.processInfo.processIdentifier, getppid()]
        if let rawHostPID = environment["DONTSTOOL_HOST_PID"],
           let hostPID = Int32(rawHostPID),
           hostPID > 1 {
            excluded.insert(hostPID)
        }
        return excluded
    }

    public static func runDaemon(engine: any PluginEngine, threadName: String = "com.donts.plugin.stdin") async {
        signal(SIGPIPE, SIG_IGN)
        let session = SidecarSession(engine: engine)

        let lines = AsyncStream<String> { continuation in
            let thread = Thread {
                while let line = readLine(strippingNewline: true) {
                    continuation.yield(line)
                }
                continuation.finish()
            }
            thread.name = threadName
            thread.start()
        }

        for await rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            let shouldStop = await session.handleLine(lineData)
            if shouldStop {
                break
            }
        }
        await session.drainActiveTasks()
    }

    public static func runOneshot(engine: any PluginEngine) async {
        signal(SIGPIPE, SIG_IGN)
        let session = SidecarSession(engine: engine)
        while let rawLine = readLine(strippingNewline: true) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let lineData = trimmed.data(using: .utf8) else { continue }
            _ = await session.handleLine(lineData)
            break
        }
        await session.drainActiveTasks()
    }
}

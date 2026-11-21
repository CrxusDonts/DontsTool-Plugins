import Foundation

public struct RunningProcess: Equatable, Hashable, Sendable {
    public let pid: Int32
    public let parentPID: Int32
    public let uid: UInt32
    public let name: String
    public let executablePath: String
    public let commandLine: String
    public let appBundlePath: String?
    public let cpuPercent: Double
    public let memoryBytes: UInt64
    public let isApplication: Bool

    public init(
        pid: Int32,
        parentPID: Int32 = 1,
        uid: UInt32 = 0,
        name: String,
        executablePath: String,
        commandLine: String = "",
        appBundlePath: String? = nil,
        cpuPercent: Double = 0,
        memoryBytes: UInt64 = 0,
        isApplication: Bool = false
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.uid = uid
        self.name = name
        self.executablePath = executablePath
        self.commandLine = commandLine.isEmpty ? executablePath : commandLine
        self.appBundlePath = appBundlePath
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.isApplication = isApplication
    }

    public var formattedMemory: String {
        let megabytes = Double(memoryBytes) / (1024 * 1024)
        if megabytes >= 1024 {
            return String(format: "%.1f GB", megabytes / 1024)
        }
        if megabytes >= 10 {
            return String(format: "%.0f MB", megabytes)
        }
        if megabytes >= 1 {
            return String(format: "%.1f MB", megabytes)
        }
        return "< 1 MB"
    }

    public var formattedCPU: String {
        if cpuPercent >= 10 {
            return String(format: "%.0f%%", cpuPercent)
        }
        return String(format: "%.1f%%", cpuPercent)
    }
}

public enum ProcessTerminationSignal: Equatable, Sendable {
    case terminate
    case forceKill
}

public enum ProcessControlError: LocalizedError, Equatable, Sendable {
    case protectedProcess(String)
    case permissionDenied(pid: Int32)
    case notFound(pid: Int32)
    case failed(pid: Int32, code: Int32)
    case listFailed(String)

    public var errorDescription: String? {
        switch self {
        case .protectedProcess(let detail):
            "受保护的系统或当前进程不可结束：\(detail)"
        case .permissionDenied(let pid):
            "没有权限结束进程 PID \(pid)（可能属于系统或其他用户）"
        case .notFound(let pid):
            "进程 PID \(pid) 已退出或不存在"
        case .failed(let pid, let code):
            "结束进程 PID \(pid) 失败（errno \(code)）"
        case .listFailed(let detail):
            "获取运行中进程失败：\(detail)"
        }
    }
}

public protocol ProcessControlling: Sendable {
    func listProcesses() async throws -> [RunningProcess]
    func listeningPIDs(onPort port: UInt16) async throws -> Set<Int32>
    func terminate(pid: Int32, signal: ProcessTerminationSignal) async throws
    func killAll(named name: String, excludingPID: Int32, signal: ProcessTerminationSignal) async throws -> Int
}

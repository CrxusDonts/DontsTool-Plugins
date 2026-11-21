import AppKit
import Darwin
import DontsToolPluginSDK
import Foundation

public struct RunningAppSnapshot: Equatable, Sendable {
    public let pid: Int32
    public let localizedName: String?
    public let bundlePath: String?
    public let isRegularApp: Bool

    public init(pid: Int32, localizedName: String?, bundlePath: String?, isRegularApp: Bool) {
        self.pid = pid
        self.localizedName = localizedName
        self.bundlePath = bundlePath
        self.isRegularApp = isRegularApp
    }
}

public final class SystemProcessService: ProcessControlling, Sendable {
    private let excludedPIDs: Set<Int32>
    private let runner: any CommandRunning

    public init(
        excludedPIDs: Set<Int32> = [],
        runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.excludedPIDs = excludedPIDs
        self.runner = runner
    }

    public func listProcesses() async throws -> [RunningProcess] {
        let currentUID = getuid()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let appsByPID = await MainActor.run { Self.snapshotRunningApps() }

        let commResult: CommandResult
        do {
            commResult = try await runner.run(
                executable: "/bin/ps",
                arguments: ["-axo", "pid=,ppid=,uid=,%cpu=,rss=,comm="],
                timeout: .seconds(2),
                captureStderr: true
            )
        } catch {
            throw ProcessControlError.listFailed(error.localizedDescription)
        }

        if commResult.timedOut {
            throw ProcessControlError.listFailed("命令执行超时")
        }
        if commResult.terminationStatus != 0 {
            let errText = commResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProcessControlError.listFailed(errText.isEmpty ? "exit \(commResult.terminationStatus)" : errText)
        }

        let argsOutput = (try? await runner.run(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,args="],
            timeout: .seconds(2),
            captureStderr: false
        ))?.output ?? ""

        return Self.parsePSOutput(
            commOutput: commResult.output,
            argsOutput: argsOutput,
            currentUID: currentUID,
            currentPID: currentPID,
            appsByPID: appsByPID,
            excludedPIDs: excludedPIDs
        )
    }

    public func listeningPIDs(onPort port: UInt16) async throws -> Set<Int32> {
        let result: CommandResult
        do {
            result = try await runner.run(
                executable: "/usr/sbin/lsof",
                arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fp"],
                timeout: .seconds(2),
                captureStderr: true
            )
        } catch {
            throw ProcessControlError.listFailed(error.localizedDescription)
        }

        if result.timedOut {
            throw ProcessControlError.listFailed("命令执行超时")
        }
        return Self.parseLsofPIDs(result.output)
    }

    public func terminate(pid: Int32, signal: ProcessTerminationSignal) async throws {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard pid > 1, pid != currentPID, !excludedPIDs.contains(pid) else {
            throw ProcessControlError.protectedProcess("PID \(pid)")
        }

        if signal == .terminate {
            let terminatedByAppKit = await MainActor.run { () -> Bool in
                guard let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular else {
                    return false
                }
                return app.terminate()
            }
            if terminatedByAppKit {
                return
            }
        } else {
            let forceTerminated = await MainActor.run { () -> Bool in
                guard let app = NSRunningApplication(processIdentifier: pid),
                      app.activationPolicy == .regular else {
                    return false
                }
                return app.forceTerminate()
            }
            if forceTerminated {
                return
            }
        }

        let posixSignal = signal == .terminate ? SIGTERM : SIGKILL
        if Darwin.kill(pid, posixSignal) != 0 {
            let code = errno
            switch code {
            case EPERM:
                throw ProcessControlError.permissionDenied(pid: pid)
            case ESRCH:
                throw ProcessControlError.notFound(pid: pid)
            default:
                throw ProcessControlError.failed(pid: pid, code: code)
            }
        }
    }

    public func killAll(named name: String, excludingPID: Int32, signal: ProcessTerminationSignal) async throws -> Int {
        let processes = try await listProcesses()
        let matches = processes.filter {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
                && $0.pid != excludingPID
                && !excludedPIDs.contains($0.pid)
                && $0.pid > 1
        }
        var killed = 0
        var lastError: (any Error)?
        for process in matches {
            do {
                try await terminate(pid: process.pid, signal: signal)
                killed += 1
            } catch ProcessControlError.notFound {
                continue
            } catch {
                lastError = error
            }
        }
        if killed == 0, let lastError {
            throw lastError
        }
        return killed
    }

    // MARK: - Parsing

    public static func parsePSOutput(
        commOutput: String,
        argsOutput: String,
        currentUID: UInt32,
        currentPID: Int32,
        appsByPID: [Int32: RunningAppSnapshot],
        excludedPIDs: Set<Int32> = []
    ) -> [RunningProcess] {
        var argsByPID: [Int32: String] = [:]
        for line in argsOutput.split(whereSeparator: \.isNewline) {
            let trimmed = line.drop(while: \.isWhitespace)
            guard let spaceIndex = trimmed.firstIndex(where: \.isWhitespace),
                  let pid = Int32(trimmed[..<spaceIndex]) else { continue }
            let command = trimmed[spaceIndex...].drop(while: \.isWhitespace)
            if !command.isEmpty {
                argsByPID[pid] = String(command)
            }
        }

        var results: [RunningProcess] = []
        for rawLine in commOutput.split(whereSeparator: \.isNewline) {
            let trimmed = rawLine.drop(while: \.isWhitespace)
            guard !trimmed.isEmpty else { continue }
            let fields = splitFixedFields(trimmed, count: 5)
            guard fields.count == 6,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]),
                  let uid = UInt32(fields[2]),
                  let cpu = Double(fields[3]),
                  let rssKiB = UInt64(fields[4]) else { continue }

            guard pid > 1, pid != currentPID, !excludedPIDs.contains(pid), uid == currentUID else { continue }

            let commPath = String(fields[5]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !commPath.isEmpty else { continue }

            let app = appsByPID[pid]
            let fallbackName = URL(fileURLWithPath: commPath).lastPathComponent
            let displayName: String
            if let localized = app?.localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !localized.isEmpty {
                displayName = localized
            } else {
                displayName = fallbackName.isEmpty ? commPath : fallbackName
            }

            let bundlePath = app?.bundlePath ?? Self.enclosingAppBundlePath(for: commPath)
            let commandLine = argsByPID[pid] ?? commPath

            results.append(RunningProcess(
                pid: pid,
                parentPID: ppid,
                uid: uid,
                name: displayName,
                executablePath: commPath,
                commandLine: commandLine,
                appBundlePath: bundlePath,
                cpuPercent: max(0, cpu),
                memoryBytes: rssKiB * 1024,
                isApplication: app?.isRegularApp ?? false
            ))
        }
        return results
    }

    public static func parseLsofPIDs(_ output: String) -> Set<Int32> {
        var pids: Set<Int32> = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard line.first == "p", let pid = Int32(line.dropFirst()), pid > 1 else { continue }
            pids.insert(pid)
        }
        return pids
    }

    public static func enclosingAppBundlePath(for executablePath: String) -> String? {
        guard let range = executablePath.range(of: ".app/") else { return nil }
        let candidate = String(executablePath[..<range.upperBound].dropLast())
        return candidate.hasPrefix("/") ? candidate : nil
    }

    private static func splitFixedFields(_ line: Substring, count: Int) -> [Substring] {
        var parts: [Substring] = []
        parts.reserveCapacity(count + 1)
        var cursor = line.startIndex
        for _ in 0..<count {
            while cursor < line.endIndex, line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            guard cursor < line.endIndex else { return parts }
            let start = cursor
            while cursor < line.endIndex, !line[cursor].isWhitespace {
                cursor = line.index(after: cursor)
            }
            parts.append(line[start..<cursor])
        }
        while cursor < line.endIndex, line[cursor].isWhitespace {
            cursor = line.index(after: cursor)
        }
        if cursor < line.endIndex {
            parts.append(line[cursor..<line.endIndex])
        }
        return parts
    }

    @MainActor
    private static func snapshotRunningApps() -> [Int32: RunningAppSnapshot] {
        var map: [Int32: RunningAppSnapshot] = [:]
        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid > 1 else { continue }
            map[pid] = RunningAppSnapshot(
                pid: pid,
                localizedName: app.localizedName,
                bundlePath: app.bundleURL?.path,
                isRegularApp: app.activationPolicy == .regular
            )
        }
        return map
    }
}

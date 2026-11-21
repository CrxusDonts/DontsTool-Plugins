import AppKit
import Darwin
import DontsToolPluginSDK
import Foundation

public final class SystemTerminalFinderService: TerminalFinderControlling, @unchecked Sendable {
    public struct ProcessSnapshotRow: Equatable, Sendable {
        public let pid: Int32
        public let ppid: Int32
        public let tty: String
        public let stat: String
        public let command: String

        public init(pid: Int32, ppid: Int32, tty: String, stat: String, command: String) {
            self.pid = pid
            self.ppid = ppid
            self.tty = tty
            self.stat = stat
            self.command = command
        }
    }

    private static let interactiveShellNames: Set<String> = [
        "zsh", "-zsh", "bash", "-bash", "fish", "-fish", "sh", "-sh",
        "nu", "pwsh", "tcsh", "-tcsh", "csh", "-csh", "ksh", "-ksh", "elvish"
    ]

    private let runner: any CommandRunning

    public init(runner: any CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public func installedTerminals() -> [TerminalAppDescriptor] {
        var result: [TerminalAppDescriptor] = []
        for descriptor in TerminalAppCatalog.knownTerminals {
            if let resolved = resolveInstalledAppURL(for: descriptor) {
                result.append(descriptor.withAppPath(resolved.path))
            }
        }
        return result
    }

    public func runningTerminalBundleIDs() -> [String] {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        var matched: [String] = []
        for descriptor in TerminalAppCatalog.knownTerminals {
            if running.contains(where: { descriptor.matches(bundleID: $0) }) {
                matched.append(descriptor.bundleID)
            }
        }
        return matched
    }

    public func currentFinderDirectory() async throws -> URL {
        let script = #"""
        tell application "Finder"
            set sel to selection
            if (count of sel) > 0 then
                set firstItem to item 1 of sel
                set itemClass to class of firstItem
                if itemClass is folder or itemClass is disk then
                    return POSIX path of (firstItem as alias)
                else
                    return POSIX path of ((container of firstItem) as alias)
                end if
            end if
            if (count of Finder windows) > 0 then
                try
                    return POSIX path of (target of front Finder window as alias)
                end try
            end if
            return POSIX path of (desktop as alias)
        end tell
        """#

        let rawPath = try await runAppleScript(script, targetName: "访达", timeout: .seconds(2))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawPath.isEmpty else {
            throw TerminalFinderError.finderNoDirectory
        }
        let url = URL(fileURLWithPath: rawPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TerminalFinderError.directoryNotFound(url.path)
        }
        return normalizeToDirectory(url)
    }

    public func currentTerminalDirectory(preferredBundleID: String?) async throws -> URL {
        let targetBundleIDs = orderedRunningTerminalBundleIDs(preferredBundleID: preferredBundleID)
        guard !targetBundleIDs.isEmpty else {
            throw TerminalFinderError.terminalNoDirectory
        }

        // 1. Try precise active-tab TTY query for AppleScript-capable terminals (iTerm2 / Apple Terminal).
        for bundleID in targetBundleIDs {
            if bundleID == TerminalAppCatalog.iterm2BundleID,
               let tty = try? await activeITerm2TTY(),
               let dir = await directoryForTTY(tty) {
                return dir
            }
            if bundleID == TerminalAppCatalog.appleTerminalBundleID,
               let tty = try? await activeAppleTerminalTTY(),
               let dir = await directoryForTTY(tty) {
                return dir
            }
        }

        // 2. Universal process-tree shell CWD lookup (works for Ghostty, Warp, WezTerm, Kitty, Alacritty, OrcaTerm, and fallback).
        let rows = await readProcessSnapshot()
        for bundleID in targetBundleIDs {
            let rootPIDs = runningPIDs(forTerminalBundleID: bundleID)
            let candidatePIDs = Self.candidateShellPIDs(underRootPIDs: rootPIDs, rows: rows)
            for pid in candidatePIDs {
                if let path = Self.workingDirectory(forPID: pid),
                   isValidWorkingDirectory(path) {
                    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
                }
            }
        }

        throw TerminalFinderError.terminalNoDirectory
    }

    public func openInTerminal(directory: URL, terminalBundleID: String) async throws {
        let normalized = normalizeToDirectory(directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: normalized.path, isDirectory: &isDir), isDir.boolValue else {
            throw TerminalFinderError.directoryNotFound(normalized.path)
        }

        let descriptor = TerminalAppCatalog.descriptor(forBundleID: terminalBundleID)
            ?? TerminalAppDescriptor(bundleID: terminalBundleID, displayName: terminalBundleID)
        guard let appURL = resolveInstalledAppURL(for: descriptor) else {
            throw TerminalFinderError.terminalNotInstalled(descriptor.displayName)
        }

        if descriptor.bundleID == "org.alacritty" {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.createsNewApplicationInstance = true
            config.arguments = ["--working-directory", normalized.path]
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            return
        }

        if descriptor.bundleID == "net.kovidgoyal.kitty" {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            config.arguments = ["--directory", normalized.path]
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            return
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await NSWorkspace.shared.open([normalized], withApplicationAt: appURL, configuration: config)
    }

    public func openInFinder(directory: URL) async throws {
        let normalized = normalizeToDirectory(directory)
        guard FileManager.default.fileExists(atPath: normalized.path) else {
            throw TerminalFinderError.directoryNotFound(normalized.path)
        }
        let opened = await MainActor.run {
            NSWorkspace.shared.open(normalized)
        }
        if !opened {
            throw TerminalFinderError.actionFailed("无法在访达中打开 \(normalized.path)")
        }
    }

    // MARK: - Pure Parsing & Selection Helpers

    public static func parseProcessSnapshot(_ output: String) -> [ProcessSnapshotRow] {
        var rows: [ProcessSnapshotRow] = []
        for rawLine in output.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let parts = line.split(maxSplits: 4, omittingEmptySubsequences: true, whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 5,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            rows.append(ProcessSnapshotRow(
                pid: pid,
                ppid: ppid,
                tty: String(parts[2]),
                stat: String(parts[3]),
                command: String(parts[4]).trimmingCharacters(in: .whitespaces)
            ))
        }
        return rows
    }

    public static func candidateShellPIDs(underRootPIDs rootPIDs: [Int32], rows: [ProcessSnapshotRow]) -> [Int32] {
        guard !rootPIDs.isEmpty else { return [] }
        var childrenByParent: [Int32: [ProcessSnapshotRow]] = [:]
        for row in rows {
            childrenByParent[row.ppid, default: []].append(row)
        }

        var descendants: [(row: ProcessSnapshotRow, depth: Int)] = []
        var visited = Set(rootPIDs)
        var queue: [(pid: Int32, depth: Int)] = rootPIDs.map { ($0, 0) }
        var cursor = 0
        while cursor < queue.count {
            let current = queue[cursor]
            cursor += 1
            for child in childrenByParent[current.pid] ?? [] {
                guard visited.insert(child.pid).inserted else { continue }
                let nextDepth = current.depth + 1
                descendants.append((child, nextDepth))
                queue.append((child.pid, nextDepth))
            }
        }

        let ttyDescendants = descendants.filter { $0.row.tty != "??" && !$0.row.tty.isEmpty }
        return ttyDescendants
            .sorted { lhs, rhs in
                let lhsScore = scoreCandidate(lhs.row, depth: lhs.depth)
                let rhsScore = scoreCandidate(rhs.row, depth: rhs.depth)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.row.pid > rhs.row.pid
            }
            .map(\.row.pid)
    }

    public static func candidatePIDs(forTTY rawTTY: String, rows: [ProcessSnapshotRow]) -> [Int32] {
        let normalized = rawTTY.replacingOccurrences(of: "/dev/", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return [] }
        let matching = rows.filter { row in
            row.tty == normalized || row.tty == "/dev/\(normalized)"
        }
        return matching
            .sorted { lhs, rhs in
                let lhsScore = scoreCandidate(lhs, depth: 1)
                let rhsScore = scoreCandidate(rhs, depth: 1)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.pid > rhs.pid
            }
            .map(\.pid)
    }

    private static func scoreCandidate(_ row: ProcessSnapshotRow, depth: Int) -> Int {
        var score = 0
        let isForeground = row.stat.contains("+")
        let baseName = URL(fileURLWithPath: row.command).lastPathComponent.lowercased()
        let isShell = interactiveShellNames.contains(baseName)
        if isForeground { score += 100 }
        if isShell { score += 50 }
        score += min(depth, 10) * 5
        return score
    }

    public static func workingDirectory(forPID pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        let bytesReturned = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        guard bytesReturned == size else { return nil }
        let path = withUnsafePointer(to: &info.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { cString in
                String(cString: cString)
            }
        }
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Private Helpers

    private func resolveInstalledAppURL(for descriptor: TerminalAppDescriptor) -> URL? {
        for candidateID in descriptor.allBundleIDs {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: candidateID) {
                return url
            }
        }
        return nil
    }

    private func orderedRunningTerminalBundleIDs(preferredBundleID: String?) -> [String] {
        let running = runningTerminalBundleIDs()
        guard let preferredBundleID, !preferredBundleID.isEmpty,
              let preferred = TerminalAppCatalog.descriptor(forBundleID: preferredBundleID)?.bundleID,
              running.contains(preferred) else {
            return running
        }
        return [preferred] + running.filter { $0 != preferred }
    }

    private func runningPIDs(forTerminalBundleID bundleID: String) -> [Int32] {
        guard let descriptor = TerminalAppCatalog.descriptor(forBundleID: bundleID) else { return [] }
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return descriptor.matches(bundleID: id)
            }
            .map(\.processIdentifier)
    }

    private func normalizeToDirectory(_ url: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
            return url.deletingLastPathComponent().standardizedFileURL
        }
        return url.standardizedFileURL
    }

    private func isValidWorkingDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard path != "/", FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return true
    }

    private func activeITerm2TTY() async throws -> String? {
        let script = #"""
        tell application id "com.googlecode.iterm2"
            if (count of windows) > 0 then
                return tty of current session of current window
            end if
        end tell
        """#
        let output = try await runAppleScript(script, targetName: "iTerm2", timeout: .milliseconds(1500))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func activeAppleTerminalTTY() async throws -> String? {
        let script = #"""
        tell application id "com.apple.Terminal"
            if (count of windows) > 0 then
                return tty of selected tab of front window
            end if
        end tell
        """#
        let output = try await runAppleScript(script, targetName: "终端", timeout: .milliseconds(1500))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    private func directoryForTTY(_ tty: String) async -> URL? {
        let rows = await readProcessSnapshot()
        for pid in Self.candidatePIDs(forTTY: tty, rows: rows) {
            if let path = Self.workingDirectory(forPID: pid), isValidWorkingDirectory(path) {
                return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
            }
        }
        return nil
    }

    private func readProcessSnapshot() async -> [ProcessSnapshotRow] {
        guard let result = try? await runner.run(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,tty=,stat=,comm="],
            timeout: .seconds(2),
            captureStderr: false
        ), !result.timedOut, result.terminationStatus == 0 else {
            return []
        }
        return Self.parseProcessSnapshot(result.output)
    }

    private func runAppleScript(_ script: String, targetName: String, timeout: Duration) async throws -> String {
        let result: CommandResult
        do {
            result = try await runner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script],
                timeout: timeout,
                captureStderr: true
            )
        } catch {
            throw TerminalFinderError.actionFailed(error.localizedDescription)
        }

        if result.timedOut {
            throw TerminalFinderError.actionFailed("与 \(targetName) 通信超时")
        }
        if result.terminationStatus != 0 {
            let errText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if errText.contains("-1743") || errText.localizedCaseInsensitiveContains("not authorized") {
                throw TerminalFinderError.automationDenied(targetName)
            }
            throw TerminalFinderError.actionFailed(errText.isEmpty ? "exit \(result.terminationStatus)" : errText)
        }
        return result.output
    }
}

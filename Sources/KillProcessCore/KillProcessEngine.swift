import DontsToolPluginSDK
import Foundation

public actor KillProcessEngine: PluginEngine {
    public static let entryCanonicalKey = "process:entry"

    private let service: any ProcessControlling
    private let cacheTTL: TimeInterval
    private let nowProvider: @Sendable () -> Date
    private let selfPID: Int32

    private var cachedProcesses: [RunningProcess] = []
    private var cacheTimestamp: Date = .distantPast

    public init(
        service: any ProcessControlling = SystemProcessService(),
        cacheTTL: TimeInterval = 1.5,
        nowProvider: @escaping @Sendable () -> Date = Date.init,
        selfPID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.service = service
        self.cacheTTL = cacheTTL
        self.nowProvider = nowProvider
        self.selfPID = selfPID
    }

    public func invalidateCache() {
        cacheTimestamp = .distantPast
        cachedProcesses = []
    }

    public func search(_ params: PluginSearchParams) async -> PluginSearchResultDTO {
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if let port = parsePortQuery(query) {
            return await searchByPort(port)
        }

        let processes: [RunningProcess]
        do {
            processes = try await loadProcesses()
        } catch {
            if Task.isCancelled { return PluginSearchResultDTO(items: []) }
            return PluginSearchResultDTO(
                items: [hintItem(title: "无法读取进程列表", subtitle: error.localizedDescription)],
                notice: error.localizedDescription
            )
        }

        guard !Task.isCancelled else { return PluginSearchResultDTO(items: []) }

        let nameCounts = Dictionary(grouping: processes, by: { $0.name.lowercased() }).mapValues(\.count)
        let ranked = rank(processes: processes, query: query)
        guard !ranked.isEmpty else {
            return PluginSearchResultDTO(items: [hintItem(
                title: query.isEmpty ? "没有可结束的用户进程" : "没有匹配的进程",
                subtitle: query.isEmpty ? "当前没有符合条件的运行中进程" : "可按进程名、PID、启动命令或 :端口号 筛选"
            )])
        }

        let items = ranked.prefix(30).map { entry in
            makeProcessItem(
                entry.process,
                score: entry.score,
                matchingNameCount: nameCounts[entry.process.name.lowercased(), default: 1],
                portBadge: nil
            )
        }
        return PluginSearchResultDTO(items: items)
    }

    public func execute(_ params: PluginExecuteParams) async -> PluginExecuteResultDTO {
        switch params.actionId {
        case "process.terminate", "process.forceKill":
            guard let pidText = params.payload["pid"], let pid = Int32(pidText) else {
                return PluginExecuteResultDTO(error: "无效的进程 PID")
            }
            let name = params.payload["name"] ?? "进程"
            let signal: ProcessTerminationSignal = params.payload["signal"] == "forceKill" ? .forceKill : .terminate
            do {
                try await service.terminate(pid: pid, signal: signal)
                invalidateCache()
                try? await Task.sleep(for: .milliseconds(100))
                let message = signal == .forceKill
                    ? "已强制结束 \(name)（PID \(pid)）"
                    : "已结束 \(name)（PID \(pid)）"
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    toast: message,
                    refresh: true,
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }

        case "process.killAll", "process.forceKillAll":
            guard let name = params.payload["name"], !name.isEmpty else {
                return PluginExecuteResultDTO(error: "缺少进程名称")
            }
            let signal: ProcessTerminationSignal = params.payload["signal"] == "forceKill" ? .forceKill : .terminate
            do {
                let count = try await service.killAll(
                    named: name,
                    excludingPID: selfPID,
                    signal: signal
                )
                invalidateCache()
                try? await Task.sleep(for: .milliseconds(120))
                let message = signal == .forceKill
                    ? "已强制结束 \(count) 个 \(name) 进程"
                    : "已结束 \(count) 个 \(name) 进程"
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    toast: message,
                    refresh: true,
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }

        default:
            return PluginExecuteResultDTO(error: "未知操作：\(params.actionId)")
        }
    }

    // MARK: - Private

    private func searchByPort(_ port: UInt16) async -> PluginSearchResultDTO {
        let pids: Set<Int32>
        let processes: [RunningProcess]
        do {
            pids = try await service.listeningPIDs(onPort: port)
            processes = try await loadProcesses(forceRefresh: true)
        } catch {
            if Task.isCancelled { return PluginSearchResultDTO(items: []) }
            return PluginSearchResultDTO(
                items: [hintItem(title: "端口查询失败", subtitle: error.localizedDescription)],
                notice: error.localizedDescription
            )
        }
        guard !Task.isCancelled else { return PluginSearchResultDTO(items: []) }

        let matching = processes
            .filter { pids.contains($0.pid) }
            .sorted { $0.memoryBytes > $1.memoryBytes }

        guard !matching.isEmpty else {
            return PluginSearchResultDTO(items: [hintItem(
                title: "端口 :\(port) 无监听进程",
                subtitle: "当前用户下没有监听 TCP 端口 \(port) 的进程"
            )])
        }

        let nameCounts = Dictionary(grouping: processes, by: { $0.name.lowercased() }).mapValues(\.count)
        let items = matching.enumerated().map { index, process in
            makeProcessItem(
                process,
                score: 3000 - Double(index),
                matchingNameCount: nameCounts[process.name.lowercased(), default: 1],
                portBadge: ":\(port)"
            )
        }
        return PluginSearchResultDTO(items: items)
    }

    private func loadProcesses(forceRefresh: Bool = false) async throws -> [RunningProcess] {
        let now = nowProvider()
        if !forceRefresh, !cachedProcesses.isEmpty, now.timeIntervalSince(cacheTimestamp) < cacheTTL {
            return cachedProcesses
        }
        let fresh = try await service.listProcesses()
        guard !Task.isCancelled else { return [] }
        cachedProcesses = fresh
        cacheTimestamp = nowProvider()
        return fresh
    }

    private func rank(processes: [RunningProcess], query: String) -> [(process: RunningProcess, score: Double)] {
        if query.isEmpty {
            return processes
                .sorted { lhs, rhs in
                    let lhsHot = lhs.cpuPercent >= 25
                    let rhsHot = rhs.cpuPercent >= 25
                    if lhsHot != rhsHot { return lhsHot }
                    if lhs.memoryBytes != rhs.memoryBytes { return lhs.memoryBytes > rhs.memoryBytes }
                    if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
                    return lhs.pid < rhs.pid
                }
                .enumerated()
                .map { offset, process in (process, 2000 - Double(offset)) }
        }

        let lowerQuery = query.lowercased()
        let pidQuery = Int32(query)

        var scored: [(process: RunningProcess, score: Double)] = []
        for process in processes {
            let pidString = String(process.pid)
            let score: Double?
            if let pidQuery, process.pid == pidQuery {
                score = 3500
            } else if process.name.compare(query, options: .caseInsensitive) == .orderedSame {
                score = 3000
            } else if let nameScore = FuzzyMatcher.score(query: query, candidate: process.name) {
                score = 2000 + min(nameScore, 900)
            } else if pidString.hasPrefix(query) {
                score = 1800
            } else if process.commandLine.lowercased().contains(lowerQuery) {
                score = 1500
            } else if process.executablePath.lowercased().contains(lowerQuery) {
                score = 1400
            } else {
                score = nil
            }
            if let score {
                scored.append((process, score))
            }
        }

        return scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.process.memoryBytes != rhs.process.memoryBytes { return lhs.process.memoryBytes > rhs.process.memoryBytes }
            if lhs.process.cpuPercent != rhs.process.cpuPercent { return lhs.process.cpuPercent > rhs.process.cpuPercent }
            return lhs.process.pid < rhs.process.pid
        }
    }

    private func makeProcessItem(
        _ process: RunningProcess,
        score: Double,
        matchingNameCount: Int,
        portBadge: String?
    ) -> PluginSearchItemDTO {
        let icon: PluginIconDTO
        if let appPath = process.appBundlePath {
            icon = PluginIconDTO(kind: "application", value: appPath)
        } else {
            icon = PluginIconDTO(kind: "symbol", value: "terminal", tint: "gray")
        }

        let badgeText = portBadge.map { "\($0) · \(process.formattedMemory)" } ?? process.formattedMemory
        let badgeTint: String
        if portBadge != nil {
            badgeTint = "blue"
        } else if process.memoryBytes >= 1_073_741_824 || process.cpuPercent >= 80 {
            badgeTint = "red"
        } else if process.memoryBytes >= 314_572_800 || process.cpuPercent >= 30 {
            badgeTint = "amber"
        } else {
            badgeTint = "gray"
        }

        let summaryPath = process.commandLine.count > 96
            ? String(process.commandLine.prefix(96)) + "…"
            : process.commandLine
        let subtitle = "PID \(process.pid) · CPU \(process.formattedCPU) · \(summaryPath)"

        var actions: [PluginActionDTO] = [
            PluginActionDTO(
                id: "process.terminate",
                title: "结束进程",
                symbol: "xmark.circle",
                presentation: "keepPanelOpen",
                callback: true,
                payload: ["pid": String(process.pid), "name": process.name, "signal": "terminate"]
            ),
            PluginActionDTO(
                id: "process.forceKill",
                title: "强制结束 (SIGKILL)",
                symbol: "bolt.slash.circle",
                presentation: "keepPanelOpen",
                callback: true,
                payload: ["pid": String(process.pid), "name": process.name, "signal": "forceKill"]
            )
        ]

        if matchingNameCount > 1 {
            actions.append(PluginActionDTO(
                id: "process.killAll",
                title: "结束全部 \(matchingNameCount) 个「\(process.name)」",
                symbol: "xmark.circle.fill",
                presentation: "keepPanelOpen",
                callback: true,
                payload: ["name": process.name, "signal": "terminate"]
            ))
            actions.append(PluginActionDTO(
                id: "process.forceKillAll",
                title: "强制结束全部「\(process.name)」(SIGKILL)",
                symbol: "bolt.slash.fill",
                presentation: "keepPanelOpen",
                callback: true,
                payload: ["name": process.name, "signal": "forceKill"]
            ))
        }

        actions.append(PluginActionDTO(
            id: "process.copyPID",
            title: "复制 PID",
            symbol: "number",
            presentation: "dismissThenRun",
            effect: PluginActionEffectDTO(
                kind: "copy",
                value: String(process.pid),
                toast: "已复制 PID \(process.pid)",
                recordUsageKey: Self.entryCanonicalKey
            )
        ))

        actions.append(PluginActionDTO(
            id: "process.copyCommand",
            title: "复制启动命令",
            symbol: "doc.on.doc",
            presentation: "dismissThenRun",
            effect: PluginActionEffectDTO(
                kind: "copy",
                value: process.commandLine,
                toast: "已复制启动命令",
                recordUsageKey: Self.entryCanonicalKey
            )
        ))

        let revealPath = process.appBundlePath ?? process.executablePath
        if revealPath.hasPrefix("/") {
            actions.append(PluginActionDTO(
                id: "process.reveal",
                title: "在访达中显示",
                symbol: "folder",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "revealInFinder",
                    value: revealPath,
                    recordUsageKey: Self.entryCanonicalKey
                )
            ))
        }

        return PluginSearchItemDTO(
            title: process.name,
            subtitle: subtitle,
            score: score,
            canonicalKey: "process:\(process.pid)",
            icon: icon,
            badge: PluginBadgeDTO(text: badgeText, tint: badgeTint),
            actions: actions
        )
    }

    private func hintItem(title: String, subtitle: String) -> PluginSearchItemDTO {
        PluginSearchItemDTO(
            title: title,
            subtitle: subtitle,
            score: 1000,
            canonicalKey: "process:hint",
            icon: PluginIconDTO(kind: "symbol", value: "xmark.octagon", tint: "gray"),
            actions: [
                PluginActionDTO(
                    id: "process.hint",
                    title: "提示",
                    symbol: "info.circle",
                    presentation: "keepPanelOpen",
                    effect: PluginActionEffectDTO(kind: "toast", value: subtitle)
                )
            ]
        )
    }

    private func parsePortQuery(_ query: String) -> UInt16? {
        guard query.hasPrefix(":") else { return nil }
        let portString = String(query.dropFirst())
        guard !portString.isEmpty, portString.allSatisfy(\.isNumber),
              let port = UInt16(portString), port > 0 else {
            return nil
        }
        return port
    }
}

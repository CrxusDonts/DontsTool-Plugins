import DontsToolPluginSDK
import Foundation

public struct TerminalFinderEngine: PluginEngine {
    public static let entryCanonicalKey = "terminal-finder:entry"

    private let service: any TerminalFinderControlling

    public init(service: any TerminalFinderControlling = SystemTerminalFinderService()) {
        self.service = service
    }

    public func preferredTerminal(
        configuredBundleID: String?,
        frontmostBundleID: String?
    ) -> TerminalAppDescriptor? {
        let installed = service.installedTerminals()
        guard !installed.isEmpty else { return nil }

        let configured = configuredBundleID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !configured.isEmpty, let matched = installed.first(where: { $0.matches(bundleID: configured) }) {
            return matched
        }
        if let frontmostBundleID, let matched = installed.first(where: { $0.matches(bundleID: frontmostBundleID) }) {
            return matched
        }
        let running = service.runningTerminalBundleIDs()
        if let firstRunning = running.first,
           let matched = installed.first(where: { $0.matches(bundleID: firstRunning) }) {
            return matched
        }
        return installed.first
    }

    public func search(_ params: PluginSearchParams) async -> PluginSearchResultDTO {
        let argument = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredBundleID = params.hostContext?["preferredTerminalBundleID"]
            ?? params.preferences["preferredTerminalBundleID"]
        let installed = service.installedTerminals()
        let primaryTerminal = preferredTerminal(
            configuredBundleID: configuredBundleID,
            frontmostBundleID: params.frontmostBundleID
        )

        // Direct path argument, e.g. `tf ~/Desktop` or `tf /tmp`
        if let pathURL = parseDirectoryArgument(argument) {
            return PluginSearchResultDTO(items: [
                makeOpenPathItem(pathURL, primaryTerminal: primaryTerminal, installed: installed)
            ])
        }

        let frontmost = params.frontmostBundleID
        let isFromFinder = frontmost?.caseInsensitiveCompare(TerminalAppCatalog.finderBundleID) == .orderedSame
        let frontmostTerminal = frontmost.flatMap { id in installed.first(where: { $0.matches(bundleID: id) }) }

        var items: [PluginSearchItemDTO] = []

        // 1. Finder -> Terminal
        let finderToTerminalScore: Double = isFromFinder ? 3200 : (frontmostTerminal != nil ? 2000 : 3000)
        items.append(makeFinderToTerminalItem(
            primaryTerminal: primaryTerminal,
            installed: installed,
            score: finderToTerminalScore,
            isContextualPrimary: isFromFinder
        ))

        // 2. Terminal -> Finder
        let terminalToFinderScore: Double = frontmostTerminal != nil ? 3200 : (isFromFinder ? 2000 : 2900)
        items.append(makeTerminalToFinderItem(
            preferredTerminalBundleID: frontmostTerminal?.bundleID ?? primaryTerminal?.bundleID,
            terminalDisplayName: frontmostTerminal?.displayName,
            score: terminalToFinderScore,
            isContextualPrimary: frontmostTerminal != nil
        ))

        // 3. Copy Finder Path / Copy Terminal Path
        items.append(makeCopyFinderPathItem(score: isFromFinder ? 2600 : 2200))
        items.append(makeCopyTerminalPathItem(
            preferredTerminalBundleID: frontmostTerminal?.bundleID ?? primaryTerminal?.bundleID,
            terminalDisplayName: frontmostTerminal?.displayName,
            score: frontmostTerminal != nil ? 2600 : 2100
        ))

        // 4. Explicit per-terminal entries when user typed a terminal name (e.g. `tf warp`, `tf ghostty`).
        if !argument.isEmpty {
            for terminal in installed {
                if terminalMatches(terminal, query: argument), terminal.bundleID != primaryTerminal?.bundleID {
                    items.append(makeFinderToTerminalItem(
                        primaryTerminal: terminal,
                        installed: installed,
                        score: 3150,
                        isContextualPrimary: false
                    ))
                }
            }

            let filtered = items.filter { item in
                FuzzyMatcher.score(query: argument, candidate: item.title) != nil
                    || (item.subtitle.map { FuzzyMatcher.score(query: argument, candidate: $0) != nil } ?? false)
            }
            if !filtered.isEmpty {
                return PluginSearchResultDTO(items: filtered.sorted { ($0.score ?? 0) > ($1.score ?? 0) })
            }
            return PluginSearchResultDTO(items: [hintItem(
                title: "没有匹配的终端与访达操作",
                subtitle: "可输入访达、终端、复制、Ghostty / Warp / iTerm2，或直接输入目录路径如 ~/Desktop"
            )])
        }

        return PluginSearchResultDTO(items: items.sorted { ($0.score ?? 0) > ($1.score ?? 0) })
    }

    public func execute(_ params: PluginExecuteParams) async -> PluginExecuteResultDTO {
        if params.actionId == "tf.finderToTerminal.missing" {
            return PluginExecuteResultDTO(error: TerminalFinderError.terminalNotInstalled("终端").localizedDescription)
        }

        if params.actionId.hasPrefix("tf.finderToTerminal.") {
            let bundleID = params.payload["terminalBundleID"]
                ?? String(params.actionId.dropFirst("tf.finderToTerminal.".count))
            guard !bundleID.isEmpty else {
                return PluginExecuteResultDTO(error: "缺少目标终端标识")
            }
            do {
                let dir = try await service.currentFinderDirectory()
                try await service.openInTerminal(directory: dir, terminalBundleID: bundleID)
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }
        }

        if params.actionId == "tf.terminalToFinder" {
            let preferred = nonEmpty(params.payload["preferredBundleID"])
                ?? nonEmpty(params.hostContext?["preferredTerminalBundleID"])
            do {
                let dir = try await service.currentTerminalDirectory(preferredBundleID: preferred)
                try await service.openInFinder(directory: dir)
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }
        }

        if params.actionId == "tf.copyFinderPath" || params.actionId == "tf.copyFinderPath.primary" {
            do {
                let dir = try await service.currentFinderDirectory()
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "copy", value: dir.path),
                    toast: "已复制访达路径：\(dir.path)",
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }
        }

        if params.actionId == "tf.copyTerminalPath" || params.actionId == "tf.copyTerminalPath.primary" {
            let preferred = nonEmpty(params.payload["preferredBundleID"])
                ?? nonEmpty(params.hostContext?["preferredTerminalBundleID"])
            do {
                let dir = try await service.currentTerminalDirectory(preferredBundleID: preferred)
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "copy", value: dir.path),
                    toast: "已复制终端路径：\(dir.path)",
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }
        }

        if params.actionId == "tf.openPath.finder" {
            guard let rawDir = nonEmpty(params.payload["directory"]) else {
                return PluginExecuteResultDTO(error: "缺少目标目录路径")
            }
            let dir = URL(fileURLWithPath: rawDir).standardizedFileURL
            do {
                try await service.openInFinder(directory: dir)
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }
        }

        if params.actionId.hasPrefix("tf.openPath.") {
            guard let rawDir = nonEmpty(params.payload["directory"]) else {
                return PluginExecuteResultDTO(error: "缺少目标目录路径")
            }
            let bundleID = nonEmpty(params.payload["terminalBundleID"])
                ?? String(params.actionId.dropFirst("tf.openPath.".count))
            guard !bundleID.isEmpty else {
                return PluginExecuteResultDTO(error: "缺少目标终端标识")
            }
            let dir = URL(fileURLWithPath: rawDir).standardizedFileURL
            do {
                try await service.openInTerminal(directory: dir, terminalBundleID: bundleID)
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }
        }

        return PluginExecuteResultDTO(error: "未知操作：\(params.actionId)")
    }

    // MARK: - Item Builders

    private func makeFinderToTerminalItem(
        primaryTerminal: TerminalAppDescriptor?,
        installed: [TerminalAppDescriptor],
        score: Double,
        isContextualPrimary: Bool
    ) -> PluginSearchItemDTO {
        let targetName = primaryTerminal?.displayName ?? "终端"
        let icon: PluginIconDTO = primaryTerminal?.appPath.map { PluginIconDTO(kind: "application", value: $0) }
            ?? PluginIconDTO(kind: "symbol", value: "terminal", tint: "teal")

        var actions: [PluginActionDTO] = []
        if let primaryTerminal {
            actions.append(PluginActionDTO(
                id: "tf.finderToTerminal.\(primaryTerminal.bundleID)",
                title: "在 \(primaryTerminal.displayName) 中打开访达目录",
                symbol: "terminal",
                presentation: "openWindow",
                callback: true,
                payload: ["terminalBundleID": primaryTerminal.bundleID]
            ))
        } else {
            actions.append(PluginActionDTO(
                id: "tf.finderToTerminal.missing",
                title: "打开终端",
                symbol: "terminal",
                presentation: "keepPanelOpen",
                callback: true
            ))
        }

        for other in installed where other.bundleID != primaryTerminal?.bundleID {
            actions.append(PluginActionDTO(
                id: "tf.finderToTerminal.\(other.bundleID)",
                title: "改用 \(other.displayName) 打开",
                symbol: "terminal",
                presentation: "openWindow",
                callback: true,
                payload: ["terminalBundleID": other.bundleID]
            ))
        }

        actions.append(PluginActionDTO(
            id: "tf.copyFinderPath",
            title: "复制当前访达路径",
            symbol: "doc.on.doc",
            presentation: "dismissThenRun",
            callback: true
        ))

        return PluginSearchItemDTO(
            title: "在 \(targetName) 中打开当前访达目录",
            subtitle: installed.count > 1
                ? "访达 → \(targetName)（⌘K 可切换其他已安装终端）"
                : "访达 → \(targetName)（选中文件夹或当前窗口目录）",
            score: score,
            canonicalKey: "terminal-finder:finder-to-\(primaryTerminal?.bundleID ?? "default")",
            icon: icon,
            badge: isContextualPrimary
                ? PluginBadgeDTO(text: "当前访达", tint: "blue")
                : PluginBadgeDTO(text: "访达→终端", tint: "teal"),
            actions: actions
        )
    }

    private func makeTerminalToFinderItem(
        preferredTerminalBundleID: String?,
        terminalDisplayName: String?,
        score: Double,
        isContextualPrimary: Bool
    ) -> PluginSearchItemDTO {
        let label = terminalDisplayName ?? "终端"
        var payload: [String: String] = [:]
        if let preferredTerminalBundleID, !preferredTerminalBundleID.isEmpty {
            payload["preferredBundleID"] = preferredTerminalBundleID
        }

        let actions: [PluginActionDTO] = [
            PluginActionDTO(
                id: "tf.terminalToFinder",
                title: "在访达中打开\(label)目录",
                symbol: "folder",
                presentation: "openWindow",
                callback: true,
                payload: payload
            ),
            PluginActionDTO(
                id: "tf.copyTerminalPath",
                title: "复制\(label)当前路径",
                symbol: "doc.on.doc",
                presentation: "dismissThenRun",
                callback: true,
                payload: payload
            )
        ]

        return PluginSearchItemDTO(
            title: "在访达中打开\(label)当前目录",
            subtitle: "\(label) → 访达（自动识别活跃 Shell 工作目录）",
            score: score,
            canonicalKey: "terminal-finder:terminal-to-finder",
            icon: PluginIconDTO(kind: "symbol", value: "folder", tint: "blue"),
            badge: isContextualPrimary
                ? PluginBadgeDTO(text: "当前终端", tint: "teal")
                : PluginBadgeDTO(text: "终端→访达", tint: "blue"),
            actions: actions
        )
    }

    private func makeCopyFinderPathItem(score: Double) -> PluginSearchItemDTO {
        PluginSearchItemDTO(
            title: "复制当前访达路径",
            subtitle: "读取访达当前窗口或所选目录路径并复制到剪贴板",
            score: score,
            canonicalKey: "terminal-finder:copy-finder-path",
            icon: PluginIconDTO(kind: "symbol", value: "doc.on.doc", tint: "gray"),
            actions: [
                PluginActionDTO(
                    id: "tf.copyFinderPath.primary",
                    title: "复制路径",
                    symbol: "doc.on.doc",
                    presentation: "dismissThenRun",
                    callback: true
                )
            ]
        )
    }

    private func makeCopyTerminalPathItem(
        preferredTerminalBundleID: String?,
        terminalDisplayName: String?,
        score: Double
    ) -> PluginSearchItemDTO {
        let label = terminalDisplayName ?? "终端"
        var payload: [String: String] = [:]
        if let preferredTerminalBundleID, !preferredTerminalBundleID.isEmpty {
            payload["preferredBundleID"] = preferredTerminalBundleID
        }

        return PluginSearchItemDTO(
            title: "复制\(label)当前路径",
            subtitle: "读取\(label)活跃 Shell 工作目录并复制到剪贴板",
            score: score,
            canonicalKey: "terminal-finder:copy-terminal-path",
            icon: PluginIconDTO(kind: "symbol", value: "doc.on.doc", tint: "gray"),
            actions: [
                PluginActionDTO(
                    id: "tf.copyTerminalPath.primary",
                    title: "复制路径",
                    symbol: "doc.on.doc",
                    presentation: "dismissThenRun",
                    callback: true,
                    payload: payload
                )
            ]
        )
    }

    private func makeOpenPathItem(
        _ directory: URL,
        primaryTerminal: TerminalAppDescriptor?,
        installed: [TerminalAppDescriptor]
    ) -> PluginSearchItemDTO {
        let targetName = primaryTerminal?.displayName ?? "终端"
        let icon: PluginIconDTO = primaryTerminal?.appPath.map { PluginIconDTO(kind: "application", value: $0) }
            ?? PluginIconDTO(kind: "symbol", value: "terminal", tint: "teal")

        var actions: [PluginActionDTO] = []
        if let primaryTerminal {
            actions.append(PluginActionDTO(
                id: "tf.openPath.\(primaryTerminal.bundleID)",
                title: "在 \(primaryTerminal.displayName) 中打开",
                symbol: "terminal",
                presentation: "openWindow",
                callback: true,
                payload: [
                    "directory": directory.path,
                    "terminalBundleID": primaryTerminal.bundleID
                ]
            ))
        }
        for other in installed where other.bundleID != primaryTerminal?.bundleID {
            actions.append(PluginActionDTO(
                id: "tf.openPath.\(other.bundleID)",
                title: "改用 \(other.displayName) 打开",
                symbol: "terminal",
                presentation: "openWindow",
                callback: true,
                payload: [
                    "directory": directory.path,
                    "terminalBundleID": other.bundleID
                ]
            ))
        }
        actions.append(PluginActionDTO(
            id: "tf.openPath.finder",
            title: "在访达中打开",
            symbol: "folder",
            presentation: "openWindow",
            callback: true,
            payload: ["directory": directory.path]
        ))
        actions.append(PluginActionDTO(
            id: "tf.openPath.copy",
            title: "复制路径",
            symbol: "doc.on.doc",
            presentation: "dismissThenRun",
            effect: PluginActionEffectDTO(
                kind: "copy",
                value: directory.path,
                toast: "已复制路径：\(directory.path)",
                recordUsageKey: Self.entryCanonicalKey
            )
        ))

        return PluginSearchItemDTO(
            title: "在 \(targetName) 中打开 \(directory.lastPathComponent)",
            subtitle: directory.path,
            score: 3300,
            canonicalKey: "terminal-finder:path:\(directory.path)",
            icon: icon,
            badge: PluginBadgeDTO(text: "目录", tint: "teal"),
            actions: actions
        )
    }

    private func hintItem(title: String, subtitle: String) -> PluginSearchItemDTO {
        PluginSearchItemDTO(
            title: title,
            subtitle: subtitle,
            score: 1000,
            canonicalKey: "terminal-finder:hint",
            icon: PluginIconDTO(kind: "symbol", value: "terminal", tint: "gray"),
            actions: [
                PluginActionDTO(
                    id: "tf.hint",
                    title: "提示",
                    symbol: "info.circle",
                    presentation: "keepPanelOpen",
                    effect: PluginActionEffectDTO(kind: "toast", value: subtitle)
                )
            ]
        )
    }

    private func terminalMatches(_ terminal: TerminalAppDescriptor, query: String) -> Bool {
        if FuzzyMatcher.score(query: query, candidate: terminal.displayName) != nil { return true }
        return terminal.aliases.contains { FuzzyMatcher.score(query: query, candidate: $0) != nil }
    }

    private func parseDirectoryArgument(_ argument: String) -> URL? {
        guard argument.hasPrefix("/") || argument.hasPrefix("~") else { return nil }
        let expanded = (argument as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

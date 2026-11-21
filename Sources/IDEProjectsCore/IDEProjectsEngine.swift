import DontsToolPluginSDK
import Foundation

public actor IDEProjectsEngine: PluginEngine {
    public static let entryCanonicalKey = "idea-project:entry"

    private let discovery: any IDEProjectDiscovering
    private let launcher: any IDEProjectOpening
    private let extraApplications: [IDEApplicationCandidate]

    public init(
        discovery: any IDEProjectDiscovering = IDEProjectDiscovery(),
        launcher: any IDEProjectOpening = SystemIDEProjectLauncher(),
        extraApplications: [IDEApplicationCandidate] = []
    ) {
        self.discovery = discovery
        self.launcher = launcher
        self.extraApplications = extraApplications
    }

    public func search(_ params: PluginSearchParams) async -> PluginSearchResultDTO {
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let manual = query.hasPrefix("/") || query.hasPrefix("~") || query.contains("://")
        let result = await discovery.discover(
            applications: extraApplications,
            manualPath: manual ? query : nil
        )
        guard !Task.isCancelled else { return PluginSearchResultDTO(items: []) }

        guard let app = result.application else {
            let message = result.notice ?? "未找到 IntelliJ IDEA"
            return PluginSearchResultDTO(items: [hintItem(message)], notice: result.notice)
        }

        let scored = result.projects.enumerated().compactMap { offset, project -> (IDERecentProject, Double)? in
            if query.isEmpty || manual {
                return (project, 1500 - Double(offset))
            }
            guard let best = [project.name, project.url.lastPathComponent, project.url.path]
                .compactMap({ FuzzyMatcher.score(query: query, candidate: $0) })
                .max() else {
                return nil
            }
            let exact = project.name.compare(query, options: .caseInsensitive) == .orderedSame
                || project.url.lastPathComponent.compare(query, options: .caseInsensitive) == .orderedSame
            return (project, exact ? 3000 : min(best, 2500))
        }.sorted {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.lastOpenedTimestamp != $1.0.lastOpenedTimestamp {
                return $0.0.lastOpenedTimestamp > $1.0.lastOpenedTimestamp
            }
            return $0.0.url.path < $1.0.url.path
        }

        guard !scored.isEmpty else {
            let message = result.notice ?? (query.isEmpty
                ? "暂无可打开的最近项目；可输入完整项目目录"
                : "没有匹配的项目；可输入完整项目目录")
            return PluginSearchResultDTO(items: [hintItem(message)], notice: result.notice)
        }

        let items = scored.prefix(30).map { makeProjectItem($0.0, application: app, score: $0.1) }
        return PluginSearchResultDTO(items: items, notice: result.notice)
    }

    public func execute(_ params: PluginExecuteParams) async -> PluginExecuteResultDTO {
        switch params.actionId {
        case "idea.project.open":
            guard let projectPath = params.payload["projectPath"], !projectPath.isEmpty,
                  let applicationPath = params.payload["applicationPath"], !applicationPath.isEmpty else {
                return PluginExecuteResultDTO(error: "缺少项目路径或 IDEA 应用路径")
            }
            let projectURL = URL(fileURLWithPath: projectPath, isDirectory: true).standardizedFileURL
            let appURL = URL(fileURLWithPath: applicationPath).standardizedFileURL
            let isLocal = await discovery.isLocalDirectory(projectURL)
            guard isLocal else {
                return PluginExecuteResultDTO(error: "项目目录不存在或不是本地目录")
            }
            do {
                try await launcher.openProject(at: projectURL, using: appURL)
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    recordUsageKey: "idea-project:\(projectURL.path)"
                )
            } catch {
                return PluginExecuteResultDTO(error: "无法用 IDEA 打开项目：\(error.localizedDescription)")
            }

        default:
            return PluginExecuteResultDTO(error: "未知操作：\(params.actionId)")
        }
    }

    private func makeProjectItem(
        _ project: IDERecentProject,
        application: IDEApplication,
        score: Double
    ) -> PluginSearchItemDTO {
        let key = "idea-project:\(project.url.path)"
        let actions: [PluginActionDTO] = [
            PluginActionDTO(
                id: "idea.project.open",
                title: "用 IDEA 打开",
                symbol: "arrow.up.forward.app",
                presentation: "openWindow",
                callback: true,
                payload: [
                    "projectPath": project.url.path,
                    "applicationPath": application.url.path
                ]
            ),
            PluginActionDTO(
                id: "idea.project.reveal",
                title: "在访达中显示",
                symbol: "folder",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "revealInFinder",
                    value: project.url.path,
                    recordUsageKey: Self.entryCanonicalKey
                )
            ),
            PluginActionDTO(
                id: "idea.project.copyPath",
                title: "复制路径",
                symbol: "doc.on.doc",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "copy",
                    value: project.url.path,
                    toast: "已复制路径",
                    recordUsageKey: Self.entryCanonicalKey
                )
            ),
            PluginActionDTO(
                id: "idea.project.openInTerminal",
                title: "在终端中打开",
                symbol: "terminal",
                presentation: "openWindow",
                effect: PluginActionEffectDTO(
                    kind: "openInTerminal",
                    value: project.url.path,
                    recordUsageKey: Self.entryCanonicalKey
                )
            )
        ]

        return PluginSearchItemDTO(
            title: project.name,
            subtitle: "\(project.url.path) · \(application.name) \(application.version)",
            score: score,
            canonicalKey: key,
            icon: PluginIconDTO(kind: "application", value: application.url.path),
            actions: actions
        )
    }

    private func hintItem(_ message: String) -> PluginSearchItemDTO {
        PluginSearchItemDTO(
            title: "IDEA 项目",
            subtitle: message,
            score: 1000,
            canonicalKey: "idea-project:hint",
            keyword: "idea",
            icon: PluginIconDTO(kind: "symbol", value: "folder", tint: "purple"),
            actions: [
                PluginActionDTO(
                    id: "idea.project.hint",
                    title: "提示",
                    symbol: "info.circle",
                    presentation: "keepPanelOpen",
                    effect: PluginActionEffectDTO(kind: "toast", value: message)
                )
            ]
        )
    }
}

import DontsToolPluginSDK
import Foundation

public struct FileSearchEngine: PluginEngine {
    private let service: FileSearchService
    private let timeout: Duration

    public init(
        service: FileSearchService = FileSearchService(),
        timeout: Duration = .milliseconds(1800)
    ) {
        self.service = service
        self.timeout = timeout
    }

    public func search(_ params: PluginSearchParams) async -> PluginSearchResultDTO {
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return PluginSearchResultDTO(items: [])
        }

        do {
            let result = try await service.search(query: query, timeout: timeout)
            guard !Task.isCancelled else { return PluginSearchResultDTO(items: []) }
            let notice: String? = if result.timedOut {
                result.hits.isEmpty ? "文件搜索超时" : "文件搜索较慢，已显示部分结果"
            } else {
                nil
            }
            return PluginSearchResultDTO(
                items: result.hits.map(makeItem),
                notice: notice
            )
        } catch is CancellationError {
            return PluginSearchResultDTO(items: [])
        } catch {
            guard !Task.isCancelled else { return PluginSearchResultDTO(items: []) }
            return PluginSearchResultDTO(items: [], notice: "文件搜索不可用")
        }
    }

    private func makeItem(_ hit: FileSearchHit) -> PluginSearchItemDTO {
        let path = hit.url.path
        let fileName = hit.url.lastPathComponent
        let actions: [PluginActionDTO] = [
            PluginActionDTO(
                id: "file.open",
                title: "打开",
                symbol: "arrow.up.forward.app",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "openFile",
                    value: path,
                    recordUsageKey: path
                )
            ),
            PluginActionDTO(
                id: "file.reveal",
                title: "在访达中显示",
                symbol: "folder",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "revealInFinder",
                    value: path
                ),
                fileAction: "reveal"
            ),
            PluginActionDTO(
                id: "file.copyPath",
                title: "复制路径",
                symbol: "doc.on.doc",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "copy",
                    value: path,
                    toast: "已复制 \(fileName) 的路径"
                ),
                fileAction: "copyPath"
            ),
            PluginActionDTO(
                id: "file.openInTerminal",
                title: "在终端中打开",
                symbol: "terminal",
                presentation: "openWindow",
                effect: PluginActionEffectDTO(
                    kind: "openInTerminal",
                    value: path
                )
            )
        ]

        return PluginSearchItemDTO(
            title: fileName,
            subtitle: PathDisplay.parentDirectory(of: hit.url),
            score: hit.score,
            canonicalKey: path,
            group: "file",
            icon: PluginIconDTO(kind: "file", value: path),
            actions: actions
        )
    }
}

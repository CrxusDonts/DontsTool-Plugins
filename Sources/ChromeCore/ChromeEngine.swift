import DontsToolPluginSDK
import Foundation

public actor ChromeEngine: PluginEngine {
    public static let entryCanonicalKey = "chrome:entry"

    private static let tabKeywords: Set<String> = ["tab", "tabs", "标签页"]
    private static let bookmarkKeywords: Set<String> = ["bm", "书签"]

    private let service: any ChromeControlling
    private let tabCacheTTL: TimeInterval
    private let nowProvider: @Sendable () -> Date

    private var cachedTabs: [ChromeTab] = []
    private var tabCacheTimestamp: Date = .distantPast
    private var cachedTabNotice: String?

    public init(
        service: any ChromeControlling = SystemChromeService(),
        tabCacheTTL: TimeInterval = 1.5,
        nowProvider: @escaping @Sendable () -> Date = Date.init
    ) {
        self.service = service
        self.tabCacheTTL = tabCacheTTL
        self.nowProvider = nowProvider
    }

    public func invalidateTabCache() {
        tabCacheTimestamp = .distantPast
        cachedTabs = []
        cachedTabNotice = nil
    }

    public func search(_ params: PluginSearchParams) async -> PluginSearchResultDTO {
        let normalizedKeyword = params.keyword?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "chrome"
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.tabKeywords.contains(normalizedKeyword) {
            return await searchTabsOnly(query: query)
        }
        if Self.bookmarkKeywords.contains(normalizedKeyword) {
            return await searchBookmarksOnly(query: query)
        }
        return await searchUnified(query: query)
    }

    public func execute(_ params: PluginExecuteParams) async -> PluginExecuteResultDTO {
        switch params.actionId {
        case "chrome.tab.switch":
            guard let wText = params.payload["windowIndex"], let w = Int(wText),
                  let tText = params.payload["tabIndex"], let t = Int(tText) else {
                return PluginExecuteResultDTO(error: "无效的标签页索引")
            }
            do {
                try await service.switchToTab(windowIndex: w, tabIndex: t)
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }

        case "chrome.tab.close":
            guard let wText = params.payload["windowIndex"], let w = Int(wText),
                  let tText = params.payload["tabIndex"], let t = Int(tText) else {
                return PluginExecuteResultDTO(error: "无效的标签页索引")
            }
            let title = params.payload["title"] ?? "标签页"
            do {
                try await service.closeTab(windowIndex: w, tabIndex: t)
                invalidateTabCache()
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    toast: "已关闭标签页：\(title)",
                    refresh: true,
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }

        case "chrome.open", "chrome.openIncognito":
            guard let urlString = params.payload["url"], let url = URL(string: urlString) else {
                return PluginExecuteResultDTO(error: ChromeControlError.invalidURL.localizedDescription)
            }
            let incognito = params.actionId == "chrome.openIncognito" || params.payload["incognito"] == "true"
            do {
                try await service.openURL(url, incognito: incognito)
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }

        case "chrome.newTab":
            do {
                try await service.openNewTab(incognito: false)
                invalidateTabCache()
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }

        case "chrome.newIncognito":
            do {
                try await service.openNewTab(incognito: true)
                return PluginExecuteResultDTO(
                    effect: PluginActionEffectDTO(kind: "none"),
                    recordUsageKey: Self.entryCanonicalKey
                )
            } catch {
                return PluginExecuteResultDTO(error: error.localizedDescription)
            }

        default:
            return PluginExecuteResultDTO(error: "未知操作：\(params.actionId)")
        }
    }

    // MARK: - Search Modes

    private func searchTabsOnly(query: String) async -> PluginSearchResultDTO {
        let (tabs, notice) = await fetchOpenTabs()
        guard !Task.isCancelled else { return PluginSearchResultDTO(items: []) }

        let matched = filterAndRankTabs(tabs, query: query)
        if matched.isEmpty {
            if let notice {
                return PluginSearchResultDTO(
                    items: [hintItem(title: "无法读取 Chrome 标签页", subtitle: notice)],
                    notice: notice
                )
            }
            return PluginSearchResultDTO(items: [hintItem(
                title: query.isEmpty ? "当前没有打开的 Chrome 标签页" : "没有匹配的 Chrome 标签页",
                subtitle: query.isEmpty ? "打开 Google Chrome 后可在此快速切换或关闭标签页" : "试试其他标题或域名关键词"
            )])
        }
        return PluginSearchResultDTO(
            items: matched.prefix(30).map { makeTabItem($0.tab, score: $0.score) },
            notice: notice
        )
    }

    private func searchBookmarksOnly(query: String) async -> PluginSearchResultDTO {
        let bookmarks = await service.loadBookmarks()
        guard !Task.isCancelled else { return PluginSearchResultDTO(items: []) }

        let matched = filterAndRankBookmarks(bookmarks, query: query)
        guard !matched.isEmpty else {
            return PluginSearchResultDTO(items: [hintItem(
                title: query.isEmpty ? "未找到 Chrome 书签" : "没有匹配的 Chrome 书签",
                subtitle: query.isEmpty ? "请确认已安装并使用过 Google Chrome" : "可按书签标题、目录名或网址筛选"
            )])
        }
        return PluginSearchResultDTO(items: matched.prefix(30).map { makeBookmarkItem($0.bookmark, score: $0.score) })
    }

    private func searchUnified(query: String) async -> PluginSearchResultDTO {
        let service = self.service
        async let bookmarksTask = service.loadBookmarks()
        async let historyTask = service.loadHistory(limit: 400)
        let (tabs, tabNotice) = await fetchOpenTabs()
        let bookmarks = await bookmarksTask
        let history = await historyTask
        guard !Task.isCancelled else { return PluginSearchResultDTO(items: []) }

        var items: [PluginSearchItemDTO] = []
        var seenURLs = Set<String>()

        let rankedTabs = filterAndRankTabs(tabs, query: query)
        for entry in rankedTabs.prefix(15) {
            seenURLs.insert(normalizedURLKey(entry.tab.url))
            items.append(makeTabItem(entry.tab, score: entry.score))
        }

        let rankedBookmarks = filterAndRankBookmarks(bookmarks, query: query)
        for entry in rankedBookmarks.prefix(15) {
            let key = normalizedURLKey(entry.bookmark.url)
            guard seenURLs.insert(key).inserted else { continue }
            items.append(makeBookmarkItem(entry.bookmark, score: entry.score))
        }

        let rankedHistory = filterAndRankHistory(history, query: query)
        for entry in rankedHistory.prefix(15) {
            let key = normalizedURLKey(entry.entry.url)
            guard seenURLs.insert(key).inserted else { continue }
            items.append(makeHistoryItem(entry.entry, score: entry.score))
        }

        items.append(contentsOf: quickCommandItems(matching: query))

        if items.isEmpty {
            return PluginSearchResultDTO(
                items: [hintItem(
                    title: "没有匹配的 Chrome 内容",
                    subtitle: "支持搜索已打开标签页、书签与历史记录，或输入 new / 无痕 新建窗口"
                )],
                notice: tabNotice
            )
        }

        let sorted = items.sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        return PluginSearchResultDTO(items: Array(sorted.prefix(30)), notice: tabNotice)
    }

    private func fetchOpenTabs() async -> ([ChromeTab], String?) {
        let now = nowProvider()
        if now.timeIntervalSince(tabCacheTimestamp) < tabCacheTTL {
            return (cachedTabs, cachedTabNotice)
        }
        do {
            let tabs = try await service.listOpenTabs()
            guard !Task.isCancelled else { return ([], nil) }
            cachedTabs = tabs
            cachedTabNotice = nil
            tabCacheTimestamp = nowProvider()
            return (tabs, nil)
        } catch {
            guard !Task.isCancelled else { return ([], nil) }
            cachedTabs = []
            cachedTabNotice = error.localizedDescription
            tabCacheTimestamp = nowProvider()
            return ([], error.localizedDescription)
        }
    }

    // MARK: - Ranking

    private func filterAndRankTabs(_ tabs: [ChromeTab], query: String) -> [(tab: ChromeTab, score: Double)] {
        if query.isEmpty {
            return tabs.enumerated().map { offset, tab in
                let activeBonus = tab.isActive ? 50.0 : 0.0
                return (tab, 3200 + activeBonus - Double(offset))
            }
        }
        let lower = query.lowercased()
        return tabs.compactMap { tab in
            if let titleScore = FuzzyMatcher.score(query: query, candidate: tab.title) {
                return (tab, 3200 + min(titleScore, 600))
            }
            if tab.url.lowercased().contains(lower) {
                return (tab, 3050)
            }
            return nil
        }.sorted { $0.score > $1.score }
    }

    private func filterAndRankBookmarks(_ bookmarks: [ChromeBookmark], query: String) -> [(bookmark: ChromeBookmark, score: Double)] {
        if query.isEmpty {
            return bookmarks.enumerated().map { offset, bookmark in
                (bookmark, 2200 - Double(offset) * 0.1)
            }
        }
        let lower = query.lowercased()
        return bookmarks.compactMap { bookmark in
            if let titleScore = FuzzyMatcher.score(query: query, candidate: bookmark.title) {
                return (bookmark, 2200 + min(titleScore, 600))
            }
            if bookmark.url.lowercased().contains(lower) {
                return (bookmark, 2050)
            }
            if !bookmark.folderPath.isEmpty, FuzzyMatcher.score(query: query, candidate: bookmark.folderPath) != nil {
                return (bookmark, 1950)
            }
            return nil
        }.sorted { $0.score > $1.score }
    }

    private func filterAndRankHistory(_ entries: [ChromeHistoryEntry], query: String) -> [(entry: ChromeHistoryEntry, score: Double)] {
        if query.isEmpty {
            return entries.enumerated().map { offset, entry in
                (entry, 1400 - Double(offset) * 0.1)
            }
        }
        let lower = query.lowercased()
        return entries.compactMap { entry in
            let visitBonus = min(Double(entry.visitCount) * 2.0, 100.0)
            if let titleScore = FuzzyMatcher.score(query: query, candidate: entry.title) {
                return (entry, 1400 + min(titleScore, 500) + visitBonus)
            }
            if entry.url.lowercased().contains(lower) {
                return (entry, 1250 + visitBonus)
            }
            return nil
        }.sorted { $0.score > $1.score }
    }

    // MARK: - Item Construction

    private var chromeIcon: PluginIconDTO {
        if let appPath = service.applicationPath {
            return PluginIconDTO(kind: "application", value: appPath)
        }
        return PluginIconDTO(kind: "symbol", value: "globe", tint: "blue")
    }

    private func makeTabItem(_ tab: ChromeTab, score: Double) -> PluginSearchItemDTO {
        var actions: [PluginActionDTO] = [
            PluginActionDTO(
                id: "chrome.tab.switch",
                title: "切换到标签页",
                symbol: "arrow.uturn.forward",
                presentation: "openWindow",
                callback: true,
                payload: [
                    "windowIndex": String(tab.windowIndex),
                    "tabIndex": String(tab.tabIndex)
                ]
            ),
            PluginActionDTO(
                id: "chrome.tab.close",
                title: "关闭标签页",
                symbol: "xmark.circle",
                presentation: "keepPanelOpen",
                callback: true,
                payload: [
                    "windowIndex": String(tab.windowIndex),
                    "tabIndex": String(tab.tabIndex),
                    "title": tab.title
                ]
            )
        ]
        actions.append(contentsOf: copyActions(title: tab.title, url: tab.url))

        return PluginSearchItemDTO(
            title: tab.title,
            subtitle: tab.url,
            score: score,
            canonicalKey: "chrome:tab:\(tab.windowIndex):\(tab.tabIndex):\(normalizedURLKey(tab.url))",
            icon: chromeIcon,
            badge: PluginBadgeDTO(text: tab.isActive ? "当前标签" : "标签页", tint: "blue"),
            actions: actions
        )
    }

    private func makeBookmarkItem(_ bookmark: ChromeBookmark, score: Double) -> PluginSearchItemDTO {
        let subtitle = bookmark.folderPath.isEmpty ? bookmark.url : "\(bookmark.folderPath) · \(bookmark.url)"
        return PluginSearchItemDTO(
            title: bookmark.title,
            subtitle: subtitle,
            score: score,
            canonicalKey: "chrome:bookmark:\(bookmark.id)",
            icon: chromeIcon,
            badge: PluginBadgeDTO(text: "书签", tint: "amber"),
            actions: urlActions(title: bookmark.title, urlString: bookmark.url)
        )
    }

    private func makeHistoryItem(_ entry: ChromeHistoryEntry, score: Double) -> PluginSearchItemDTO {
        PluginSearchItemDTO(
            title: entry.title,
            subtitle: entry.url,
            score: score,
            canonicalKey: "chrome:history:\(normalizedURLKey(entry.url))",
            icon: chromeIcon,
            badge: PluginBadgeDTO(text: "历史", tint: "gray"),
            actions: urlActions(title: entry.title, urlString: entry.url)
        )
    }

    private func quickCommandItems(matching query: String) -> [PluginSearchItemDTO] {
        var result: [PluginSearchItemDTO] = []
        let newTabAliases = ["new", "new tab", "tab", "新建", "新标签页"]
        if query.isEmpty || newTabAliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) {
            result.append(PluginSearchItemDTO(
                title: "新建 Chrome 标签页",
                subtitle: "在 Google Chrome 中打开一个新的空白标签页",
                score: query.isEmpty ? 800 : 2500,
                canonicalKey: "chrome:action:new-tab",
                icon: chromeIcon,
                actions: [
                    PluginActionDTO(
                        id: "chrome.newTab",
                        title: "新建标签页",
                        symbol: "plus.square",
                        presentation: "openWindow",
                        callback: true
                    )
                ]
            ))
        }

        let incognitoAliases = ["incognito", "private", "new incognito", "无痕", "隐私窗口"]
        if query.isEmpty || incognitoAliases.contains(where: { FuzzyMatcher.score(query: query, candidate: $0) != nil }) {
            result.append(PluginSearchItemDTO(
                title: "新建 Chrome 无痕窗口",
                subtitle: "在 Google Chrome 中打开无痕浏览窗口",
                score: query.isEmpty ? 790 : 2550,
                canonicalKey: "chrome:action:incognito",
                icon: chromeIcon,
                actions: [
                    PluginActionDTO(
                        id: "chrome.newIncognito",
                        title: "新建无痕窗口",
                        symbol: "eye.slash",
                        presentation: "openWindow",
                        callback: true
                    )
                ]
            ))
        }
        return result
    }

    private func urlActions(title: String, urlString: String) -> [PluginActionDTO] {
        [
            PluginActionDTO(
                id: "chrome.open",
                title: "在 Chrome 中打开",
                symbol: "safari",
                presentation: "openWindow",
                callback: true,
                payload: ["url": urlString]
            ),
            PluginActionDTO(
                id: "chrome.copyURL",
                title: "复制网址",
                symbol: "link",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "copy",
                    value: urlString,
                    toast: "已复制网址",
                    recordUsageKey: Self.entryCanonicalKey
                )
            ),
            PluginActionDTO(
                id: "chrome.openIncognito",
                title: "在无痕窗口打开",
                symbol: "eye.slash",
                presentation: "openWindow",
                callback: true,
                payload: ["url": urlString, "incognito": "true"]
            ),
            PluginActionDTO(
                id: "chrome.copyMarkdown",
                title: "复制 Markdown 链接",
                symbol: "number",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "copy",
                    value: "[\(title)](\(urlString))",
                    toast: "已复制 Markdown 链接",
                    recordUsageKey: Self.entryCanonicalKey
                )
            )
        ]
    }

    private func copyActions(title: String, url: String) -> [PluginActionDTO] {
        [
            PluginActionDTO(
                id: "chrome.copyURL",
                title: "复制网址",
                symbol: "link",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "copy",
                    value: url,
                    toast: "已复制网址",
                    recordUsageKey: Self.entryCanonicalKey
                )
            ),
            PluginActionDTO(
                id: "chrome.copyMarkdown",
                title: "复制 Markdown 链接",
                symbol: "number",
                presentation: "dismissThenRun",
                effect: PluginActionEffectDTO(
                    kind: "copy",
                    value: "[\(title)](\(url))",
                    toast: "已复制 Markdown 链接",
                    recordUsageKey: Self.entryCanonicalKey
                )
            )
        ]
    }

    private func hintItem(title: String, subtitle: String) -> PluginSearchItemDTO {
        PluginSearchItemDTO(
            title: title,
            subtitle: subtitle,
            score: 1000,
            canonicalKey: "chrome:hint",
            icon: chromeIcon,
            actions: [
                PluginActionDTO(
                    id: "chrome.hint",
                    title: "提示",
                    symbol: "info.circle",
                    presentation: "keepPanelOpen",
                    effect: PluginActionEffectDTO(kind: "toast", value: subtitle)
                )
            ]
        )
    }

    private func normalizedURLKey(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
            .lowercased()
    }
}

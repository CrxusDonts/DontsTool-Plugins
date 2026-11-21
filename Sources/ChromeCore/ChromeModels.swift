import Foundation

public struct ChromeProfile: Equatable, Hashable, Sendable {
    public let directoryName: String
    public let displayName: String
    public let directoryURL: URL

    public init(directoryName: String, displayName: String, directoryURL: URL) {
        self.directoryName = directoryName
        self.displayName = displayName
        self.directoryURL = directoryURL
    }
}

public struct ChromeBookmark: Equatable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let url: String
    public let folderPath: String
    public let profileName: String

    public init(id: String, title: String, url: String, folderPath: String = "", profileName: String = "Default") {
        self.id = id
        self.title = title
        self.url = url
        self.folderPath = folderPath
        self.profileName = profileName
    }
}

public struct ChromeHistoryEntry: Equatable, Hashable, Sendable {
    public let title: String
    public let url: String
    public let visitCount: Int
    public let lastVisitedAt: Date
    public let profileName: String

    public init(title: String, url: String, visitCount: Int = 1, lastVisitedAt: Date = Date(), profileName: String = "Default") {
        self.title = title
        self.url = url
        self.visitCount = visitCount
        self.lastVisitedAt = lastVisitedAt
        self.profileName = profileName
    }
}

public struct ChromeTab: Equatable, Hashable, Sendable {
    public let windowIndex: Int
    public let tabIndex: Int
    public let title: String
    public let url: String
    public let isActive: Bool

    public init(windowIndex: Int, tabIndex: Int, title: String, url: String, isActive: Bool = false) {
        self.windowIndex = windowIndex
        self.tabIndex = tabIndex
        self.title = title
        self.url = url
        self.isActive = isActive
    }
}

public enum ChromeControlError: LocalizedError, Equatable, Sendable {
    case notInstalled
    case notRunning
    case automationDenied
    case invalidURL
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            "未在本机找到 Google Chrome"
        case .notRunning:
            "Google Chrome 当前未运行"
        case .automationDenied:
            "读取或控制 Chrome 标签页需要「自动化」权限，请在系统设置 → 隐私与安全性 → 自动化中允许 DontsTool 控制 Google Chrome"
        case .invalidURL:
            "仅支持打开 HTTP/HTTPS 网址"
        case .actionFailed(let message):
            "Chrome 操作失败：\(message)"
        }
    }
}

public protocol ChromeControlling: Sendable {
    var applicationPath: String? { get }
    func loadBookmarks() async -> [ChromeBookmark]
    func loadHistory(limit: Int) async -> [ChromeHistoryEntry]
    func listOpenTabs() async throws -> [ChromeTab]
    func switchToTab(windowIndex: Int, tabIndex: Int) async throws
    func closeTab(windowIndex: Int, tabIndex: Int) async throws
    func openURL(_ url: URL, incognito: Bool) async throws
    func openNewTab(incognito: Bool) async throws
}

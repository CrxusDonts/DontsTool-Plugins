import Foundation

public struct IDERecentProject: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let lastOpenedTimestamp: Int64

    public init(url: URL, name: String, lastOpenedTimestamp: Int64 = 0) {
        self.url = url
        self.name = name
        self.lastOpenedTimestamp = lastOpenedTimestamp
    }
}

public struct IDEApplicationCandidate: Equatable, Sendable {
    public let url: URL
    public let bundleID: String?
    public let name: String

    public init(url: URL, bundleID: String?, name: String) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
    }
}

public struct IDEApplication: Equatable, Sendable {
    public let url: URL
    public let name: String
    public let version: String
    public let configurationPrefix: String

    public init(url: URL, name: String, version: String, configurationPrefix: String) {
        self.url = url
        self.name = name
        self.version = version
        self.configurationPrefix = configurationPrefix
    }
}

public struct IDEProjectDiscoveryResult: Equatable, Sendable {
    public let application: IDEApplication?
    public let projects: [IDERecentProject]
    public let notice: String?

    public init(application: IDEApplication?, projects: [IDERecentProject], notice: String?) {
        self.application = application
        self.projects = projects
        self.notice = notice
    }
}

public protocol IDEProjectDiscovering: Sendable {
    func discover(applications: [IDEApplicationCandidate], manualPath: String?) async -> IDEProjectDiscoveryResult
    func isLocalDirectory(_ url: URL) async -> Bool
}

public protocol IDEProjectOpening: Sendable {
    func openProject(at project: URL, using application: URL) async throws
}

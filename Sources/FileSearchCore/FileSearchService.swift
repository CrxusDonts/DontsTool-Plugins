import DontsToolPluginSDK
import Foundation

public struct FileSearchHit: Sendable, Equatable {
    public let url: URL
    public let score: Double

    public init(url: URL, score: Double) {
        self.url = url
        self.score = score
    }
}

public struct FileSearchResult: Sendable, Equatable {
    public let hits: [FileSearchHit]
    public let timedOut: Bool

    public init(hits: [FileSearchHit], timedOut: Bool) {
        self.hits = hits
        self.timedOut = timedOut
    }

    public var paths: [URL] {
        hits.map(\.url)
    }
}

public enum FileSearchError: LocalizedError, Equatable, Sendable {
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "文件搜索不可用"
        }
    }
}

public struct FileSearchService: Sendable {
    private let runner: any CommandRunning
    private let searchRoot: URL

    public init(
        runner: any CommandRunning = ProcessCommandRunner(),
        searchRoot: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.runner = runner
        self.searchRoot = searchRoot
    }

    public func search(query: String, timeout: Duration = .milliseconds(1800)) async throws -> FileSearchResult {
        try Task.checkCancellation()
        let result = try await runner.run(
            executable: "/usr/bin/mdfind",
            arguments: ["-name", query, "-onlyin", searchRoot.path],
            timeout: timeout,
            captureStderr: false
        )
        try Task.checkCancellation()

        if result.output.isEmpty && result.terminationStatus != 0 && !result.timedOut {
            throw FileSearchError.unavailable
        }

        let excludedPrefixes = ["/System/", "/Library/", "/private/", "/Users/Shared/"]
        var seen: Set<String> = []
        var hits: [FileSearchHit] = []

        for line in result.output.split(whereSeparator: \.isNewline) {
            let path = String(line)
            guard !path.isEmpty,
                  !excludedPrefixes.contains(where: { path.hasPrefix($0) }),
                  !path.hasSuffix(".app"),
                  !path.contains(".app/") else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.pathComponents.dropFirst().allSatisfy({ !$0.hasPrefix(".") }) else { continue }
            guard seen.insert(url.path).inserted else { continue }

            guard let score = FuzzyMatcher.score(query: query, candidate: url.lastPathComponent) else {
                continue
            }
            hits.append(FileSearchHit(url: url, score: score))
            if hits.count >= 200 { break }
        }

        let top = hits
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
            .prefix(12)

        return FileSearchResult(hits: Array(top), timedOut: result.timedOut)
    }
}

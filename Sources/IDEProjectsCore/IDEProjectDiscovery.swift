import AppKit
import Foundation

public actor IDEProjectDiscovery: IDEProjectDiscovering {
    private let homeDirectory: URL
    private let jetBrainsDirectory: URL
    private let applicationRoots: [URL]
    private let includeLaunchServices: Bool
    private var historyCache: [URL: HistorySnapshot] = [:]
    private var applicationCache: [URL: (FileStamp, IDEApplication)] = [:]

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        jetBrainsDirectory: URL? = nil,
        applicationRoots: [URL]? = nil,
        includeLaunchServices: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.jetBrainsDirectory = jetBrainsDirectory
            ?? homeDirectory.appendingPathComponent("Library/Application Support/JetBrains", isDirectory: true)
        self.applicationRoots = applicationRoots ?? [
            homeDirectory.appendingPathComponent("Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications/JetBrains Toolbox", isDirectory: true),
            URL(fileURLWithPath: "/Applications", isDirectory: true)
        ]
        self.includeLaunchServices = includeLaunchServices
    }

    public func discover(applications: [IDEApplicationCandidate], manualPath: String?) async -> IDEProjectDiscoveryResult {
        var allCandidates = applications

        if includeLaunchServices {
            let lsCandidates = await MainActor.run { Self.launchServicesCandidates() }
            allCandidates.append(contentsOf: lsCandidates)
        }

        let fallback = applicationRoots.flatMap { root in
            ["IntelliJ IDEA.app", "IntelliJ IDEA CE.app", "IntelliJ IDEA Community Edition.app", "IntelliJ IDEA Ultimate.app"].map {
                IDEApplicationCandidate(
                    url: root.appendingPathComponent($0),
                    bundleID: nil,
                    name: $0.replacingOccurrences(of: ".app", with: "")
                )
            }
        }
        allCandidates.append(contentsOf: fallback)

        var seenPaths: Set<String> = []
        var uniqueCandidates: [IDEApplicationCandidate] = []
        for candidate in allCandidates {
            let normalized = candidate.url.standardizedFileURL.path
            if seenPaths.insert(normalized).inserted {
                uniqueCandidates.append(candidate)
            }
        }

        let installed = uniqueCandidates.compactMap(application).sorted {
            let comparison = $0.version.compare($1.version, options: .numeric)
            if comparison != .orderedSame { return comparison == .orderedDescending }
            return $0.url.path < $1.url.path
        }

        guard let app = installed.first else {
            return IDEProjectDiscoveryResult(
                application: nil,
                projects: [],
                notice: "未找到 IntelliJ IDEA，请先安装"
            )
        }

        if let manualPath {
            guard let url = IDERecentProjectsParser.localURL(manualPath, homeDirectory: homeDirectory),
                  localDirectory(url) else {
                return IDEProjectDiscoveryResult(
                    application: app,
                    projects: [],
                    notice: "请输入已存在的本地项目目录；不支持远程路径"
                )
            }
            return IDEProjectDiscoveryResult(
                application: app,
                projects: [IDERecentProject(url: url, name: url.lastPathComponent)],
                notice: nil
            )
        }

        let history = jetBrainsDirectory
            .appendingPathComponent("\(app.configurationPrefix)\(app.version)/options/recentProjects.xml")
        let snapshot = readHistory(history)
        return IDEProjectDiscoveryResult(
            application: app,
            projects: snapshot.projects.filter { localDirectory($0.url) },
            notice: snapshot.notice
        )
    }

    public func isLocalDirectory(_ url: URL) async -> Bool {
        localDirectory(url)
    }

    @MainActor
    private static func launchServicesCandidates() -> [IDEApplicationCandidate] {
        let bundleIDs = ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"]
        var result: [IDEApplicationCandidate] = []
        for bundleID in bundleIDs {
            for url in NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID) {
                let name = url.deletingPathExtension().lastPathComponent
                result.append(IDEApplicationCandidate(url: url, bundleID: bundleID, name: name))
            }
        }
        return result
    }

    private func localDirectory(_ url: URL) -> Bool {
        guard url.isFileURL, url.host == nil || url.host == "", !url.path.hasPrefix("//") else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        let freshURL = URL(fileURLWithPath: url.path, isDirectory: true)
        guard let values = try? freshURL.resourceValues(forKeys: [.volumeIsLocalKey]) else { return false }
        return values.volumeIsLocal != false
    }

    private func application(_ candidate: IDEApplicationCandidate) -> IDEApplication? {
        let infoURL = candidate.url.appendingPathComponent("Contents/Info.plist")
        guard let stamp = FileStamp(infoURL),
              FileManager.default.fileExists(atPath: candidate.url.appendingPathComponent("Contents/MacOS/idea").path) else {
            return nil
        }
        if let cached = applicationCache[candidate.url], cached.0 == stamp {
            return cached.1
        }
        guard let data = try? Data(contentsOf: infoURL),
              data.count <= 1024 * 1024,
              let info = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              ["com.jetbrains.intellij", "com.jetbrains.intellij.ce"].contains(bundleID),
              let rawVersion = info["CFBundleShortVersionString"] as? String else {
            return nil
        }
        let parts = rawVersion.split(separator: ".")
        guard parts.count >= 2, Int(parts[0]) != nil, Int(parts[1]) != nil else { return nil }
        let displayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? candidate.name
        let app = IDEApplication(
            url: candidate.url.standardizedFileURL,
            name: displayName,
            version: "\(parts[0]).\(parts[1])",
            configurationPrefix: bundleID == "com.jetbrains.intellij.ce" ? "IdeaIC" : "IntelliJIdea"
        )
        applicationCache[candidate.url] = (stamp, app)
        return app
    }

    private func readHistory(_ url: URL) -> HistorySnapshot {
        let previous = historyCache[url]
        guard let stamp = FileStamp(url) else {
            return HistorySnapshot(
                stamp: nil,
                projects: [],
                notice: "当前 IDEA 版本还没有最近项目，可输入 idea 后加完整项目目录"
            )
        }
        if previous?.stamp == stamp {
            return previous!
        }
        do {
            guard stamp.size <= IDERecentProjectsParser.maximumDocumentSize else {
                throw HistoryError.invalidSnapshot
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: IDERecentProjectsParser.maximumDocumentSize + 1) ?? Data()
            guard FileStamp(url) == stamp else {
                throw HistoryError.invalidSnapshot
            }
            let projects = try IDERecentProjectsParser.parse(data, homeDirectory: homeDirectory)
            let snapshot = HistorySnapshot(stamp: stamp, projects: projects, notice: nil)
            historyCache[url] = snapshot
            return snapshot
        } catch {
            let snapshot = HistorySnapshot(
                stamp: stamp,
                projects: previous?.projects ?? [],
                notice: "IDEA 最近项目记录暂时无法读取，请稍后重试或输入完整项目目录"
            )
            historyCache[url] = snapshot
            return snapshot
        }
    }

    private struct HistorySnapshot {
        let stamp: FileStamp?
        let projects: [IDERecentProject]
        let notice: String?
    }

    private enum HistoryError: Error {
        case invalidSnapshot
    }

    private struct FileStamp: Equatable {
        let size: Int
        let modified: Date
        let inode: UInt64

        init?(_ url: URL) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let size = attributes[.size] as? NSNumber,
                  let modified = attributes[.modificationDate] as? Date,
                  let inode = attributes[.systemFileNumber] as? NSNumber else {
                return nil
            }
            self.size = size.intValue
            self.modified = modified
            self.inode = inode.uint64Value
        }
    }
}

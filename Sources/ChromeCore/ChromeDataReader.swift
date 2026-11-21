import Foundation
import SQLite3

public enum ChromeDataReader {
    private static let webKitEpochOffsetSeconds: Double = 11_644_473_600.0
    private static let skippedProfileDirectories: Set<String> = [
        "Guest Profile",
        "System Profile",
        "Snapshots"
    ]

    public static var defaultChromeSupportURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true)
    }

    public static func discoverProfiles(in rootURL: URL) -> [ChromeProfile] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        var displayNamesByDir: [String: String] = [:]
        let localStateURL = rootURL.appendingPathComponent("Local State")
        if let data = try? Data(contentsOf: localStateURL),
           let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let profile = root["profile"] as? [String: Any],
           let infoCache = profile["info_cache"] as? [String: Any] {
            for (dirName, rawMeta) in infoCache {
                guard !skippedProfileDirectories.contains(dirName),
                      let meta = rawMeta as? [String: Any] else { continue }
                let name = (meta["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                displayNamesByDir[dirName] = (name?.isEmpty == false ? name! : dirName)
            }
        }

        let children = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        var profiles: [ChromeProfile] = []
        for child in children {
            let dirName = child.lastPathComponent
            guard !skippedProfileDirectories.contains(dirName) else { continue }
            guard (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let hasBookmarks = fileManager.fileExists(atPath: child.appendingPathComponent("Bookmarks").path)
            let hasHistory = fileManager.fileExists(atPath: child.appendingPathComponent("History").path)
            guard hasBookmarks || hasHistory else { continue }

            let displayName = displayNamesByDir[dirName] ?? dirName
            profiles.append(ChromeProfile(directoryName: dirName, displayName: displayName, directoryURL: child))
        }

        return profiles.sorted { lhs, rhs in
            if lhs.directoryName == "Default" { return true }
            if rhs.directoryName == "Default" { return false }
            return lhs.directoryName.localizedStandardCompare(rhs.directoryName) == .orderedAscending
        }
    }

    public static func loadBookmarks(in rootURL: URL = defaultChromeSupportURL) -> [ChromeBookmark] {
        let profiles = discoverProfiles(in: rootURL)
        var all: [ChromeBookmark] = []
        for profile in profiles {
            let fileURL = profile.directoryURL.appendingPathComponent("Bookmarks")
            guard let data = try? Data(contentsOf: fileURL) else { continue }
            all.append(contentsOf: parseBookmarksJSON(data, profileName: profile.displayName))
        }
        return all
    }

    public static func parseBookmarksJSON(_ data: Data, profileName: String) -> [ChromeBookmark] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let roots = root["roots"] as? [String: Any] else {
            return []
        }

        let orderedRoots: [(key: String, fallbackLabel: String)] = [
            ("bookmark_bar", "书签栏"),
            ("other", "其他书签"),
            ("synced", "移动书签")
        ]

        var results: [ChromeBookmark] = []
        for entry in orderedRoots {
            guard let node = roots[entry.key] as? [String: Any] else { continue }
            let rootName = (node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = (rootName?.isEmpty == false ? rootName! : entry.fallbackLabel)
            collectBookmarks(from: node, path: [label], profileName: profileName, depth: 0, into: &results)
        }
        return results
    }

    private static func collectBookmarks(
        from node: [String: Any],
        path: [String],
        profileName: String,
        depth: Int,
        into results: inout [ChromeBookmark]
    ) {
        guard depth <= 32 else { return }
        let nodeType = node["type"] as? String
        if nodeType == "url" {
            guard let rawURL = node["url"] as? String,
                  isAllowedWebURL(rawURL) else { return }
            let rawTitle = (node["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let title = rawTitle.isEmpty ? rawURL : rawTitle
            let id = (node["guid"] as? String) ?? (node["id"] as? String) ?? rawURL
            results.append(ChromeBookmark(
                id: "\(profileName):\(id)",
                title: title,
                url: rawURL,
                folderPath: path.joined(separator: " / "),
                profileName: profileName
            ))
            return
        }

        guard let children = node["children"] as? [[String: Any]] else { return }
        for child in children {
            if (child["type"] as? String) == "folder" {
                let folderName = (child["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let nextPath = folderName.isEmpty ? path : path + [folderName]
                collectBookmarks(from: child, path: nextPath, profileName: profileName, depth: depth + 1, into: &results)
            } else {
                collectBookmarks(from: child, path: path, profileName: profileName, depth: depth + 1, into: &results)
            }
        }
    }

    public static func loadHistory(in rootURL: URL = defaultChromeSupportURL, limit: Int = 400) -> [ChromeHistoryEntry] {
        guard limit > 0 else { return [] }
        let profiles = discoverProfiles(in: rootURL)
        var byURL: [String: ChromeHistoryEntry] = [:]

        for profile in profiles {
            let historyURL = profile.directoryURL.appendingPathComponent("History")
            let entries = readHistorySQLite(at: historyURL, profileName: profile.displayName, limit: limit)
            for entry in entries {
                if let existing = byURL[entry.url] {
                    if entry.lastVisitedAt > existing.lastVisitedAt {
                        byURL[entry.url] = entry
                    }
                } else {
                    byURL[entry.url] = entry
                }
            }
        }

        return Array(byURL.values.sorted { lhs, rhs in
            if lhs.lastVisitedAt != rhs.lastVisitedAt { return lhs.lastVisitedAt > rhs.lastVisitedAt }
            return lhs.visitCount > rhs.visitCount
        }.prefix(limit))
    }

    public static func readHistorySQLite(at historyURL: URL, profileName: String, limit: Int) -> [ChromeHistoryEntry] {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: historyURL.path) else { return [] }

        // Copy database (and WAL sidecars if present) so we never block or touch Chrome's live SQLite lock.
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("donts-chrome-hist-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return []
        }
        defer { try? fileManager.removeItem(at: tempDir) }

        let copiedDB = tempDir.appendingPathComponent("History")
        do {
            try fileManager.copyItem(at: historyURL, to: copiedDB)
        } catch {
            return []
        }
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: historyURL.path + suffix)
            if fileManager.fileExists(atPath: sidecar.path) {
                try? fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: copiedDB.path + suffix))
            }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copiedDB.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return []
        }
        defer { sqlite3_close(db) }

        let sql = """
        SELECT url, title, visit_count, last_visit_time
        FROM urls
        WHERE hidden = 0 AND (url LIKE 'http://%' OR url LIKE 'https://%')
        ORDER BY last_visit_time DESC
        LIMIT ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            return []
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int(statement, 1, Int32(min(max(1, limit), 2000)))

        var entries: [ChromeHistoryEntry] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let urlCString = sqlite3_column_text(statement, 0) else { continue }
            let url = String(cString: urlCString)
            guard isAllowedWebURL(url) else { continue }
            let rawTitle = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            let trimmedTitle = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let visitCount = Int(sqlite3_column_int(statement, 2))
            let lastVisitMicros = sqlite3_column_int64(statement, 3)
            let lastVisitedAt = chromeTimestampToDate(lastVisitMicros)
            entries.append(ChromeHistoryEntry(
                title: trimmedTitle.isEmpty ? url : trimmedTitle,
                url: url,
                visitCount: max(0, visitCount),
                lastVisitedAt: lastVisitedAt,
                profileName: profileName
            ))
        }
        return entries
    }

    public static func chromeTimestampToDate(_ microsecondsSince1601: Int64) -> Date {
        guard microsecondsSince1601 > 0 else { return .distantPast }
        let unixSeconds = (Double(microsecondsSince1601) / 1_000_000.0) - webKitEpochOffsetSeconds
        return Date(timeIntervalSince1970: unixSeconds)
    }

    public static func isAllowedWebURL(_ rawURL: String) -> Bool {
        guard let url = URL(string: rawURL),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }
}

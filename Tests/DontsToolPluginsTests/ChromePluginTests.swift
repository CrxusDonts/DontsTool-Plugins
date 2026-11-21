import ChromeCore
import DontsToolPluginSDK
import Foundation
import SQLite3
import XCTest

private actor MockChromeService: ChromeControlling {
    nonisolated let applicationPath: String? = "/Applications/Google Chrome.app"
    var bookmarks: [ChromeBookmark]
    var history: [ChromeHistoryEntry]
    var tabs: [ChromeTab]
    var listTabsCalls = 0
    var closedTabs: [(Int, Int)] = []
    var switchedTabs: [(Int, Int)] = []
    var openedURLs: [(URL, Bool)] = []

    init(bookmarks: [ChromeBookmark] = [], history: [ChromeHistoryEntry] = [], tabs: [ChromeTab] = []) {
        self.bookmarks = bookmarks
        self.history = history
        self.tabs = tabs
    }

    func loadBookmarks() async -> [ChromeBookmark] { bookmarks }
    func loadHistory(limit: Int) async -> [ChromeHistoryEntry] { Array(history.prefix(limit)) }

    func listOpenTabs() async throws -> [ChromeTab] {
        listTabsCalls += 1
        return tabs
    }

    func switchToTab(windowIndex: Int, tabIndex: Int) async throws {
        switchedTabs.append((windowIndex, tabIndex))
    }

    func closeTab(windowIndex: Int, tabIndex: Int) async throws {
        closedTabs.append((windowIndex, tabIndex))
    }

    func openURL(_ url: URL, incognito: Bool) async throws {
        openedURLs.append((url, incognito))
    }

    func openNewTab(incognito: Bool) async throws {}
}

final class ChromePluginTests: XCTestCase {
    func testParseBookmarksJSONAndHistorySQLite() throws {
        let json = """
        {
          "roots": {
            "bookmark_bar": {
              "name": "书签栏",
              "type": "folder",
              "children": [
                {
                  "type": "folder",
                  "name": "开发",
                  "children": [
                    {"type": "url", "id": "1", "name": "GitHub", "url": "https://github.com"},
                    {"type": "url", "id": "2", "name": "Bad", "url": "javascript:alert(1)"}
                  ]
                }
              ]
            }
          }
        }
        """
        let bookmarks = ChromeDataReader.parseBookmarksJSON(Data(json.utf8), profileName: "Default")
        XCTAssertEqual(bookmarks.count, 1)
        XCTAssertEqual(bookmarks[0].title, "GitHub")
        XCTAssertEqual(bookmarks[0].folderPath, "书签栏 / 开发")

        // Create temporary Chrome History SQLite DB
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("chrome-hist-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("History")
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        let sql = """
        CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
        INSERT INTO urls VALUES (1, 'https://swift.org', 'Swift.org', 12, 13380000000000000, 0);
        INSERT INTO urls VALUES (2, 'chrome://settings', 'Settings', 5, 13380000000000001, 0);
        INSERT INTO urls VALUES (3, 'https://hidden.example.com', 'Hidden', 1, 13380000000000002, 1);
        """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        let history = ChromeDataReader.readHistorySQLite(at: dbURL, profileName: "Default", limit: 20)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history[0].title, "Swift.org")
        XCTAssertEqual(history[0].visitCount, 12)
    }

    func testParseOpenTabsOutput() {
        let rs = String(UnicodeScalar(30))
        let fs = String(UnicodeScalar(31))
        let raw = "1\(fs)2\(fs)1\(fs)GitHub\(fs)https://github.com\(rs)1\(fs)3\(fs)0\(fs)Apple\(fs)https://apple.com"
        let tabs = SystemChromeService.parseOpenTabsOutput(raw)
        XCTAssertEqual(tabs.count, 2)
        XCTAssertTrue(tabs[0].isActive)
        XCTAssertEqual(tabs[0].windowIndex, 1)
        XCTAssertEqual(tabs[0].tabIndex, 2)
        XCTAssertFalse(tabs[1].isActive)
    }

    func testUnifiedSearchDeduplicationCachingAndCloseRefresh() async {
        let mock = MockChromeService(
            bookmarks: [
                ChromeBookmark(id: "b1", title: "GitHub", url: "https://github.com/", folderPath: "书签栏"),
                ChromeBookmark(id: "b2", title: "Swift Docs", url: "https://docs.swift.org", folderPath: "书签栏")
            ],
            history: [
                ChromeHistoryEntry(title: "Swift Forums", url: "https://forums.swift.org", visitCount: 5)
            ],
            tabs: [
                ChromeTab(windowIndex: 1, tabIndex: 1, title: "GitHub", url: "https://github.com", isActive: true)
            ]
        )
        let engine = ChromeEngine(service: mock, tabCacheTTL: 60)

        let unified = await engine.search(PluginSearchParams(keyword: "chrome", query: ""))
        // GitHub tab deduplicates GitHub bookmark with trailing slash
        XCTAssertEqual(unified.items.filter { $0.title == "GitHub" }.count, 1)
        XCTAssertEqual(unified.items.first?.badge?.text, "当前标签")

        let tabsOnly = await engine.search(PluginSearchParams(keyword: "tab", query: "git"))
        XCTAssertEqual(tabsOnly.items.count, 1)
        // Served from 1.5s/60s cache
        let listCalls = await mock.listTabsCalls
        XCTAssertEqual(listCalls, 1)

        let bmOnly = await engine.search(PluginSearchParams(keyword: "bm", query: "swift"))
        XCTAssertEqual(bmOnly.items.count, 1)
        XCTAssertEqual(bmOnly.items.first?.badge?.text, "书签")

        // Close tab returns refresh: true and invalidates cache
        let closeResult = await engine.execute(PluginExecuteParams(
            actionId: "chrome.tab.close",
            payload: ["windowIndex": "1", "tabIndex": "1", "title": "GitHub"]
        ))
        XCTAssertNil(closeResult.error)
        XCTAssertEqual(closeResult.refresh, true)
        XCTAssertEqual(closeResult.toast, "已关闭标签页：GitHub")

        _ = await engine.search(PluginSearchParams(keyword: "tab", query: ""))
        let listCallsAfterClose = await mock.listTabsCalls
        XCTAssertEqual(listCallsAfterClose, 2)
    }
}

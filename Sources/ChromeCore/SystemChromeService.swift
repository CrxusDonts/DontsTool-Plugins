import AppKit
import DontsToolPluginSDK
import Foundation
import os

public final class SystemChromeService: ChromeControlling, @unchecked Sendable {
    public static let bundleIdentifier = "com.google.Chrome"

    private let supportURL: URL
    private let runner: any CommandRunning
    private let cacheLock = OSAllocatedUnfairLock(initialState: CacheState())
    private let historyTTL: TimeInterval = 10

    private struct CacheState {
        var bookmarks: [ChromeBookmark] = []
        var bookmarksLoadedAt: Date = .distantPast
        var history: [ChromeHistoryEntry] = []
        var historyLoadedAt: Date = .distantPast
    }

    public init(
        supportURL: URL = ChromeDataReader.defaultChromeSupportURL,
        runner: any CommandRunning = ProcessCommandRunner()
    ) {
        self.supportURL = supportURL
        self.runner = runner
    }

    public var applicationPath: String? {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier) {
            return url.path
        }
        let fallback = "/Applications/Google Chrome.app"
        return FileManager.default.fileExists(atPath: fallback) ? fallback : nil
    }

    public func loadBookmarks() async -> [ChromeBookmark] {
        let now = Date()
        if let cached = cacheLock.withLock({ state -> [ChromeBookmark]? in
            guard !state.bookmarks.isEmpty, now.timeIntervalSince(state.bookmarksLoadedAt) < 8 else { return nil }
            return state.bookmarks
        }) {
            return cached
        }

        let root = supportURL
        let loaded = await Task.detached(priority: .userInitiated) {
            ChromeDataReader.loadBookmarks(in: root)
        }.value

        cacheLock.withLock {
            $0.bookmarks = loaded
            $0.bookmarksLoadedAt = Date()
        }
        return loaded
    }

    public func loadHistory(limit: Int = 400) async -> [ChromeHistoryEntry] {
        let now = Date()
        if let cached = cacheLock.withLock({ state -> [ChromeHistoryEntry]? in
            guard !state.history.isEmpty, now.timeIntervalSince(state.historyLoadedAt) < historyTTL else { return nil }
            return Array(state.history.prefix(limit))
        }) {
            return cached
        }

        let root = supportURL
        let loaded = await Task.detached(priority: .userInitiated) {
            ChromeDataReader.loadHistory(in: root, limit: max(limit, 400))
        }.value

        cacheLock.withLock {
            $0.history = loaded
            $0.historyLoadedAt = Date()
        }
        return Array(loaded.prefix(limit))
    }

    public func listOpenTabs() async throws -> [ChromeTab] {
        let isRunning = await MainActor.run {
            !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
        }
        guard isRunning else { return [] }

        let script = #"""
        set fieldSep to character id 31
        set recordSep to character id 30
        set outputLines to {}
        tell application id "com.google.Chrome"
            set winCount to count of windows
            repeat with w from 1 to winCount
                try
                    set activeIdx to active tab index of window w
                    set tabCount to count of tabs of window w
                    repeat with t from 1 to tabCount
                        set tabObj to tab t of window w
                        set tabTitle to title of tabObj
                        set tabURL to URL of tabObj
                        set isAct to "0"
                        if t is activeIdx and w is 1 then set isAct to "1"
                        set end of outputLines to (w as text) & fieldSep & (t as text) & fieldSep & isAct & fieldSep & tabTitle & fieldSep & tabURL
                    end repeat
                end try
            end repeat
        end tell
        set AppleScript's text item delimiters to recordSep
        return outputLines as text
        """#

        let output = try await runAppleScript(script, arguments: [], timeout: .milliseconds(1600))
        return Self.parseOpenTabsOutput(output)
    }

    public func switchToTab(windowIndex: Int, tabIndex: Int) async throws {
        guard windowIndex > 0, tabIndex > 0 else {
            throw ChromeControlError.actionFailed("无效的标签页索引")
        }
        let script = #"""
        on run argv
            set w to (item 1 of argv) as integer
            set t to (item 2 of argv) as integer
            tell application id "com.google.Chrome"
                activate
                if (count of windows) >= w then
                    set targetWin to window w
                    if (count of tabs of targetWin) >= t then
                        set active tab index of targetWin to t
                    end if
                    set index of targetWin to 1
                end if
            end tell
        end run
        """#
        _ = try await runAppleScript(script, arguments: [String(windowIndex), String(tabIndex)], timeout: .seconds(2))
    }

    public func closeTab(windowIndex: Int, tabIndex: Int) async throws {
        guard windowIndex > 0, tabIndex > 0 else {
            throw ChromeControlError.actionFailed("无效的标签页索引")
        }
        let script = #"""
        on run argv
            set w to (item 1 of argv) as integer
            set t to (item 2 of argv) as integer
            tell application id "com.google.Chrome"
                if (count of windows) >= w then
                    set targetWin to window w
                    if (count of tabs of targetWin) >= t then
                        close tab t of targetWin
                    end if
                end if
            end tell
        end run
        """#
        _ = try await runAppleScript(script, arguments: [String(windowIndex), String(tabIndex)], timeout: .seconds(2))
    }

    public func openURL(_ url: URL, incognito: Bool) async throws {
        guard ChromeDataReader.isAllowedWebURL(url.absoluteString) else {
            throw ChromeControlError.invalidURL
        }
        if incognito {
            let script = #"""
            on run argv
                set targetURL to item 1 of argv
                tell application id "com.google.Chrome"
                    activate
                    set newWin to make new window with properties {mode:"incognito"}
                    set URL of active tab of newWin to targetURL
                end tell
            end run
            """#
            _ = try await runAppleScript(script, arguments: [url.absoluteString], timeout: .seconds(3))
            return
        }

        if let chromePath = applicationPath {
            let appURL = URL(fileURLWithPath: chromePath)
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            _ = try await NSWorkspace.shared.open([url], withApplicationAt: appURL, configuration: config)
        } else {
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            if !opened {
                throw ChromeControlError.notInstalled
            }
        }
    }

    public func openNewTab(incognito: Bool) async throws {
        let script: String
        if incognito {
            script = #"""
            tell application id "com.google.Chrome"
                activate
                make new window with properties {mode:"incognito"}
            end tell
            """#
        } else {
            script = #"""
            tell application id "com.google.Chrome"
                activate
                if (count of windows) is 0 then
                    make new window
                else
                    make new tab at end of tabs of front window
                end if
            end tell
            """#
        }
        _ = try await runAppleScript(script, arguments: [], timeout: .seconds(3))
    }

    // MARK: - Parsing

    public static func parseOpenTabsOutput(_ output: String) -> [ChromeTab] {
        let trimmed = output.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else { return [] }
        let recordSep = Character(UnicodeScalar(30))
        let fieldSep = Character(UnicodeScalar(31))

        var tabs: [ChromeTab] = []
        for record in trimmed.split(separator: recordSep, omittingEmptySubsequences: true) {
            let fields = record.split(separator: fieldSep, maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5,
                  let windowIndex = Int(fields[0]),
                  let tabIndex = Int(fields[1]) else { continue }
            let isActive = fields[2] == "1"
            let rawTitle = String(fields[3]).trimmingCharacters(in: .whitespacesAndNewlines)
            let url = String(fields[4]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { continue }
            tabs.append(ChromeTab(
                windowIndex: windowIndex,
                tabIndex: tabIndex,
                title: rawTitle.isEmpty ? url : rawTitle,
                url: url,
                isActive: isActive
            ))
        }
        return tabs
    }

    // MARK: - AppleScript Execution

    private func runAppleScript(_ script: String, arguments: [String], timeout: Duration) async throws -> String {
        let result: CommandResult
        do {
            result = try await runner.run(
                executable: "/usr/bin/osascript",
                arguments: ["-e", script] + arguments,
                timeout: timeout,
                captureStderr: true
            )
        } catch {
            throw ChromeControlError.actionFailed(error.localizedDescription)
        }

        if result.timedOut {
            throw ChromeControlError.actionFailed("与 Google Chrome 通信超时")
        }
        if result.terminationStatus != 0 {
            let errText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if errText.contains("-1743") || errText.localizedCaseInsensitiveContains("not authorized") {
                throw ChromeControlError.automationDenied
            }
            if errText.contains("-600") || errText.localizedCaseInsensitiveContains("isn’t running") || errText.localizedCaseInsensitiveContains("isn't running") {
                throw ChromeControlError.notRunning
            }
            throw ChromeControlError.actionFailed(errText.isEmpty ? "exit \(result.terminationStatus)" : errText)
        }
        return result.output
    }
}

import DontsToolPluginSDK
import Foundation
import TerminalFinderCore
import XCTest

private final class MockTerminalFinderService: TerminalFinderControlling, @unchecked Sendable {
    let installed: [TerminalAppDescriptor]
    let running: [String]
    var finderDir = URL(fileURLWithPath: "/Users/tester/Desktop")
    var terminalDir = URL(fileURLWithPath: "/Users/tester/code/app")
    var openedTerminal: [(URL, String)] = []
    var openedFinder: [URL] = []

    init(installed: [TerminalAppDescriptor], running: [String] = []) {
        self.installed = installed
        self.running = running
    }

    func installedTerminals() -> [TerminalAppDescriptor] { installed }
    func runningTerminalBundleIDs() -> [String] { running }
    func currentFinderDirectory() async throws -> URL { finderDir }
    func currentTerminalDirectory(preferredBundleID: String?) async throws -> URL { terminalDir }
    func openInTerminal(directory: URL, terminalBundleID: String) async throws {
        openedTerminal.append((directory, terminalBundleID))
    }
    func openInFinder(directory: URL) async throws {
        openedFinder.append(directory)
    }
}

final class TerminalFinderPluginTests: XCTestCase {
    func testProcessSnapshotAndShellCandidateSelection() {
        let snapshot = """
          100     1 ??     Ss   /Applications/Ghostty.app/Contents/MacOS/ghostty
          101   100 s001   Ss   -zsh
          102   101 s001   S+   nvim
          200     1 s002   S+   zsh
        """
        let rows = SystemTerminalFinderService.parseProcessSnapshot(snapshot)
        XCTAssertEqual(rows.count, 4)

        let candidates = SystemTerminalFinderService.candidateShellPIDs(underRootPIDs: [100], rows: rows)
        XCTAssertEqual(candidates, [102, 101])

        let ttyCandidates = SystemTerminalFinderService.candidatePIDs(forTTY: "/dev/s001", rows: rows)
        XCTAssertEqual(ttyCandidates, [102, 101])
    }

    func testContextualRankingHostContextDirectPathAndExecute() async throws {
        let ghostty = TerminalAppCatalog.knownTerminals[0].withAppPath("/Applications/Ghostty.app")
        let warp = TerminalAppCatalog.knownTerminals[1].withAppPath("/Applications/Warp.app")
        let mock = MockTerminalFinderService(installed: [ghostty, warp], running: [ghostty.bundleID])
        let engine = TerminalFinderEngine(service: mock)

        // When Finder is frontmost and Warp is preferred via hostContext
        let finderSearch = await engine.search(PluginSearchParams(
            keyword: "tf",
            query: "",
            frontmostBundleID: TerminalAppCatalog.finderBundleID,
            hostContext: ["preferredTerminalBundleID": warp.bundleID]
        ))
        XCTAssertEqual(finderSearch.items.first?.badge?.text, "当前访达")
        XCTAssertTrue(finderSearch.items.first?.title.contains("Warp") == true)

        // When Ghostty is frontmost
        let termSearch = await engine.search(PluginSearchParams(
            keyword: "tf",
            query: "",
            frontmostBundleID: ghostty.bundleID,
            hostContext: ["preferredTerminalBundleID": warp.bundleID]
        ))
        XCTAssertEqual(termSearch.items.first?.badge?.text, "当前终端")
        XCTAssertTrue(termSearch.items.first?.title.contains("Ghostty") == true)

        // Direct path argument
        let directPath = await engine.search(PluginSearchParams(
            keyword: "tf",
            query: "/tmp",
            hostContext: ["preferredTerminalBundleID": ghostty.bundleID]
        ))
        XCTAssertEqual(directPath.items.count, 1)
        XCTAssertEqual(directPath.items.first?.badge?.text, "目录")
        XCTAssertEqual(directPath.items.first?.subtitle, "/tmp")

        // Execute Finder -> Terminal
        let f2t = await engine.execute(PluginExecuteParams(
            actionId: "tf.finderToTerminal.\(ghostty.bundleID)",
            payload: ["terminalBundleID": ghostty.bundleID]
        ))
        XCTAssertNil(f2t.error)
        XCTAssertEqual(mock.openedTerminal.first?.0.path, "/Users/tester/Desktop")
        XCTAssertEqual(mock.openedTerminal.first?.1, ghostty.bundleID)

        // Execute copyFinderPath returns copy effect
        let copyFinder = await engine.execute(PluginExecuteParams(actionId: "tf.copyFinderPath"))
        XCTAssertNil(copyFinder.error)
        XCTAssertEqual(copyFinder.effect?.kind, "copy")
        XCTAssertEqual(copyFinder.effect?.value, "/Users/tester/Desktop")

        // Execute Terminal -> Finder
        let t2f = await engine.execute(PluginExecuteParams(
            actionId: "tf.terminalToFinder",
            payload: ["preferredBundleID": ghostty.bundleID]
        ))
        XCTAssertNil(t2f.error)
        XCTAssertEqual(mock.openedFinder.first?.path, "/Users/tester/code/app")
    }
}

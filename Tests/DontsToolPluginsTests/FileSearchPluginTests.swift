import DontsToolPluginSDK
import FileSearchCore
import Foundation
import XCTest

private struct MockCommandRunner: CommandRunning {
    let result: CommandResult

    func run(
        executable: String,
        arguments: [String],
        timeout: Duration,
        captureStderr: Bool
    ) async throws -> CommandResult {
        result
    }
}

final class FileSearchPluginTests: XCTestCase {
    func testFileSearchFilteringRankingAndDTOFields() async throws {
        let output = """
        /Users/tester/Documents/report.pdf
        /Users/tester/Documents/report-final.pdf
        /Users/tester/.hidden/report.pdf
        /Applications/Report.app
        /System/Library/report.txt
        /Users/tester/Documents/report.pdf
        """
        let runner = MockCommandRunner(result: CommandResult(output: output, terminationStatus: 0, timedOut: false))
        let service = FileSearchService(runner: runner, searchRoot: URL(fileURLWithPath: "/Users/tester"))
        let engine = FileSearchEngine(service: service)

        let empty = await engine.search(PluginSearchParams(keyword: "file", query: "  "))
        XCTAssertTrue(empty.items.isEmpty)

        let res = await engine.search(PluginSearchParams(keyword: "file", query: "report"))
        XCTAssertNil(res.notice)
        XCTAssertEqual(res.items.count, 2)
        XCTAssertEqual(res.items[0].title, "report-final.pdf") // both prefix=900, localizedStandardCompare: report-final vs report.pdf -> "-" < "."
        for item in res.items {
            XCTAssertEqual(item.group, "file")
            XCTAssertEqual(item.icon?.kind, "file")
            XCTAssertEqual(item.actions.map(\.id), ["file.open", "file.reveal", "file.copyPath", "file.openInTerminal"])
            XCTAssertEqual(item.actions[0].effect?.kind, "openFile")
            XCTAssertEqual(item.actions[1].fileAction, "reveal")
            XCTAssertEqual(item.actions[1].effect?.kind, "revealInFinder")
            XCTAssertEqual(item.actions[2].fileAction, "copyPath")
            XCTAssertEqual(item.actions[2].effect?.kind, "copy")
            XCTAssertEqual(item.actions[3].effect?.kind, "openInTerminal")
        }
    }

    func testFileSearchTimeoutAndErrorNotices() async {
        let timeoutRunner = MockCommandRunner(result: CommandResult(output: "", terminationStatus: 15, timedOut: true))
        let timeoutEngine = FileSearchEngine(service: FileSearchService(runner: timeoutRunner))
        let timeoutRes = await timeoutEngine.search(PluginSearchParams(keyword: "file", query: "notes"))
        XCTAssertTrue(timeoutRes.items.isEmpty)
        XCTAssertEqual(timeoutRes.notice, "文件搜索超时")

        let partialRunner = MockCommandRunner(result: CommandResult(output: "/Users/tester/notes.md\n", terminationStatus: 15, timedOut: true))
        let partialEngine = FileSearchEngine(service: FileSearchService(runner: partialRunner))
        let partialRes = await partialEngine.search(PluginSearchParams(keyword: "file", query: "notes"))
        XCTAssertEqual(partialRes.items.count, 1)
        XCTAssertEqual(partialRes.notice, "文件搜索较慢，已显示部分结果")

        let failedRunner = MockCommandRunner(result: CommandResult(output: "", terminationStatus: 1, timedOut: false))
        let failedEngine = FileSearchEngine(service: FileSearchService(runner: failedRunner))
        let failedRes = await failedEngine.search(PluginSearchParams(keyword: "file", query: "notes"))
        XCTAssertTrue(failedRes.items.isEmpty)
        XCTAssertEqual(failedRes.notice, "文件搜索不可用")
    }
}

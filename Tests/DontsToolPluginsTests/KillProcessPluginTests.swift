import DontsToolPluginSDK
import Foundation
import KillProcessCore
import XCTest

private actor MockProcessService: ProcessControlling {
    var processes: [RunningProcess]
    var portPIDs: [UInt16: Set<Int32>]
    var listCallCount = 0
    var terminated: [(pid: Int32, signal: ProcessTerminationSignal)] = []
    var killAllCalls: [(name: String, signal: ProcessTerminationSignal)] = []
    var terminateError: (any Error)?

    init(processes: [RunningProcess] = [], portPIDs: [UInt16: Set<Int32>] = [:]) {
        self.processes = processes
        self.portPIDs = portPIDs
    }

    func listProcesses() async throws -> [RunningProcess] {
        listCallCount += 1
        return processes
    }

    func listeningPIDs(onPort port: UInt16) async throws -> Set<Int32> {
        portPIDs[port] ?? []
    }

    func terminate(pid: Int32, signal: ProcessTerminationSignal) async throws {
        if let terminateError { throw terminateError }
        terminated.append((pid, signal))
    }

    func killAll(named name: String, excludingPID: Int32, signal: ProcessTerminationSignal) async throws -> Int {
        killAllCalls.append((name, signal))
        return processes.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame && $0.pid != excludingPID }.count
    }
}

final class KillProcessPluginTests: XCTestCase {
    func testParsePSOutputExcludesProtectedAndMapsBundle() {
        let comm = """
          1     0   0   0.0   1000 /sbin/launchd
        100     1 501  12.5 102400 /Applications/Safari.app/Contents/MacOS/Safari
        200     1 501   1.0  20480 /usr/local/bin/node
        300     1 501   0.1  10240 /Applications/DontsTool.app/Contents/MacOS/DontsTool
        400     1   0   0.5  10240 /usr/sbin/syslogd
        """
        let args = """
        100 /Applications/Safari.app/Contents/MacOS/Safari
        200 /usr/local/bin/node server.js --port 3000
        """
        let apps: [Int32: RunningAppSnapshot] = [
            100: RunningAppSnapshot(pid: 100, localizedName: "Safari 浏览器", bundlePath: "/Applications/Safari.app", isRegularApp: true)
        ]

        let parsed = SystemProcessService.parsePSOutput(
            commOutput: comm,
            argsOutput: args,
            currentUID: 501,
            currentPID: 999,
            appsByPID: apps,
            excludedPIDs: [300]
        )

        XCTAssertEqual(parsed.count, 2)
        XCTAssertEqual(parsed[0].pid, 100)
        XCTAssertEqual(parsed[0].name, "Safari 浏览器")
        XCTAssertEqual(parsed[0].appBundlePath, "/Applications/Safari.app")
        XCTAssertEqual(parsed[1].pid, 200)
        XCTAssertEqual(parsed[1].commandLine, "/usr/local/bin/node server.js --port 3000")
    }

    func testParseLsofPIDs() {
        let output = "p1234\nf5\np5678\np1\n"
        XCTAssertEqual(SystemProcessService.parseLsofPIDs(output), [1234, 5678])
    }

    func testSearchRankingPortQueryCachingAndExecute() async {
        let processes = [
            RunningProcess(pid: 101, name: "node", executablePath: "/usr/local/bin/node", commandLine: "node app.js", cpuPercent: 2.0, memoryBytes: 200 * 1024 * 1024),
            RunningProcess(pid: 102, name: "node", executablePath: "/usr/local/bin/node", commandLine: "node worker.js", cpuPercent: 55.0, memoryBytes: 100 * 1024 * 1024),
            RunningProcess(pid: 205, name: "Safari", executablePath: "/Applications/Safari.app/Contents/MacOS/Safari", appBundlePath: "/Applications/Safari.app", cpuPercent: 1.0, memoryBytes: 1_200_000_000)
        ]
        let mock = MockProcessService(processes: processes, portPIDs: [3000: [101]])
        let engine = KillProcessEngine(service: mock, cacheTTL: 60)

        // Empty query puts CPU >= 25% hot process first
        let emptyResult = await engine.search(PluginSearchParams(keyword: "kill", query: ""))
        XCTAssertEqual(emptyResult.items.map(\.canonicalKey), ["process:102", "process:205", "process:101"])
        // Multiple "node" instances get killAll action
        let nodeActions = emptyResult.items.first?.actions.map(\.id) ?? []
        XCTAssertTrue(nodeActions.contains("process.killAll"))
        XCTAssertTrue(nodeActions.contains("process.forceKillAll"))

        // Second search within TTL uses cache
        _ = await engine.search(PluginSearchParams(keyword: "kill", query: "101"))
        let callsBeforeKill = await mock.listCallCount
        XCTAssertEqual(callsBeforeKill, 1)

        // Port query
        let portResult = await engine.search(PluginSearchParams(keyword: "kill", query: ":3000"))
        XCTAssertEqual(portResult.items.count, 1)
        XCTAssertEqual(portResult.items.first?.canonicalKey, "process:101")
        XCTAssertEqual(portResult.items.first?.badge?.tint, "blue")
        XCTAssertTrue(portResult.items.first?.badge?.text.hasPrefix(":3000") == true)

        // Execute terminate invalidates cache and sets refresh: true
        let execResult = await engine.execute(PluginExecuteParams(
            actionId: "process.terminate",
            payload: ["pid": "101", "name": "node", "signal": "terminate"]
        ))
        XCTAssertNil(execResult.error)
        XCTAssertEqual(execResult.refresh, true)
        XCTAssertEqual(execResult.toast, "已结束 node（PID 101）")

        let terminated = await mock.terminated
        XCTAssertEqual(terminated.first?.pid, 101)
        XCTAssertEqual(terminated.first?.signal, .terminate)
    }
}

import DontsToolPluginSDK
import Foundation
import XCTest

private actor StubEngine: PluginEngine {
    let delayMs: UInt64
    var searchCount = 0
    var executeCount = 0

    init(delayMs: UInt64 = 0) {
        self.delayMs = delayMs
    }

    func search(_ params: PluginSearchParams) async -> PluginSearchResultDTO {
        searchCount += 1
        if delayMs > 0 {
            try? await Task.sleep(for: .milliseconds(delayMs))
        }
        guard !Task.isCancelled else { return PluginSearchResultDTO(items: []) }
        return PluginSearchResultDTO(
            items: [
                PluginSearchItemDTO(
                    title: "Echo: \(params.query)",
                    subtitle: params.hostContext?["hostVersion"],
                    score: 1000,
                    canonicalKey: "stub:\(params.query)",
                    group: "file",
                    actions: [
                        PluginActionDTO(
                            id: "stub.reveal",
                            title: "Reveal",
                            effect: PluginActionEffectDTO(kind: "openInTerminal", value: "/tmp"),
                            fileAction: "reveal"
                        )
                    ]
                )
            ]
        )
    }

    func execute(_ params: PluginExecuteParams) async -> PluginExecuteResultDTO {
        executeCount += 1
        return PluginExecuteResultDTO(
            effect: PluginActionEffectDTO(kind: "openApplication", value: "/Applications/Safari.app"),
            toast: "ok:\(params.actionId):\(params.hostContext?["hostVersion"] ?? "")"
        )
    }
}

final class SDKRuntimeTests: XCTestCase {
    func testProtocolDTOsRoundTripWithNewFields() throws {
        let searchJSON = """
        {"mode":"keyword","keyword":"tf","query":"warp","rawQuery":"tf warp","frontmostBundleID":"com.apple.finder","preferences":{"k":"v"},"hostContext":{"preferredTerminalBundleID":"com.mitchellh.ghostty","hostVersion":"0.2.14"}}
        """
        let decodedSearch = try JSONDecoder().decode(PluginSearchParams.self, from: Data(searchJSON.utf8))
        XCTAssertEqual(decodedSearch.mode, "keyword")
        XCTAssertEqual(decodedSearch.keyword, "tf")
        XCTAssertEqual(decodedSearch.query, "warp")
        XCTAssertEqual(decodedSearch.frontmostBundleID, "com.apple.finder")
        XCTAssertEqual(decodedSearch.preferences["k"], "v")
        XCTAssertEqual(decodedSearch.hostContext?["preferredTerminalBundleID"], "com.mitchellh.ghostty")
        XCTAssertEqual(decodedSearch.hostContext?["hostVersion"], "0.2.14")

        // Minimal payload without optional fields decodes cleanly
        let minimalJSON = """
        {"query":"hello"}
        """
        let minimal = try JSONDecoder().decode(PluginSearchParams.self, from: Data(minimalJSON.utf8))
        XCTAssertEqual(minimal.mode, "keyword")
        XCTAssertEqual(minimal.query, "hello")
        XCTAssertEqual(minimal.rawQuery, "hello")
        XCTAssertTrue(minimal.preferences.isEmpty)
        XCTAssertNil(minimal.hostContext)

        let executeJSON = """
        {"actionId":"test.run","payload":{"a":"1"},"hostContext":{"hostVersion":"0.2.14"}}
        """
        let decodedExec = try JSONDecoder().decode(PluginExecuteParams.self, from: Data(executeJSON.utf8))
        XCTAssertEqual(decodedExec.actionId, "test.run")
        XCTAssertEqual(decodedExec.payload["a"], "1")
        XCTAssertEqual(decodedExec.hostContext?["hostVersion"], "0.2.14")
    }

    func testSidecarSessionRoutesSearchExecuteCancelAndShutdown() async throws {
        let pipe = Pipe()
        let writer = StdoutWriter(outputHandle: pipe.fileHandleForWriting, flushCStdout: false)
        let engine = StubEngine()
        let session = SidecarSession(engine: engine, writer: writer)

        let searchReq = """
        {"jsonrpc":"2.0","id":1,"method":"search","params":{"mode":"keyword","keyword":"k","query":"abc","rawQuery":"k abc","preferences":{},"hostContext":{"hostVersion":"0.2.14"}}}
        """
        let execReq = """
        {"jsonrpc":"2.0","id":2,"method":"execute","params":{"actionId":"run","payload":{},"preferences":{},"hostContext":{"hostVersion":"0.2.14"}}}
        """
        let unknownReq = """
        {"jsonrpc":"2.0","id":3,"method":"bogus","params":{}}
        """
        let shutdownReq = """
        {"jsonrpc":"2.0","method":"shutdown","params":{}}
        """

        let stop1 = await session.handleLine(Data(searchReq.utf8))
        XCTAssertFalse(stop1)
        let stop2 = await session.handleLine(Data(execReq.utf8))
        XCTAssertFalse(stop2)
        let stop3 = await session.handleLine(Data(unknownReq.utf8))
        XCTAssertFalse(stop3)
        let stop4 = await session.handleLine(Data(shutdownReq.utf8))
        XCTAssertTrue(stop4)

        await session.drainActiveTasks()
        try pipe.fileHandleForWriting.close()

        let outputData = try pipe.fileHandleForReading.readToEnd() ?? Data()
        let lines = String(decoding: outputData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(lines.count, 3)

        var seenIDs: Set<Int> = []
        for line in lines {
            let env = try JSONDecoder().decode(PluginRPCEnvelope.self, from: Data(line.utf8))
            if let id = env.id {
                seenIDs.insert(id)
                if id == 1 {
                    let resp = try JSONDecoder().decode(PluginRPCResponse<PluginSearchResultDTO>.self, from: Data(line.utf8))
                    XCTAssertEqual(resp.result?.items.first?.title, "Echo: abc")
                    XCTAssertEqual(resp.result?.items.first?.group, "file")
                    XCTAssertEqual(resp.result?.items.first?.actions.first?.fileAction, "reveal")
                    XCTAssertEqual(resp.result?.items.first?.actions.first?.effect?.kind, "openInTerminal")
                } else if id == 2 {
                    let resp = try JSONDecoder().decode(PluginRPCResponse<PluginExecuteResultDTO>.self, from: Data(line.utf8))
                    XCTAssertEqual(resp.result?.toast, "ok:run:0.2.14")
                    XCTAssertEqual(resp.result?.effect?.kind, "openApplication")
                } else if id == 3 {
                    XCTAssertEqual(env.error?.code, -32601)
                }
            }
        }
        XCTAssertEqual(seenIDs, [1, 2, 3])
    }

    func testSidecarSessionCancelPreventsResponse() async throws {
        let pipe = Pipe()
        let writer = StdoutWriter(outputHandle: pipe.fileHandleForWriting, flushCStdout: false)
        let engine = StubEngine(delayMs: 300)
        let session = SidecarSession(engine: engine, writer: writer)

        let searchReq = """
        {"jsonrpc":"2.0","id":10,"method":"search","params":{"mode":"keyword","query":"slow","rawQuery":"slow","preferences":{}}}
        """
        let cancelNote = """
        {"jsonrpc":"2.0","method":"cancel","params":{"id":10}}
        """

        _ = await session.handleLine(Data(searchReq.utf8))
        _ = await session.handleLine(Data(cancelNote.utf8))
        await session.drainActiveTasks()
        try pipe.fileHandleForWriting.close()

        let outputData = try pipe.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertTrue(outputData.isEmpty)
    }

    func testFuzzyMatcherHierarchy() {
        let exact = FuzzyMatcher.score(query: "chrome", candidate: "Chrome")
        let prefix = FuzzyMatcher.score(query: "chr", candidate: "Chrome")
        let word = FuzzyMatcher.score(query: "code", candidate: "Visual Studio Code")
        let subseq = FuzzyMatcher.score(query: "vsc", candidate: "Visual Studio Code")
        let none = FuzzyMatcher.score(query: "xyz", candidate: "Chrome")

        XCTAssertEqual(exact, 1000)
        XCTAssertEqual(prefix, 900)
        XCTAssertEqual(word, 800)
        XCTAssertNotNil(subseq)
        XCTAssertNil(none)
    }

    func testProcessCommandRunnerSuccessAndTimeout() async throws {
        let runner = ProcessCommandRunner()
        let ok = try await runner.run(executable: "/bin/echo", arguments: ["hello"], timeout: .seconds(2))
        XCTAssertFalse(ok.timedOut)
        XCTAssertEqual(ok.terminationStatus, 0)
        XCTAssertEqual(ok.output.trimmingCharacters(in: .whitespacesAndNewlines), "hello")

        let timedOut = try await runner.run(executable: "/bin/sleep", arguments: ["2"], timeout: .milliseconds(150))
        XCTAssertTrue(timedOut.timedOut)

        // Verify Task cancellation terminates running child process cleanly
        let cancelTask = Task {
            try await runner.run(executable: "/bin/sleep", arguments: ["5"], timeout: .seconds(5))
        }
        try await Task.sleep(for: .milliseconds(50))
        cancelTask.cancel()
        do {
            _ = try await cancelTask.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }
    }

    func testAllPluginManifestsAreValidUserPlugins() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let pluginsDir = packageRoot.appendingPathComponent("plugins", isDirectory: true)
        let allowedPermissions: Set<String> = [
            "clipboard.write", "openURL", "openFile", "revealInFinder",
            "openTerminal", "openApplication", "prefill", "toast", "secrets", "refresh"
        ]
        let expectedIDs: Set<String> = [
            "com.donts.kill-process",
            "com.donts.idea-projects",
            "com.donts.file-search",
            "com.donts.chrome",
            "com.donts.terminal-finder",
            "com.example.hello-sidecar"
        ]

        let entries = try FileManager.default.contentsOfDirectory(at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey])
        var foundIDs: Set<String> = []
        for dir in entries {
            let manifestURL = dir.appendingPathComponent("manifest.json")
            guard FileManager.default.fileExists(atPath: manifestURL.path) else { continue }
            let data = try Data(contentsOf: manifestURL)
            let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
            let id = try XCTUnwrap(obj["id"] as? String)
            XCTAssertEqual(id, dir.lastPathComponent)
            foundIDs.insert(id)
            XCTAssertNil(obj["legacyProviderID"], "User plugin \(id) must not declare legacyProviderID")
            let runtime = try XCTUnwrap(obj["runtime"] as? [String: Any])
            let command = try XCTUnwrap(runtime["command"] as? [String])
            XCTAssertFalse(command.isEmpty)
            XCTAssertFalse(command[0].contains("$HOST_HELPERS"), "User plugin \(id) must not use $HOST_HELPERS")
            XCTAssertTrue(command[0].hasPrefix("bin/"), "User plugin \(id) should use relative bin/ command")
            let permissions = (obj["permissions"] as? [String]) ?? []
            for perm in permissions {
                XCTAssertTrue(allowedPermissions.contains(perm), "Unknown permission \(perm) in \(id)")
            }
        }
        XCTAssertEqual(foundIDs, expectedIDs)
    }
}

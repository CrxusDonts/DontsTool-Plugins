import DontsToolPluginSDK
import Foundation
import QuickAICore
import XCTest

final class QuickAIPluginTests: XCTestCase {
    private let configuredGeminiContext: [String: String] = [
        "hostVersion": "0.4.0",
        "aiConfigured": "true",
        "aiFormat": "gemini",
        "aiModel": "gemini-2.5-flash"
    ]

    private let unconfiguredContext: [String: String] = [
        "hostVersion": "0.4.0",
        "aiConfigured": "false",
        "aiFormat": "openai_responses"
    ]

    func testEmptyArgumentShowsNewChatAndFivePresets() async throws {
        let engine = QuickAIEngine()
        let result = await engine.search(PluginSearchParams(
            keyword: "ai",
            query: "   ",
            hostContext: configuredGeminiContext
        ))

        // 1 new chat + 5 presets
        XCTAssertEqual(result.items.count, 6)

        let first = try XCTUnwrap(result.items.first)
        XCTAssertEqual(first.title, "新建 AI 对话")
        XCTAssertEqual(first.subtitle, "使用 Gemini · gemini-2.5-flash 流式回答")
        XCTAssertEqual(first.badge?.text, "gemini-2.5-flash")
        let newChatAction = try XCTUnwrap(first.actions.first)
        XCTAssertEqual(newChatAction.presentation, "openWindow")
        XCTAssertEqual(newChatAction.callback, false)
        XCTAssertEqual(newChatAction.effect?.kind, "openAI")
        XCTAssertEqual(newChatAction.effect?.value, "")
        XCTAssertEqual(newChatAction.effect?.options?["title"], "AI 快问")
        XCTAssertEqual(newChatAction.effect?.options?["autoSend"], "false")
        XCTAssertNil(newChatAction.effect?.options?["systemPrompt"])

        let presetTitles = result.items.dropFirst().map(\.title)
        XCTAssertEqual(presetTitles, [
            "解释代码与概念",
            "排查报错原因",
            "润色与改写文字",
            "生成 Shell 命令 / 正则",
            "提炼要点与总结"
        ])

        // Verify each preset has primary openAI (autoSend=false) + secondary prefill
        let fixItem = result.items[2]
        XCTAssertEqual(fixItem.actions.count, 2)
        XCTAssertEqual(fixItem.actions[0].presentation, "openWindow")
        XCTAssertEqual(fixItem.actions[0].callback, false)
        XCTAssertEqual(fixItem.actions[0].effect?.kind, "openAI")
        XCTAssertEqual(fixItem.actions[0].effect?.options?["title"], "排查报错")
        XCTAssertEqual(fixItem.actions[0].effect?.options?["autoSend"], "false")
        XCTAssertNotNil(fixItem.actions[0].effect?.options?["systemPrompt"])

        XCTAssertEqual(fixItem.actions[1].presentation, "keepPanelOpen")
        XCTAssertEqual(fixItem.actions[1].callback, false)
        XCTAssertEqual(fixItem.actions[1].effect?.kind, "prefill")
        XCTAssertEqual(fixItem.actions[1].effect?.value, "ai fix ")
    }

    func testHostContextConfiguredAndUnconfiguredSubtitles() async throws {
        let engine = QuickAIEngine()

        let unconfigured = await engine.search(PluginSearchParams(
            keyword: "ai",
            query: "",
            hostContext: unconfiguredContext
        ))
        let unconfFirst = try XCTUnwrap(unconfigured.items.first)
        XCTAssertEqual(unconfFirst.subtitle, "尚未配置大模型，回车打开窗口前往「设置 → AI 与翻译」")
        XCTAssertEqual(unconfFirst.badge?.text, "未配置")
        XCTAssertEqual(unconfFirst.badge?.tint, "amber")

        let openAIResponses = await engine.search(PluginSearchParams(
            keyword: "ai",
            query: "hello",
            hostContext: [
                "aiConfigured": "true",
                "aiFormat": "openai_responses",
                "aiModel": "gpt-4.1-mini"
            ]
        ))
        XCTAssertEqual(openAIResponses.items.first?.subtitle, "使用 OpenAI Responses · gpt-4.1-mini 流式回答")

        let openAIChat = await engine.search(PluginSearchParams(
            keyword: "ai",
            query: "hello",
            hostContext: [
                "aiConfigured": "true",
                "aiFormat": "openai_chat",
                "aiModel": "deepseek-chat"
            ]
        ))
        XCTAssertEqual(openAIChat.items.first?.subtitle, "使用 OpenAI Chat · deepseek-chat 流式回答")
    }

    func testPresetPrefixRoutingWithBodyAndFallback() async throws {
        let engine = QuickAIEngine()

        let fixResult = await engine.search(PluginSearchParams(
            keyword: "ai",
            query: "fix Cannot find 'Foo' in scope",
            hostContext: configuredGeminiContext
        ))
        XCTAssertEqual(fixResult.items.count, 2)

        let top = fixResult.items[0]
        XCTAssertEqual(top.title, "排查报错：Cannot find 'Foo' in scope")
        XCTAssertEqual(top.actions[0].presentation, "openWindow")
        XCTAssertEqual(top.actions[0].callback, false)
        XCTAssertEqual(top.actions[0].effect?.kind, "openAI")
        XCTAssertEqual(top.actions[0].effect?.value, "Cannot find 'Foo' in scope")
        XCTAssertEqual(top.actions[0].effect?.options?["title"], "排查报错")
        XCTAssertEqual(top.actions[0].effect?.options?["autoSend"], "true")
        XCTAssertTrue(top.actions[0].effect?.options?["systemPrompt"]?.isEmpty == false)
        XCTAssertEqual(top.actions[1].effect?.options?["autoSend"], "false")

        let fallback = fixResult.items[1]
        XCTAssertEqual(fallback.title, "直接问 AI：fix Cannot find 'Foo' in scope")
        XCTAssertEqual(fallback.actions[0].effect?.kind, "openAI")
        XCTAssertEqual(fallback.actions[0].effect?.value, "fix Cannot find 'Foo' in scope")
        XCTAssertEqual(fallback.actions[0].effect?.options?["autoSend"], "true")

        // Chinese trigger prefix works too
        let chineseResult = await engine.search(PluginSearchParams(
            keyword: "问",
            query: "解释 Swift Actor 重入",
            hostContext: configuredGeminiContext
        ))
        XCTAssertEqual(chineseResult.items.first?.title, "解释代码：Swift Actor 重入")
        XCTAssertEqual(chineseResult.items.first?.actions.first?.effect?.value, "Swift Actor 重入")
        XCTAssertEqual(chineseResult.items.first?.actions.first?.effect?.options?["autoSend"], "true")

        // Prefix without body opens blank preset window + prefill
        let triggerOnly = await engine.search(PluginSearchParams(
            keyword: "ask",
            query: "cmd",
            hostContext: configuredGeminiContext
        ))
        XCTAssertEqual(triggerOnly.items.first?.title, "生成 Shell 命令 / 正则")
        XCTAssertEqual(triggerOnly.items.first?.actions[0].effect?.options?["autoSend"], "false")
        XCTAssertEqual(triggerOnly.items.first?.actions[1].effect?.kind, "prefill")
        XCTAssertEqual(triggerOnly.items.first?.actions[1].effect?.value, "ask cmd ")
    }

    func testFreeFormQueryAndDefaultSystemPromptPreference() async throws {
        let engine = QuickAIEngine()
        let result = await engine.search(PluginSearchParams(
            keyword: "ai",
            query: "Swift 6 Sendable 怎么用",
            preferences: ["defaultSystemPrompt": "始终附带代码示例"],
            hostContext: configuredGeminiContext
        ))

        // 1 primary ask + 3 quick shortcuts (code / fix / polish)
        XCTAssertEqual(result.items.count, 4)

        let ask = result.items[0]
        XCTAssertEqual(ask.title, "问 AI：Swift 6 Sendable 怎么用")
        XCTAssertEqual(ask.actions.count, 2)
        XCTAssertEqual(ask.actions[0].presentation, "openWindow")
        XCTAssertEqual(ask.actions[0].callback, false)
        XCTAssertEqual(ask.actions[0].effect?.kind, "openAI")
        XCTAssertEqual(ask.actions[0].effect?.value, "Swift 6 Sendable 怎么用")
        XCTAssertEqual(ask.actions[0].effect?.options?["autoSend"], "true")
        XCTAssertEqual(ask.actions[0].effect?.options?["systemPrompt"], "始终附带代码示例")

        XCTAssertEqual(ask.actions[1].title, "打开窗口并预填（暂不发送）")
        XCTAssertEqual(ask.actions[1].effect?.options?["autoSend"], "false")
        XCTAssertEqual(ask.actions[1].effect?.options?["systemPrompt"], "始终附带代码示例")

        // Quick shortcuts
        let shortcuts = Array(result.items.dropFirst())
        XCTAssertEqual(shortcuts.map(\.canonicalKey), [
            "quick-ai:shortcut:code",
            "quick-ai:shortcut:fix",
            "quick-ai:shortcut:polish"
        ])
        for shortcut in shortcuts {
            let primary = try XCTUnwrap(shortcut.actions.first)
            XCTAssertEqual(primary.callback, false)
            XCTAssertEqual(primary.effect?.kind, "openAI")
            XCTAssertEqual(primary.effect?.value, "Swift 6 Sendable 怎么用")
            XCTAssertEqual(primary.effect?.options?["autoSend"], "true")
            XCTAssertTrue(primary.effect?.options?["systemPrompt"]?.contains("始终附带代码示例") == true)
        }
    }

    func testQuickAIExecutableEndToEndStdioNDJSON() throws {
        let executableURL = try locateOrBuildQuickAIExecutable()

        let searchRequest: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 42,
            "method": "search",
            "params": [
                "mode": "keyword",
                "keyword": "ai",
                "query": "fix EXC_BAD_ACCESS",
                "rawQuery": "ai fix EXC_BAD_ACCESS",
                "preferences": ["defaultSystemPrompt": "结论先行"],
                "hostContext": [
                    "hostVersion": "0.4.0",
                    "aiConfigured": "true",
                    "aiFormat": "gemini",
                    "aiModel": "gemini-2.5-flash"
                ]
            ]
        ]
        let shutdownNote: [String: Any] = [
            "jsonrpc": "2.0",
            "method": "shutdown",
            "params": [:]
        ]

        var inputData = try JSONSerialization.data(withJSONObject: searchRequest)
        inputData.append(UInt8(ascii: "\n"))
        inputData.append(try JSONSerialization.data(withJSONObject: shutdownNote))
        inputData.append(UInt8(ascii: "\n"))

        let process = Process()
        process.executableURL = executableURL
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        try stdinPipe.fileHandleForWriting.write(contentsOf: inputData)
        try stdinPipe.fileHandleForWriting.close()

        let stdoutData = try stdoutPipe.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 0)
        let lines = String(decoding: stdoutData, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        XCTAssertEqual(lines.count, 1)

        let rpc = try JSONDecoder().decode(
            PluginRPCResponse<PluginSearchResultDTO>.self,
            from: Data(lines[0].utf8)
        )
        XCTAssertEqual(rpc.jsonrpc, "2.0")
        XCTAssertEqual(rpc.id, 42)
        XCTAssertNil(rpc.error)

        let items = try XCTUnwrap(rpc.result?.items)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].title, "排查报错：EXC_BAD_ACCESS")
        XCTAssertEqual(items[0].subtitle, "使用 Gemini · gemini-2.5-flash 流式回答")
        XCTAssertEqual(items[0].actions[0].effect?.kind, "openAI")
        XCTAssertEqual(items[0].actions[0].effect?.value, "EXC_BAD_ACCESS")
        XCTAssertEqual(items[0].actions[0].effect?.options?["title"], "排查报错")
        XCTAssertEqual(items[0].actions[0].effect?.options?["autoSend"], "true")
        XCTAssertTrue(items[0].actions[0].effect?.options?["systemPrompt"]?.contains("结论先行") == true)
    }

    private func locateOrBuildQuickAIExecutable() throws -> URL {
        let fm = FileManager.default
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        let candidates: [URL] = [
            Bundle(for: type(of: self)).bundleURL
                .deletingLastPathComponent()
                .appendingPathComponent("QuickAIPlugin"),
            packageRoot.appendingPathComponent(".build/debug/QuickAIPlugin"),
            packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/QuickAIPlugin"),
            packageRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/QuickAIPlugin")
        ]

        if let existing = candidates.first(where: { fm.isExecutableFile(atPath: $0.path) }) {
            return existing
        }

        let build = Process()
        build.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        build.arguments = ["build", "--package-path", packageRoot.path, "--product", "QuickAIPlugin"]
        build.standardOutput = Pipe()
        build.standardError = Pipe()
        try build.run()
        build.waitUntilExit()
        XCTAssertEqual(build.terminationStatus, 0, "Failed to build QuickAIPlugin executable")

        let showPath = Process()
        showPath.executableURL = URL(fileURLWithPath: "/usr/bin/swift")
        showPath.arguments = ["build", "--package-path", packageRoot.path, "--show-bin-path"]
        let binPipe = Pipe()
        showPath.standardOutput = binPipe
        try showPath.run()
        let binData = try binPipe.fileHandleForReading.readToEnd() ?? Data()
        showPath.waitUntilExit()
        let binDir = String(decoding: binData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let built = URL(fileURLWithPath: binDir).appendingPathComponent("QuickAIPlugin")
        XCTAssertTrue(fm.isExecutableFile(atPath: built.path), "Missing built QuickAIPlugin at \(built.path)")
        return built
    }
}

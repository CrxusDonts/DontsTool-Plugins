import DontsToolPluginSDK
import Foundation

public struct QuickAIEngine: PluginEngine {
    public static let entryCanonicalKey = "plugin.com.donts.quick-ai.home"

    public init() {}

    public func search(_ params: PluginSearchParams) async -> PluginSearchResultDTO {
        let query = params.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let activeKeyword = nonEmpty(params.keyword)?.lowercased() ?? "ai"
        let defaultSystemPrompt = nonEmpty(params.preferences["defaultSystemPrompt"])
        let status = HostAIStatus(hostContext: params.hostContext)

        if query.isEmpty {
            return PluginSearchResultDTO(
                items: emptyQueryItems(
                    keyword: activeKeyword,
                    status: status,
                    defaultSystemPrompt: defaultSystemPrompt
                )
            )
        }

        if let matched = QuickAIPresets.matchPrefix(in: query) {
            return PluginSearchResultDTO(
                items: presetPrefixItems(
                    matched: matched,
                    fullQuery: query,
                    keyword: activeKeyword,
                    status: status,
                    defaultSystemPrompt: defaultSystemPrompt
                )
            )
        }

        return PluginSearchResultDTO(
            items: freeFormQueryItems(
                query: query,
                status: status,
                defaultSystemPrompt: defaultSystemPrompt
            )
        )
    }

    // MARK: - Search Modes

    private func emptyQueryItems(
        keyword: String,
        status: HostAIStatus,
        defaultSystemPrompt: String?
    ) -> [PluginSearchItemDTO] {
        var items: [PluginSearchItemDTO] = []

        let newChatEffect = makeOpenAIEffect(
            prompt: "",
            windowTitle: "AI 快问",
            systemPrompt: defaultSystemPrompt,
            autoSend: false
        )
        items.append(PluginSearchItemDTO(
            title: "新建 AI 对话",
            subtitle: status.statusSubtitle,
            score: 3000,
            canonicalKey: "quick-ai:new-chat",
            icon: PluginIconDTO(kind: "symbol", value: "sparkles", tint: "blue"),
            badge: status.primaryBadge,
            actions: [
                PluginActionDTO(
                    id: "quick-ai.new-chat",
                    title: "打开 AI 对话窗口",
                    symbol: "sparkles",
                    presentation: "openWindow",
                    callback: false,
                    effect: newChatEffect
                )
            ]
        ))

        for (index, preset) in QuickAIPresets.all.enumerated() {
            items.append(makeEmptyPresetItem(
                preset,
                keyword: keyword,
                status: status,
                defaultSystemPrompt: defaultSystemPrompt,
                score: 2500 - Double(index * 10)
            ))
        }

        return items
    }

    private func presetPrefixItems(
        matched: QuickAIPresets.MatchedPrefix,
        fullQuery: String,
        keyword: String,
        status: HostAIStatus,
        defaultSystemPrompt: String?
    ) -> [PluginSearchItemDTO] {
        let preset = matched.preset
        let mergedPrompt = mergedSystemPrompt(
            presetPrompt: preset.systemPrompt,
            defaultSystemPrompt: defaultSystemPrompt
        )

        var items: [PluginSearchItemDTO] = []

        if matched.remainder.isEmpty {
            items.append(PluginSearchItemDTO(
                title: preset.title,
                subtitle: status.isConfigured
                    ? "\(preset.subtitle) · \(status.statusSubtitle)"
                    : status.statusSubtitle,
                score: 3200,
                canonicalKey: "quick-ai:preset:\(preset.id)",
                icon: PluginIconDTO(kind: "symbol", value: preset.symbol, tint: preset.tint),
                badge: PluginBadgeDTO(text: preset.badgeText, tint: preset.tint),
                actions: [
                    PluginActionDTO(
                        id: "quick-ai.preset.\(preset.id).open",
                        title: "打开「\(preset.windowTitle)」窗口",
                        symbol: preset.symbol,
                        presentation: "openWindow",
                        callback: false,
                        effect: makeOpenAIEffect(
                            prompt: "",
                            windowTitle: preset.windowTitle,
                            systemPrompt: mergedPrompt,
                            autoSend: false
                        )
                    ),
                    PluginActionDTO(
                        id: "quick-ai.preset.\(preset.id).prefill",
                        title: "回填「\(keyword) \(preset.primaryTrigger) 」继续输入",
                        symbol: "text.cursor",
                        presentation: "keepPanelOpen",
                        callback: false,
                        effect: PluginActionEffectDTO(
                            kind: "prefill",
                            value: "\(keyword) \(preset.primaryTrigger) "
                        )
                    )
                ]
            ))
        } else {
            let body = matched.remainder
            items.append(PluginSearchItemDTO(
                title: "\(preset.windowTitle)：\(abbreviated(body))",
                subtitle: status.statusSubtitle,
                score: 3400,
                canonicalKey: "quick-ai:preset:\(preset.id):ask",
                icon: PluginIconDTO(kind: "symbol", value: preset.symbol, tint: preset.tint),
                badge: status.isConfigured
                    ? PluginBadgeDTO(text: preset.windowTitle, tint: preset.tint)
                    : status.primaryBadge,
                actions: [
                    PluginActionDTO(
                        id: "quick-ai.preset.\(preset.id).send",
                        title: "立即发送（\(preset.windowTitle)）",
                        symbol: "paperplane.fill",
                        presentation: "openWindow",
                        callback: false,
                        effect: makeOpenAIEffect(
                            prompt: body,
                            windowTitle: preset.windowTitle,
                            systemPrompt: mergedPrompt,
                            autoSend: true
                        )
                    ),
                    PluginActionDTO(
                        id: "quick-ai.preset.\(preset.id).draft",
                        title: "打开窗口并预填（暂不发送）",
                        symbol: "square.and.pencil",
                        presentation: "openWindow",
                        callback: false,
                        effect: makeOpenAIEffect(
                            prompt: body,
                            windowTitle: preset.windowTitle,
                            systemPrompt: mergedPrompt,
                            autoSend: false
                        )
                    )
                ]
            ))
        }

        items.append(PluginSearchItemDTO(
            title: "直接问 AI：\(abbreviated(fullQuery))",
            subtitle: status.statusSubtitle,
            score: 2600,
            canonicalKey: "quick-ai:direct-fallback",
            icon: PluginIconDTO(kind: "symbol", value: "sparkles", tint: "blue"),
            badge: PluginBadgeDTO(text: "通用", tint: "gray"),
            actions: [
                PluginActionDTO(
                    id: "quick-ai.direct.send",
                    title: "直接问 AI",
                    symbol: "paperplane.fill",
                    presentation: "openWindow",
                    callback: false,
                    effect: makeOpenAIEffect(
                        prompt: fullQuery,
                        windowTitle: "AI 快问",
                        systemPrompt: defaultSystemPrompt,
                        autoSend: true
                    )
                ),
                PluginActionDTO(
                    id: "quick-ai.direct.draft",
                    title: "打开窗口并预填（暂不发送）",
                    symbol: "square.and.pencil",
                    presentation: "openWindow",
                    callback: false,
                    effect: makeOpenAIEffect(
                        prompt: fullQuery,
                        windowTitle: "AI 快问",
                        systemPrompt: defaultSystemPrompt,
                        autoSend: false
                    )
                )
            ]
        ))

        return items
    }

    private func freeFormQueryItems(
        query: String,
        status: HostAIStatus,
        defaultSystemPrompt: String?
    ) -> [PluginSearchItemDTO] {
        var items: [PluginSearchItemDTO] = []

        items.append(PluginSearchItemDTO(
            title: "问 AI：\(abbreviated(query))",
            subtitle: status.statusSubtitle,
            score: 3400,
            canonicalKey: "quick-ai:ask",
            icon: PluginIconDTO(kind: "symbol", value: "sparkles", tint: "blue"),
            badge: status.primaryBadge,
            actions: [
                PluginActionDTO(
                    id: "quick-ai.ask.send",
                    title: "发送给 AI",
                    symbol: "paperplane.fill",
                    presentation: "openWindow",
                    callback: false,
                    effect: makeOpenAIEffect(
                        prompt: query,
                        windowTitle: "AI 快问",
                        systemPrompt: defaultSystemPrompt,
                        autoSend: true
                    )
                ),
                PluginActionDTO(
                    id: "quick-ai.ask.draft",
                    title: "打开窗口并预填（暂不发送）",
                    symbol: "square.and.pencil",
                    presentation: "openWindow",
                    callback: false,
                    effect: makeOpenAIEffect(
                        prompt: query,
                        windowTitle: "AI 快问",
                        systemPrompt: defaultSystemPrompt,
                        autoSend: false
                    )
                )
            ]
        ))

        for (index, preset) in QuickAIPresets.quickShortcuts.enumerated() {
            let mergedPrompt = mergedSystemPrompt(
                presetPrompt: preset.systemPrompt,
                defaultSystemPrompt: defaultSystemPrompt
            )
            items.append(PluginSearchItemDTO(
                title: "\(preset.quickActionTitlePrefix)：\(abbreviated(query))",
                subtitle: status.isConfigured
                    ? "场景：\(preset.title) · \(status.statusSubtitle)"
                    : status.statusSubtitle,
                score: 2800 - Double(index * 10),
                canonicalKey: "quick-ai:shortcut:\(preset.id)",
                icon: PluginIconDTO(kind: "symbol", value: preset.symbol, tint: preset.tint),
                badge: PluginBadgeDTO(text: preset.windowTitle, tint: preset.tint),
                actions: [
                    PluginActionDTO(
                        id: "quick-ai.shortcut.\(preset.id).send",
                        title: "\(preset.quickActionTitlePrefix)并立即发送",
                        symbol: preset.symbol,
                        presentation: "openWindow",
                        callback: false,
                        effect: makeOpenAIEffect(
                            prompt: query,
                            windowTitle: preset.windowTitle,
                            systemPrompt: mergedPrompt,
                            autoSend: true
                        )
                    ),
                    PluginActionDTO(
                        id: "quick-ai.shortcut.\(preset.id).draft",
                        title: "打开窗口并预填（暂不发送）",
                        symbol: "square.and.pencil",
                        presentation: "openWindow",
                        callback: false,
                        effect: makeOpenAIEffect(
                            prompt: query,
                            windowTitle: preset.windowTitle,
                            systemPrompt: mergedPrompt,
                            autoSend: false
                        )
                    )
                ]
            ))
        }

        return items
    }

    // MARK: - Helpers

    private func makeEmptyPresetItem(
        _ preset: QuickAIPreset,
        keyword: String,
        status: HostAIStatus,
        defaultSystemPrompt: String?,
        score: Double
    ) -> PluginSearchItemDTO {
        let mergedPrompt = mergedSystemPrompt(
            presetPrompt: preset.systemPrompt,
            defaultSystemPrompt: defaultSystemPrompt
        )
        let subtitle = status.isConfigured ? preset.subtitle : status.statusSubtitle

        return PluginSearchItemDTO(
            title: preset.title,
            subtitle: subtitle,
            score: score,
            canonicalKey: "quick-ai:preset:\(preset.id)",
            icon: PluginIconDTO(kind: "symbol", value: preset.symbol, tint: preset.tint),
            badge: PluginBadgeDTO(text: preset.badgeText, tint: preset.tint),
            actions: [
                PluginActionDTO(
                    id: "quick-ai.preset.\(preset.id).open",
                    title: "打开「\(preset.windowTitle)」窗口",
                    symbol: preset.symbol,
                    presentation: "openWindow",
                    callback: false,
                    effect: makeOpenAIEffect(
                        prompt: "",
                        windowTitle: preset.windowTitle,
                        systemPrompt: mergedPrompt,
                        autoSend: false
                    )
                ),
                PluginActionDTO(
                    id: "quick-ai.preset.\(preset.id).prefill",
                    title: "回填「\(keyword) \(preset.primaryTrigger) 」继续输入",
                    symbol: "text.cursor",
                    presentation: "keepPanelOpen",
                    callback: false,
                    effect: PluginActionEffectDTO(
                        kind: "prefill",
                        value: "\(keyword) \(preset.primaryTrigger) "
                    )
                )
            ]
        )
    }

    private func makeOpenAIEffect(
        prompt: String,
        windowTitle: String,
        systemPrompt: String?,
        autoSend: Bool
    ) -> PluginActionEffectDTO {
        var options: [String: String] = [
            "title": windowTitle,
            "autoSend": autoSend ? "true" : "false"
        ]
        if let systemPrompt, !systemPrompt.isEmpty {
            options["systemPrompt"] = systemPrompt
        }
        return PluginActionEffectDTO(
            kind: "openAI",
            value: prompt,
            options: options,
            recordUsageKey: Self.entryCanonicalKey
        )
    }

    private func mergedSystemPrompt(presetPrompt: String?, defaultSystemPrompt: String?) -> String? {
        let trimmedPreset = nonEmpty(presetPrompt)
        let trimmedDefault = nonEmpty(defaultSystemPrompt)
        switch (trimmedPreset, trimmedDefault) {
        case (nil, nil):
            return nil
        case (nil, let fallback?):
            return fallback
        case (let preset?, nil):
            return preset
        case (let preset?, let fallback?):
            return "\(preset)\n\n\(fallback)"
        }
    }

    private func abbreviated(_ text: String, maxLength: Int = 72) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard singleLine.count > maxLength else { return singleLine }
        return String(singleLine.prefix(maxLength)) + "…"
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

private struct HostAIStatus: Sendable {
    let isConfigured: Bool
    let formatDisplayName: String?
    let modelName: String?

    init(hostContext: [String: String]?) {
        let configuredRaw = hostContext?["aiConfigured"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        self.isConfigured = (configuredRaw == "true")

        let rawFormat = hostContext?["aiFormat"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch rawFormat {
        case "gemini":
            self.formatDisplayName = "Gemini"
        case "openai_responses":
            self.formatDisplayName = "OpenAI Responses"
        case "openai_chat":
            self.formatDisplayName = "OpenAI Chat"
        default:
            self.formatDisplayName = nil
        }

        let rawModel = hostContext?["aiModel"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.modelName = (rawModel?.isEmpty == false) ? rawModel : nil
    }

    var statusSubtitle: String {
        guard isConfigured else {
            return "尚未配置大模型，回车打开窗口前往「设置 → AI 与翻译」"
        }
        switch (formatDisplayName, modelName) {
        case (let format?, let model?):
            return "使用 \(format) · \(model) 流式回答"
        case (nil, let model?):
            return "使用 \(model) 流式回答"
        case (let format?, nil):
            return "使用 \(format) 流式回答"
        case (nil, nil):
            return "使用宿主大模型配置流式回答"
        }
    }

    var primaryBadge: PluginBadgeDTO? {
        guard isConfigured else {
            return PluginBadgeDTO(text: "未配置", tint: "amber")
        }
        if let modelName {
            return PluginBadgeDTO(text: modelName, tint: "blue")
        }
        if let formatDisplayName {
            return PluginBadgeDTO(text: formatDisplayName, tint: "blue")
        }
        return nil
    }
}

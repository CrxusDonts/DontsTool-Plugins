import Foundation

public struct QuickAIPreset: Equatable, Sendable {
    public let id: String
    public let title: String
    public let windowTitle: String
    public let quickActionTitlePrefix: String
    public let subtitle: String
    public let triggers: [String]
    public let primaryTrigger: String
    public let symbol: String
    public let tint: String
    public let badgeText: String
    public let systemPrompt: String
    public let isQuickShortcut: Bool

    public init(
        id: String,
        title: String,
        windowTitle: String,
        quickActionTitlePrefix: String,
        subtitle: String,
        triggers: [String],
        primaryTrigger: String,
        symbol: String,
        tint: String,
        badgeText: String,
        systemPrompt: String,
        isQuickShortcut: Bool
    ) {
        self.id = id
        self.title = title
        self.windowTitle = windowTitle
        self.quickActionTitlePrefix = quickActionTitlePrefix
        self.subtitle = subtitle
        self.triggers = triggers
        self.primaryTrigger = primaryTrigger
        self.symbol = symbol
        self.tint = tint
        self.badgeText = badgeText
        self.systemPrompt = systemPrompt
        self.isQuickShortcut = isQuickShortcut
    }

    public func matchesTrigger(_ token: String) -> Bool {
        let lower = token.lowercased()
        return triggers.contains { $0.lowercased() == lower }
    }
}

public enum QuickAIPresets {
    public static let all: [QuickAIPreset] = [
        QuickAIPreset(
            id: "code",
            title: "解释代码与概念",
            windowTitle: "解释代码",
            quickActionTitlePrefix: "用 AI 解释",
            subtitle: "输入 ai code <片段或概念> · 先给结论，再拆解原理与关键细节",
            triggers: ["code", "explain", "解释"],
            primaryTrigger: "code",
            symbol: "chevron.left.forwardslash.chevron.right",
            tint: "indigo",
            badgeText: "code",
            systemPrompt: "你是资深软件工程师与技术导师。请用清晰简洁的中文解释用户提供的代码、API 或技术概念，先给出一句话结论，再说明关键原理、常见坑与简短示例。",
            isQuickShortcut: true
        ),
        QuickAIPreset(
            id: "fix",
            title: "排查报错原因",
            windowTitle: "排查报错",
            quickActionTitlePrefix: "用 AI 排查报错",
            subtitle: "输入 ai fix <报错信息> · 定位最可能根因并给出最小修复方案",
            triggers: ["fix", "debug", "报错"],
            primaryTrigger: "fix",
            symbol: "wrench.and.screwdriver",
            tint: "orange",
            badgeText: "fix",
            systemPrompt: "你是经验丰富的故障排查专家。请根据用户提供的报错日志或异常现象，先给出最可能的根因排序，再提供可直接验证的排查步骤与最小修复方案，回复用简洁中文。",
            isQuickShortcut: true
        ),
        QuickAIPreset(
            id: "polish",
            title: "润色与改写文字",
            windowTitle: "润色改写",
            quickActionTitlePrefix: "用 AI 润色改写",
            subtitle: "输入 ai polish <文本> · 保持原意，让表达更自然、清晰、克制",
            triggers: ["polish", "rewrite", "润色"],
            primaryTrigger: "polish",
            symbol: "wand.and.stars",
            tint: "purple",
            badgeText: "polish",
            systemPrompt: "你是严谨的文字编辑。请在保持原意的前提下润色改写用户的文本，使其自然、清晰、克制；若原文为英文则输出更地道的英文，否则输出简洁中文，直接给出改写结果，必要时附一行改动要点。",
            isQuickShortcut: true
        ),
        QuickAIPreset(
            id: "cmd",
            title: "生成 Shell 命令 / 正则",
            windowTitle: "命令与正则",
            quickActionTitlePrefix: "生成命令或正则",
            subtitle: "输入 ai cmd <需求> · 给出适配 macOS zsh 的可执行命令或正则",
            triggers: ["cmd", "regex", "命令"],
            primaryTrigger: "cmd",
            symbol: "terminal",
            tint: "teal",
            badgeText: "cmd",
            systemPrompt: "你是 macOS / Unix 命令行与正则表达式专家。请优先给出可直接复制执行的命令或正则（默认适配 macOS zsh 与 BSD 工具差异），再用简短要点解释关键参数与风险提示。",
            isQuickShortcut: false
        ),
        QuickAIPreset(
            id: "sum",
            title: "提炼要点与总结",
            windowTitle: "提炼总结",
            quickActionTitlePrefix: "用 AI 提炼总结",
            subtitle: "输入 ai sum <长文或记录> · 按核心结论、关键事实与待办结构化提炼",
            triggers: ["sum", "summary", "总结"],
            primaryTrigger: "sum",
            symbol: "text.alignleft",
            tint: "green",
            badgeText: "sum",
            systemPrompt: "你是高效的信息提炼助手。请将用户输入的长文、会议记录或资料压缩为结构化要点，按「核心结论 / 关键事实 / 待办与风险」输出，用简洁中文，不遗漏关键数字与结论。",
            isQuickShortcut: false
        )
    ]

    public static var quickShortcuts: [QuickAIPreset] {
        all.filter(\.isQuickShortcut)
    }

    public struct MatchedPrefix: Equatable, Sendable {
        public let preset: QuickAIPreset
        public let matchedToken: String
        public let remainder: String

        public init(preset: QuickAIPreset, matchedToken: String, remainder: String) {
            self.preset = preset
            self.matchedToken = matchedToken
            self.remainder = remainder
        }
    }

    public static func matchPrefix(in query: String) -> MatchedPrefix? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let firstToken: String
        let remainder: String
        if let splitIndex = trimmed.firstIndex(where: \.isWhitespace) {
            firstToken = String(trimmed[..<splitIndex])
            remainder = String(trimmed[splitIndex...]).trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            firstToken = trimmed
            remainder = ""
        }

        guard let preset = all.first(where: { $0.matchesTrigger(firstToken) }) else {
            return nil
        }
        return MatchedPrefix(preset: preset, matchedToken: firstToken, remainder: remainder)
    }
}

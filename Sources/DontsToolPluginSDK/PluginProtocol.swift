import Foundation

public struct PluginRPCErrorPayload: Codable, Equatable, Sendable {
    public let code: Int
    public let message: String

    public init(code: Int, message: String) {
        self.code = code
        self.message = message
    }
}

public struct PluginRPCEnvelope: Decodable, Sendable {
    public let jsonrpc: String?
    public let id: Int?
    public let error: PluginRPCErrorPayload?
}

public struct PluginRPCRequest<Params: Encodable>: Encodable {
    public let jsonrpc = "2.0"
    public let id: Int
    public let method: String
    public let params: Params

    public init(id: Int, method: String, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct PluginRPCNotification<Params: Encodable>: Encodable {
    public let jsonrpc = "2.0"
    public let method: String
    public let params: Params

    public init(method: String, params: Params) {
        self.method = method
        self.params = params
    }
}

public struct PluginRPCResponse<Result: Codable & Sendable>: Codable, Sendable {
    public let jsonrpc: String
    public let id: Int?
    public let result: Result?
    public let error: PluginRPCErrorPayload?

    public init(
        jsonrpc: String = "2.0",
        id: Int? = nil,
        result: Result? = nil,
        error: PluginRPCErrorPayload? = nil
    ) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.result = result
        self.error = error
    }
}

public struct PluginEmptyParams: Codable, Equatable, Sendable {
    public init() {}
}

public struct PluginCancelParams: Codable, Equatable, Sendable {
    public let id: Int

    public init(id: Int) {
        self.id = id
    }
}

public struct PluginSearchParams: Codable, Equatable, Sendable {
    public let mode: String
    public let keyword: String?
    public let query: String
    public let rawQuery: String
    public let frontmostBundleID: String?
    public let preferences: [String: String]
    public let hostContext: [String: String]?

    public init(
        mode: String = "keyword",
        keyword: String? = nil,
        query: String = "",
        rawQuery: String? = nil,
        frontmostBundleID: String? = nil,
        preferences: [String: String] = [:],
        hostContext: [String: String]? = nil
    ) {
        self.mode = mode
        self.keyword = keyword
        self.query = query
        self.rawQuery = rawQuery ?? query
        self.frontmostBundleID = frontmostBundleID
        self.preferences = preferences
        self.hostContext = hostContext
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case keyword
        case query
        case rawQuery
        case frontmostBundleID
        case preferences
        case hostContext
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decodeIfPresent(String.self, forKey: .mode) ?? "keyword"
        let keyword = try container.decodeIfPresent(String.self, forKey: .keyword)
        let query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        let rawQuery = try container.decodeIfPresent(String.self, forKey: .rawQuery) ?? query
        let frontmostBundleID = try container.decodeIfPresent(String.self, forKey: .frontmostBundleID)
        let preferences = try container.decodeIfPresent([String: String].self, forKey: .preferences) ?? [:]
        let hostContext = try container.decodeIfPresent([String: String].self, forKey: .hostContext)

        self.mode = mode
        self.keyword = keyword
        self.query = query
        self.rawQuery = rawQuery
        self.frontmostBundleID = frontmostBundleID
        self.preferences = preferences
        self.hostContext = hostContext
    }
}

public struct PluginIconDTO: Codable, Equatable, Sendable {
    public let kind: String
    public let value: String
    public let tint: String?

    public init(kind: String, value: String, tint: String? = nil) {
        self.kind = kind
        self.value = value
        self.tint = tint
    }
}

public struct PluginBadgeDTO: Codable, Equatable, Sendable {
    public let text: String
    public let tint: String?

    public init(text: String, tint: String? = nil) {
        self.text = text
        self.tint = tint
    }
}

public struct PluginActionEffectDTO: Codable, Equatable, Sendable {
    public let kind: String
    public let value: String?
    public let toast: String?
    public let refresh: Bool?
    public let recordUsageKey: String?

    public init(
        kind: String,
        value: String? = nil,
        toast: String? = nil,
        refresh: Bool? = nil,
        recordUsageKey: String? = nil
    ) {
        self.kind = kind
        self.value = value
        self.toast = toast
        self.refresh = refresh
        self.recordUsageKey = recordUsageKey
    }
}

public struct PluginActionDTO: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String?
    public let presentation: String?
    public let callback: Bool?
    public let payload: [String: String]?
    public let effect: PluginActionEffectDTO?
    public let fileAction: String?

    public init(
        id: String,
        title: String,
        symbol: String? = nil,
        presentation: String? = nil,
        callback: Bool? = nil,
        payload: [String: String]? = nil,
        effect: PluginActionEffectDTO? = nil,
        fileAction: String? = nil
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.presentation = presentation
        self.callback = callback
        self.payload = payload
        self.effect = effect
        self.fileAction = fileAction
    }
}

public struct PluginSearchItemDTO: Codable, Equatable, Sendable {
    public let id: String?
    public let title: String
    public let subtitle: String?
    public let score: Double?
    public let canonicalKey: String
    public let keyword: String?
    public let group: String?
    public let icon: PluginIconDTO?
    public let badge: PluginBadgeDTO?
    public let actions: [PluginActionDTO]

    public init(
        id: String? = nil,
        title: String,
        subtitle: String? = nil,
        score: Double? = nil,
        canonicalKey: String,
        keyword: String? = nil,
        group: String? = nil,
        icon: PluginIconDTO? = nil,
        badge: PluginBadgeDTO? = nil,
        actions: [PluginActionDTO] = []
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.score = score
        self.canonicalKey = canonicalKey
        self.keyword = keyword
        self.group = group
        self.icon = icon
        self.badge = badge
        self.actions = actions
    }
}

public struct PluginSearchResultDTO: Codable, Equatable, Sendable {
    public let items: [PluginSearchItemDTO]
    public let notice: String?

    public init(items: [PluginSearchItemDTO], notice: String? = nil) {
        self.items = items
        self.notice = notice
    }
}

public struct PluginExecuteParams: Codable, Equatable, Sendable {
    public let actionId: String
    public let payload: [String: String]
    public let preferences: [String: String]
    public let hostContext: [String: String]?

    public init(
        actionId: String,
        payload: [String: String] = [:],
        preferences: [String: String] = [:],
        hostContext: [String: String]? = nil
    ) {
        self.actionId = actionId
        self.payload = payload
        self.preferences = preferences
        self.hostContext = hostContext
    }

    private enum CodingKeys: String, CodingKey {
        case actionId
        case payload
        case preferences
        case hostContext
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.actionId = try container.decode(String.self, forKey: .actionId)
        self.payload = try container.decodeIfPresent([String: String].self, forKey: .payload) ?? [:]
        self.preferences = try container.decodeIfPresent([String: String].self, forKey: .preferences) ?? [:]
        self.hostContext = try container.decodeIfPresent([String: String].self, forKey: .hostContext)
    }
}

public struct PluginExecuteResultDTO: Codable, Equatable, Sendable {
    public let effect: PluginActionEffectDTO?
    public let toast: String?
    public let refresh: Bool?
    public let recordUsageKey: String?
    public let error: String?

    public init(
        effect: PluginActionEffectDTO? = nil,
        toast: String? = nil,
        refresh: Bool? = nil,
        recordUsageKey: String? = nil,
        error: String? = nil
    ) {
        self.effect = effect
        self.toast = toast
        self.refresh = refresh
        self.recordUsageKey = recordUsageKey
        self.error = error
    }
}

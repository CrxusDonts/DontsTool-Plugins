import Foundation

public protocol PluginEngine: Sendable {
    func search(_ params: PluginSearchParams) async -> PluginSearchResultDTO
    func execute(_ params: PluginExecuteParams) async -> PluginExecuteResultDTO
}

public extension PluginEngine {
    func execute(_ params: PluginExecuteParams) async -> PluginExecuteResultDTO {
        PluginExecuteResultDTO(error: "不支持的操作：\(params.actionId)")
    }
}

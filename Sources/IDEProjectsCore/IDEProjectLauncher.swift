import AppKit
import Foundation

public struct SystemIDEProjectLauncher: IDEProjectOpening {
    public init() {}

    public func openProject(at project: URL, using application: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = true
        configuration.arguments = [project.path]
        _ = try await NSWorkspace.shared.openApplication(at: application, configuration: configuration)
    }
}

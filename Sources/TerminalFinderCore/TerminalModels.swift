import Foundation

public struct TerminalAppDescriptor: Equatable, Hashable, Identifiable, Sendable {
    public let bundleID: String
    public let displayName: String
    public let aliases: [String]
    public let alternateBundleIDs: [String]
    public let appPath: String?

    public var id: String { bundleID }

    public init(
        bundleID: String,
        displayName: String,
        aliases: [String] = [],
        alternateBundleIDs: [String] = [],
        appPath: String? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.aliases = aliases
        self.alternateBundleIDs = alternateBundleIDs
        self.appPath = appPath
    }

    public var allBundleIDs: [String] {
        [bundleID] + alternateBundleIDs
    }

    public func matches(bundleID candidate: String) -> Bool {
        allBundleIDs.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
    }

    public func withAppPath(_ path: String?) -> TerminalAppDescriptor {
        TerminalAppDescriptor(
            bundleID: bundleID,
            displayName: displayName,
            aliases: aliases,
            alternateBundleIDs: alternateBundleIDs,
            appPath: path
        )
    }
}

public enum TerminalAppCatalog {
    public static let finderBundleID = "com.apple.finder"
    public static let ghosttyBundleID = "com.mitchellh.ghostty"
    public static let warpBundleID = "dev.warp.Warp-Stable"
    public static let iterm2BundleID = "com.googlecode.iterm2"
    public static let appleTerminalBundleID = "com.apple.Terminal"

    public static let knownTerminals: [TerminalAppDescriptor] = [
        TerminalAppDescriptor(
            bundleID: ghosttyBundleID,
            displayName: "Ghostty",
            aliases: ["ghostty", "otty"]
        ),
        TerminalAppDescriptor(
            bundleID: warpBundleID,
            displayName: "Warp",
            aliases: ["warp"],
            alternateBundleIDs: ["dev.warp.Warp-Preview", "dev.warp.Warp"]
        ),
        TerminalAppDescriptor(
            bundleID: iterm2BundleID,
            displayName: "iTerm2",
            aliases: ["iterm", "iterm2"]
        ),
        TerminalAppDescriptor(
            bundleID: appleTerminalBundleID,
            displayName: "终端",
            aliases: ["terminal", "终端"]
        ),
        TerminalAppDescriptor(
            bundleID: "com.github.wez.wezterm",
            displayName: "WezTerm",
            aliases: ["wezterm", "wez"]
        ),
        TerminalAppDescriptor(
            bundleID: "net.kovidgoyal.kitty",
            displayName: "Kitty",
            aliases: ["kitty"]
        ),
        TerminalAppDescriptor(
            bundleID: "org.alacritty",
            displayName: "Alacritty",
            aliases: ["alacritty"]
        ),
        TerminalAppDescriptor(
            bundleID: "com.orcaterm.app",
            displayName: "OrcaTerm",
            aliases: ["orcaterm", "orca"]
        )
    ]

    public static func descriptor(forBundleID bundleID: String) -> TerminalAppDescriptor? {
        knownTerminals.first { $0.matches(bundleID: bundleID) }
    }

    public static func isKnownTerminal(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return descriptor(forBundleID: bundleID) != nil
    }
}

public enum TerminalFinderError: LocalizedError, Equatable, Sendable {
    case finderNoDirectory
    case terminalNoDirectory
    case terminalNotInstalled(String)
    case directoryNotFound(String)
    case automationDenied(String)
    case actionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .finderNoDirectory:
            "当前没有可读取路径的访达窗口"
        case .terminalNoDirectory:
            "未能检测到终端的当前工作目录，请确认终端已打开并运行本地 Shell"
        case .terminalNotInstalled(let name):
            "未在本机找到终端应用：\(name)"
        case .directoryNotFound(let path):
            "目录不存在：\(path)"
        case .automationDenied(let target):
            "读取「\(target)」需要自动化权限，请在系统设置 → 隐私与安全性 → 自动化中允许 DontsTool"
        case .actionFailed(let message):
            "终端与访达操作失败：\(message)"
        }
    }
}

public protocol TerminalFinderControlling: Sendable {
    func installedTerminals() -> [TerminalAppDescriptor]
    func runningTerminalBundleIDs() -> [String]
    func currentFinderDirectory() async throws -> URL
    func currentTerminalDirectory(preferredBundleID: String?) async throws -> URL
    func openInTerminal(directory: URL, terminalBundleID: String) async throws
    func openInFinder(directory: URL) async throws
}

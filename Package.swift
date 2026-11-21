// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "DontsToolPlugins",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "DontsToolPluginSDK",
            targets: ["DontsToolPluginSDK"]
        ),
        .executable(
            name: "KillProcessPlugin",
            targets: ["KillProcessPlugin"]
        ),
        .executable(
            name: "IDEProjectsPlugin",
            targets: ["IDEProjectsPlugin"]
        ),
        .executable(
            name: "FileSearchPlugin",
            targets: ["FileSearchPlugin"]
        ),
        .executable(
            name: "ChromePlugin",
            targets: ["ChromePlugin"]
        ),
        .executable(
            name: "TerminalFinderPlugin",
            targets: ["TerminalFinderPlugin"]
        )
    ],
    targets: [
        .target(
            name: "DontsToolPluginSDK"
        ),
        .target(
            name: "KillProcessCore",
            dependencies: ["DontsToolPluginSDK"]
        ),
        .executableTarget(
            name: "KillProcessPlugin",
            dependencies: ["DontsToolPluginSDK", "KillProcessCore"]
        ),
        .target(
            name: "IDEProjectsCore",
            dependencies: ["DontsToolPluginSDK"]
        ),
        .executableTarget(
            name: "IDEProjectsPlugin",
            dependencies: ["DontsToolPluginSDK", "IDEProjectsCore"]
        ),
        .target(
            name: "FileSearchCore",
            dependencies: ["DontsToolPluginSDK"]
        ),
        .executableTarget(
            name: "FileSearchPlugin",
            dependencies: ["DontsToolPluginSDK", "FileSearchCore"]
        ),
        .target(
            name: "ChromeCore",
            dependencies: ["DontsToolPluginSDK"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "ChromePlugin",
            dependencies: ["DontsToolPluginSDK", "ChromeCore"]
        ),
        .target(
            name: "TerminalFinderCore",
            dependencies: ["DontsToolPluginSDK"]
        ),
        .executableTarget(
            name: "TerminalFinderPlugin",
            dependencies: ["DontsToolPluginSDK", "TerminalFinderCore"]
        ),
        .testTarget(
            name: "DontsToolPluginsTests",
            dependencies: [
                "DontsToolPluginSDK",
                "KillProcessCore",
                "IDEProjectsCore",
                "FileSearchCore",
                "ChromeCore",
                "TerminalFinderCore"
            ]
        )
    ]
)

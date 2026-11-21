# DontsTool Plugins

[DontsTool](https://github.com/CrxusDonts/DontsTool) 官方插件集合仓库（SwiftPM 多插件 Monorepo），通过标准 Sidecar（NDJSON JSON-RPC 2.0）协议与 DontsTool 微内核解耦，支持在 DontsTool 设置中一键拉取、校验并安装更新。

## 在 DontsTool 中安装插件

DontsTool 已默认内置本官方插件源（`CrxusDonts/DontsTool-Plugins`）：

1. 打开 **DontsTool 设置 → 插件**。
2. 在「插件源」中点击 **DontsTool 官方插件仓库** 的刷新按钮（或直接点击「一键安装全部官方插件」）。
3. 也可手动添加自定义插件源：填写 `CrxusDonts/DontsTool-Plugins` 或 `https://github.com/CrxusDonts/DontsTool-Plugins/releases/latest/download/catalog.json`。
4. 在权限确认弹窗中核对插件申请的权限与 SHA-256 校验状态后点击「确认安装」，插件会立即热加载生效。

## 官方插件清单

| 插件 ID | 名称 | 触发关键词 | 运行模式 | 说明 |
| --- | --- | --- | --- | --- |
| `com.donts.kill-process` | 结束进程 | `kill`、`kp`、`进程` | `daemon` | 按名称、PID 或 `:端口` 检索并优雅退出/强制结束进程，支持批量结束与原地刷新 |
| `com.donts.idea-projects` | IDEA 项目 | `idea` | `daemon` | 解析 IntelliJ IDEA 最近项目（含指纹缓存），支持手动目录、访达定位与终端打开 |
| `com.donts.file-search` | 文件搜索 | `file` | `daemon`（`slow`） | 基于 Spotlight (`mdfind`) 限定主目录检索文件，支持文件分组、行内定位、复制路径与终端打开 |
| `com.donts.chrome` | Google Chrome | `chrome`、`ch`、`tab`、`tabs`、`标签页`、`bm`、`书签` | `daemon` | 检索并切换/关闭 Chrome 标签页，读取多 Profile 书签与历史记录，支持无痕窗口打开 |
| `com.donts.terminal-finder` | 终端与访达 | `tf`、`ft`、`term`、`终端` | `daemon` | 在访达与 Ghostty / Warp / iTerm2 / 终端 / WezTerm / Kitty / Alacritty 之间双向跳转目录 |
| `com.example.hello-sidecar` | Hello Sidecar 示例 | `hello` | `daemon`（Python） | 零依赖 Python 3 示例插件，演示多语言 Sidecar 协议实现 |

## 仓库结构

```text
DontsTool-Plugins/
├── Package.swift                        # SwiftPM 多目标定义（macOS 14+ / Swift 6）
├── catalog.json                         # 最新版本插件索引（含 downloadURL 与 SHA-256）
├── Sources/
│   ├── DontsToolPluginSDK/              # 公共 SDK：RPC DTO、NDJSON Daemon/Oneshot、FuzzyMatcher、进程执行器
│   ├── KillProcessCore/ & KillProcessPlugin/
│   ├── IDEProjectsCore/ & IDEProjectsPlugin/
│   ├── FileSearchCore/  & FileSearchPlugin/
│   ├── ChromeCore/      & ChromePlugin/
│   └── TerminalFinderCore/ & TerminalFinderPlugin/
├── plugins/
│   ├── com.donts.*/manifest.json        # 各插件清单（声明关键词、权限与入口）
│   └── com.example.hello-sidecar/       # Python 脚本插件完整示例
├── Tests/DontsToolPluginsTests/         # SDK 与全部 5 个插件的单元测试
├── scripts/build-release.sh             # 一键构建、签名、打包 zip 并生成 catalog.json
└── .github/workflows/release.yml        # CI 测试与 tag v* 自动发布 GitHub Release
```

## 本地构建与测试

要求 macOS 14+ 与 Swift 6 工具链：

```bash
# 运行全部单元测试
swift test

# 构建全部 Release 插件包并生成 dist/*.dontsplugin.zip 与 catalog.json
scripts/build-release.sh --version 1.0.0
```

## 开发新插件

DontsTool Sidecar 插件不限编程语言（Swift、Python、Node.js、Go、Rust 等均可），只需满足两点：

1. 在插件目录根目录提供 `manifest.json`（参考 [`plugins/com.example.hello-sidecar/manifest.json`](plugins/com.example.hello-sidecar/manifest.json)），通过 `runtime.command` 指向包内相对路径可执行文件（如 `["bin/run"]`）并声明所需最小权限集合。
2. 可执行入口通过 `stdin` 逐行读取 NDJSON JSON-RPC 2.0 请求（`search`、`execute`、`cancel`、`shutdown`），并通过 `stdout` 逐行写入响应并立即刷新缓冲区（参考 [`plugins/com.example.hello-sidecar/bin/run`](plugins/com.example.hello-sidecar/bin/run) 或 Swift SDK [`Sources/DontsToolPluginSDK/`](Sources/DontsToolPluginSDK/)）。

打包发布自己的第三方插件仓库时，只需将插件打为根目录含 `manifest.json` 的 `.dontsplugin.zip`，并在 GitHub Release 中提供符合 `schemaVersion: 1` 的 `catalog.json` 即可被 DontsTool 直接添加安装。

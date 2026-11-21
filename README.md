# DontsTool Plugins

[DontsTool](https://github.com/CrxusDonts/DontsTool) 的配套插件仓库，把平时自己会用到、但不想塞进主程序的几个小功能拆成了独立 Sidecar 插件，顺手一并开源。仓库采用 SwiftPM 多插件 Monorepo 结构，同时包含一个零依赖 Python 示例插件，通过标准 NDJSON over stdio（JSON-RPC 2.0）协议与主程序进程外通信。

关于完整的插件架构、协议字段、权限模型与第三方仓库规范，请参阅主仓库的 [插件使用与开发指南](https://github.com/CrxusDonts/DontsTool/blob/main/docs/plugins.md)。

## 在 DontsTool 中安装、更新与卸载

DontsTool `v0.3.0` 已默认内置本仓库（`CrxusDonts/DontsTool-Plugins`）作为官方插件源，无需额外配置即可使用：

1. 打开 **DontsTool 设置 → 插件**，页面会自动拉取「DontsTool 官方插件仓库」的最新目录（`releases/latest/download/catalog.json`）。
2. 在官方插件源顶部点击 **安装全部推荐插件** 可批量安装全部官方 Swift 插件，也可在下方列表中逐个点击 **安装**（包含示例插件 `com.example.hello-sidecar`）。
3. 每次安装或更新前，DontsTool 会先下载压缩包并核验 SHA-256 与 `manifest.json`，再弹出确认框列出插件版本、来源仓库、关键词及申请权限；点击确认后才会原子写入用户插件目录并热重载生效。
4. 如需手动重新添加本源或其他第三方仓库，可在 **添加插件源** 中输入 `CrxusDonts/DontsTool-Plugins`、GitHub 仓库链接或 `https://…/catalog.json` 地址，点击 **添加源**。
5. 在 **已安装插件** 区块中，可通过开关随时启用或停用插件、点击 **检查更新** / **更新** 升级到新版本，或点击 **卸载** 移除插件文件并立即停止其进程（已保存的插件偏好设置会保留）。

## 仓库插件清单

全部 6 个官方插件均以 Universal（`arm64` + `x86_64`）原生二进制打包发布，另附 1 个 Python 脚本示例插件供多语言开发参考：

| 插件 ID | 名称 | 触发关键词 | 功能简介 | 运行模式 | 声明权限 | 系统授权与运行说明 |
| --- | --- | --- | --- | --- | --- | --- |
| `com.donts.kill-process` | 结束进程 | `kill`、`kp`、`进程` | 按名称、PID、命令或 `:端口` 检索运行中的用户进程，支持优雅退出、`SIGKILL`、批量结束与原地刷新 | `daemon`（`fast`） | `clipboard.write`、`revealInFinder`、`prefill`、`toast`、`refresh` | 无需额外系统授权；仅列出并操作当前用户进程，自动排除宿主与自身 PID |
| `com.donts.idea-projects` | IDEA 项目 | `idea` | 解析 IntelliJ IDEA 最近项目（带文件指纹缓存），支持手动目录、访达定位、复制路径与在终端打开 | `daemon`（`fast`） | `clipboard.write`、`revealInFinder`、`openTerminal`、`openApplication`、`prefill`、`toast` | 无需额外系统授权；读取 `~/Library/Application Support/JetBrains/` 中的历史记录 |
| `com.donts.file-search` | 文件搜索 | `file` | 调用 Spotlight（`/usr/bin/mdfind`）在用户主目录内检索本地文件，结果归入原生文件分组，支持行内定位、复制路径与在终端打开 | `daemon`（`slow`） | `openFile`、`revealInFinder`、`clipboard.write`、`openTerminal`、`prefill`、`toast` | 依赖系统 Spotlight 索引；访问受保护目录时按需复用 macOS 文件访问或完全磁盘访问权限 |
| `com.donts.chrome` | Google Chrome | `chrome`、`ch`、`tab`、`tabs`、`标签页`、`bm`、`书签` | 检索、切换与关闭已打开标签页，读取多 Profile 书签与历史记录，支持普通或无痕窗口打开 | `daemon`（`fast`） | `clipboard.write`、`openURL`、`prefill`、`toast`、`refresh` | 读取/控制标签页需在「系统设置 → 隐私与安全性 → 自动化」中允许 DontsTool 控制 Google Chrome；历史记录通过临时副本只读访问，不锁定浏览器数据库 |
| `com.donts.terminal-finder` | 终端与访达 | `tf`、`ft`、`term`、`终端` | 在访达与 Ghostty / Warp / iTerm2 / 系统终端 / WezTerm / Kitty / Alacritty / OrcaTerm 之间双向跳转当前目录，支持 `tf ~/Desktop` 直接路径 | `daemon`（`fast`） | `clipboard.write`、`openFile`、`revealInFinder`、`openTerminal`、`openApplication`、`prefill`、`toast` | 读取访达、iTerm2 或系统「终端」路径需 macOS「自动化」权限；其余终端通过进程树工作目录自动识别，并读取宿主首选终端设置 |
| `com.donts.quick-ai` | AI 快问 | `ai`、`ask`、`问` | 通过自由提问或 5 个预设场景（`code`/`fix`/`polish`/`cmd`/`sum`）调用宿主大模型，在原生流式窗口中即时问答 | `daemon`（`fast`） | `openAI`、`prefill` | 需要 DontsTool `0.4.0+`，并在宿主 **设置 → AI 与翻译** 中配置大模型服务；插件本身不联网也不接触 API 密钥 |
| `com.example.hello-sidecar` | Hello Sidecar 示例 | `hello` | 演示多语言 NDJSON JSON-RPC 2.0 协议、剪贴板写入与 `execute` 回调的最小示例 | `daemon`（`fast`，Python） | `clipboard.write`、`prefill`、`toast` | 无需额外系统授权；依赖本机 `python3`（在目录中标记为非官方示例，不随「安装全部推荐插件」自动安装） |

## 仓库结构

```text
DontsTool-Plugins/
├── Package.swift                             # SwiftPM 配置（macOS 14+ / Swift 6）
├── catalog.json                              # 最新已发布版本的插件目录与 SHA-256 校验索引
├── Sources/
│   ├── DontsToolPluginSDK/                   # 共享 SDK：RPC DTO、NDJSON 读写循环、FuzzyMatcher、带超时/取消的命令执行器
│   ├── KillProcessCore/ & KillProcessPlugin/
│   ├── IDEProjectsCore/ & IDEProjectsPlugin/
│   ├── FileSearchCore/  & FileSearchPlugin/
│   ├── ChromeCore/      & ChromePlugin/
│   ├── TerminalFinderCore/ & TerminalFinderPlugin/
│   └── QuickAICore/     & QuickAIPlugin/
├── plugins/
│   ├── com.donts.kill-process/manifest.json
│   ├── com.donts.idea-projects/manifest.json
│   ├── com.donts.file-search/manifest.json
│   ├── com.donts.chrome/manifest.json
│   ├── com.donts.terminal-finder/manifest.json
│   ├── com.donts.quick-ai/manifest.json
│   └── com.example.hello-sidecar/            # Python 脚本插件源码与清单
│       ├── manifest.json
│       └── bin/run
├── Tests/DontsToolPluginsTests/              # SDK 与全部 6 个 Swift 插件的单元测试
├── scripts/build-release.sh                  # 构建、ad-hoc 签名、打包 zip 并生成 catalog.json
└── .github/workflows/release.yml             # CI 测试、冒烟校验与 tag v* 自动发版
```

## 新增插件

所有用户插件均放置在 `plugins/<plugin-id>/` 下，清单一律使用 `schemaVersion: 1`，以包内相对路径声明入口（如 `"command": ["bin/MyPlugin"]`），不得使用内置保留字段 `legacyProviderID` 或 `$HOST_HELPERS/`。

### 1. 新增 Swift 插件

1. 在 `Package.swift` 中添加一个 `*Core` 库目标（依赖 `DontsToolPluginSDK`）和一个薄入口可执行目标 `*Plugin`（依赖 `DontsToolPluginSDK` 与 `*Core`），方便单元测试直接导入 `*Core`。
2. 在 `Sources/<Name>Core/` 中实现 `PluginEngine` 协议的 `search(_:)` 与可选的 `execute(_:)` 方法；在 `Sources/<Name>Plugin/` 的 `@main` 入口调用 `SidecarRuntime.runDaemon(engine:)` 或 `SidecarRuntime.runOneshot(engine:)`。
3. 在 `plugins/<plugin-id>/manifest.json` 中声明插件 ID、关键词、运行模式、`command: ["bin/<ExecutableName>"]` 及所需最小权限集。
4. 在 `Tests/DontsToolPluginsTests/` 补充对应单元测试（并同步更新 `SDKRuntimeTests.testAllPluginManifestsAreValidUserPlugins` 中的预期插件清单），并在 `scripts/build-release.sh` 的 `SWIFT_PLUGINS` 数组中登记打包条目。

### 2. 新增任意脚本语言插件

Sidecar 协议不限制语言（Python、Node.js、Go、Rust、Shell 等均可），只要可执行入口从 `stdin` 逐行读取 NDJSON JSON-RPC 2.0 消息（处理 `search`、`execute`、`cancel`、`shutdown`），并将单行 JSON 响应写入 `stdout` 后立即 flush 即可：

1. 参考 [`plugins/com.example.hello-sidecar/manifest.json`](plugins/com.example.hello-sidecar/manifest.json) 与 [`plugins/com.example.hello-sidecar/bin/run`](plugins/com.example.hello-sidecar/bin/run) 创建 `plugins/<plugin-id>/`。
2. 确保入口脚本具备可执行权限（`chmod +x plugins/<plugin-id>/bin/run`）。
3. 在 `scripts/build-release.sh` 的 `SCRIPT_PLUGINS` 数组中登记该插件，并在测试中补充校验。

详细协议格式、可用 `effect.kind` 与 `hostContext` 约定见主仓库 [docs/plugins.md](https://github.com/CrxusDonts/DontsTool/blob/main/docs/plugins.md)。

## 本地开发、软链接调试与打包验证

本地构建要求 macOS 14+ 与 Swift 6 工具链：

```bash
# 运行全部单元测试
swift test

# 仅构建本机架构 Release 包（本地开发验证更快）
./scripts/build-release.sh --version 1.0.0 --native

# 构建 Universal（arm64 + x86_64）Release 包并刷新 dist/ 与根目录 catalog.json
./scripts/build-release.sh --version 1.0.0
```

脚本会对所有 Swift 二进制执行 `codesign --force --sign -`（ad-hoc 签名，满足 Apple Silicon 运行要求），将每个插件打包为根目录直接包含 `manifest.json` 与 `bin/` 的 `dist/<plugin-id>-<version>-macos.dontsplugin.zip`，并计算真实 SHA-256 写入 `dist/catalog.json` 与根目录 `catalog.json`。

### 在本机 DontsTool 中调试

DontsTool 扫描 `~/Library/Application Support/DontsTool/Plugins/` 下的每个子目录，并在校验时阻止入口文件通过符号链接逃逸出插件目录之外：

- 调试脚本插件时，可直接把整个插件目录软链接进用户插件目录：

  ```bash
  mkdir -p "$HOME/Library/Application Support/DontsTool/Plugins"
  ln -s "$PWD/plugins/com.example.hello-sidecar" \
    "$HOME/Library/Application Support/DontsTool/Plugins/com.example.hello-sidecar"
  ```

- 调试 Swift 插件时，先运行 `./scripts/build-release.sh --version 1.0.0 --native`，再用 `ditto -xk` 解压到用户插件目录（不要单独把 `bin/<Exec>` 软链接到 `.build/`，否则会被路径越界防护拦截）：

  ```bash
  ditto -xk dist/com.donts.kill-process-1.0.0-macos.dontsplugin.zip \
    "$HOME/Library/Application Support/DontsTool/Plugins/com.donts.kill-process"
  ```

完成后，在 **DontsTool 设置 → 插件** 点击 **重新加载** 即可立即生效。也可以直接通过管道在命令行做协议冒烟测试：

```bash
printf '%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"search","params":{"mode":"keyword","keyword":"hello","query":"DontsTool","rawQuery":"hello DontsTool","preferences":{},"hostContext":{"hostVersion":"0.3.0"}}}' \
  '{"jsonrpc":"2.0","method":"shutdown","params":{}}' \
  | ./plugins/com.example.hello-sidecar/bin/run
```

## 自动发版流程

仓库通过 [`.github/workflows/release.yml`](.github/workflows/release.yml) 在 `macos-15` 上运行 CI 与发版：

- 推送到 `main` 或发起 Pull Request 时，自动执行 `swift test`、Universal 构建打包与全量插件 `ditto -xk` 解压后的 NDJSON 冒烟测试。
- 需要发布新版本（例如 `1.1.0`）时，先确保 `main` 上的变更与各 `manifest.json` 版本号已就绪，再推送 `v*` 标签触发自动发版：

  ```bash
  git tag -a v1.1.0 -m "Release v1.1.0"
  git push origin v1.1.0
  ```

工作流会自动构建全部 Universal 插件包与 `catalog.json`，验证通过后创建对应的 GitHub Release 并上传全部 `.dontsplugin.zip` 与 `catalog.json`（若该标签对应的 Release 已包含产物，工作流会跳过覆盖，避免破坏已发布的 SHA-256）。

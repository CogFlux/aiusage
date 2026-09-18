# AIUsage

[English](README.md) · 中文

macOS 菜单栏里显示 Claude 订阅额度（5 小时 / 7 天窗口）以及 **pace**：按"窗口结束时恰好用到 99%"
的均速折算，现在应该用到多少、实际用了多少、超了还是省了、照这个速度什么时候用完。

```
5h 42% ▲9      ← 已用 42%，比均速预算多 9 个点（红）
5h 42% ▼3      ← 比预算少 3 个点（绿）
5h 42% ●       ← 在 ±5 以内
5h 0% ↺        ← 窗口已重置，等下一次数据
5h 42% ● ⧗     ← 数据超过 30 分钟没更新
```

## 数据从哪来

| 来源 | 成本 | 时效 |
|---|---|---|
| **Claude Code statusline 钩子**（默认） | 0 | 有会话在跑时实时；空闲时每 60s 刷一次 |
| **主动查询**（菜单里的按钮） | 一次极小的 Haiku 请求，约 500 tokens ≈ $0.001 API 等价；Max 套餐内不另收费 | 即时 |

两条路都走 Claude Code 官方暴露的接口，不碰 OAuth token，不抓网页。细节见 [docs/data-contract.md](docs/data-contract.md)。

主动查询的副作用：如果当前没有活跃的 5h 窗口，它会开启一个新窗口。

## 更新

打包发布的版本通过 [Sparkle](https://sparkle-project.org) 检查更新（EdDSA 签名的 appcast 位于
`aiusage.cogflux.io/appcast.xml`）。在 设置 → 通用 里可开关自动检查或手动检查。

## 设置

菜单里的齿轮 → 设置窗口。

- **通用**：语言、菜单栏显示哪个窗口（5h / 7d）、精简菜单栏（只显示 `42%`）、登录时启动、
  通知（超速 / 重置前用尽 / 5 小时窗口重置，附测试按钮）、更新检查。
- **Claude Code**：钩子状态与安装、是否让钩子同时在 Claude Code 自己的状态栏打印一行用量（仅在你原本没有状态栏时；下次刷新生效，无需重启）、`claude` 路径。

## 语言

界面默认英文；菜单底部可切换 English / 中文 / 跟随系统（系统首选语言以 `zh` 开头时用中文）。
所有文案集中在 `Sources/AIUsage/Localization.swift` 的 `Strings` 表里，两种语言各一份，少一个 key 编译不过。
`AIUsageCore` 本身不含任何语言相关文案。

## 安装

从 [最新 release](https://github.com/CogFlux/aiusage/releases/latest) 下载 `AIUsage.zip`（universal，macOS 14+），
把 `AIUsage.app` 拖进"应用程序"。目前未签名，首次打开会被 macOS 拦截：去 **系统设置 → 隐私与安全性 → 仍要打开**，
或执行 `xattr -dr com.apple.quarantine /Applications/AIUsage.app`。

## 构建与运行

需要 macOS 14+ 和 Swift 工具链（Command Line Tools 自带的就够，不需要 Xcode）。

```bash
swift run AIUsageCoreChecks   # 跑测试
scripts/build-app.sh          # → build/AIUsage.app（加 --universal 出 arm64 + x86_64）
scripts/release.sh 0.1.0      # 打 tag、universal 构建、zip、GitHub release
open build/AIUsage.app
```

首次运行后在菜单里点"安装"装钩子，或者命令行：

```bash
hook/install.sh               # 安装 / 更新
hook/install.sh --uninstall   # 卸载并还原原有 statusLine
```

安装会备份 `~/.claude/settings.json`（`settings.json.aiusage-backup-<时间>`），原有的 statusline 命令会保存到
`~/Library/Application Support/AIUsage/chain-command` 并继续执行。

## 结构

```
Sources/AIUsageCore/     纯逻辑，无 UI 依赖：模型、pace 算法、两个解析器、文本格式化（可移植部分）
Sources/AIUsage/         菜单栏 App：文件监听、claude -p 探测、钩子安装、语言表、SwiftUI 视图
Sources/AIUsage/Resources/aiusage-statusline.sh   钩子脚本本体
Tests/AIUsageCoreChecks/ 测试（独立可执行，因 CLT 没有 XCTest）
hook/install.sh          钩子的命令行安装器
scripts/build-app.sh     打 .app 包
docs/data-contract.md    数据格式与算法规范
```

## 许可证

MIT，见 [LICENSE](LICENSE)。

## 路线

- [x] Claude：statusline 被动 + `claude -p` 主动
- [x] 应用内更新（Sparkle）
- [ ] 菜单栏同时显示 5h 和 7d
- [ ] 其他 provider（Codex / Cursor …）——只需产出同样的 `UsageSnapshot`
- [x] 开机自启、通知（超速 / 即将用尽 / 窗口重置）

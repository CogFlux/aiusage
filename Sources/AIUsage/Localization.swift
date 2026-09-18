import AIUsageCore
import Foundation

/// User-facing language setting. `.system` follows the macOS preferred language.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case zh

    var id: String { rawValue }

    var resolved: ResolvedLanguage {
        switch self {
        case .en: return .en
        case .zh: return .zh
        case .system:
            let preferred = Locale.preferredLanguages.first ?? "en"
            return preferred.hasPrefix("zh") ? .zh : .en
        }
    }
}

enum ResolvedLanguage: String {
    case en
    case zh

    var locale: Locale {
        switch self {
        case .en: return Locale(identifier: "en_US")
        case .zh: return Locale(identifier: "zh_Hans")
        }
    }
}

/// Every string the app shows. One instance per language; the memberwise initializer
/// forces both tables to define every key, so a missing translation is a compile error.
struct Strings {
    // Header
    let waitingForData: String
    let sourceStatusline: String
    let sourceProbe: String

    // Windows
    let fiveHourTitle: String
    let sevenDayTitle: String
    let resetsLine: (_ time: String, _ countdown: String) -> String
    let used: String
    let budget: String
    let delta: String
    let projected: String
    let runout: String
    let exhausted: String
    let tooEarlyNote: String
    let resetNote: String
    let noData: String

    // Claude Code availability
    let claudeCodeMissingTitle: String
    let claudeCodeMissingBody: String
    let installClaudeCode: String
    let noQuotaInData: String

    // Probe
    let probeNow: String
    let probeHint: String
    let probeClaudeNotInstalled: String
    let probeClaudePathInvalid: String
    let probeTimeout: String
    let probeNotLoggedIn: String
    let probeExited: (_ code: Int32, _ stderrTail: String) -> String
    let probeNoEvent: String

    // Hook
    let hookInstalled: String
    let hookNotInstalled: String
    let install: String
    let reinstall: String
    let hookHint: String
    let hookResourceMissing: String
    let hookSettingsNotObject: String

    // Settings
    let settings: String
    let general: String
    let claudeCode: String
    let menuBarShows: String
    let compactMenuBar: String
    let compactMenuBarHint: String
    let language: String
    let languageSystem: String
    let showInClaudeCode: String
    let showInClaudeCodeHint: String
    let claudePath: String
    let claudePathPlaceholder: String
    let quit: String

    /// Read by error types that have no access to the store. The store keeps it in sync.
    nonisolated(unsafe) static var current: Strings = .en

    static func forLanguage(_ language: ResolvedLanguage) -> Strings {
        switch language {
        case .en: return .en
        case .zh: return .zh
        }
    }

    func windowTitle(_ kind: AIUsageCore.WindowKind) -> String {
        switch kind {
        case .fiveHour: return fiveHourTitle
        case .sevenDay: return sevenDayTitle
        }
    }

    static let en = Strings(
        waitingForData: "Waiting for data",
        sourceStatusline: "statusline",
        sourceProbe: "probe",

        fiveHourTitle: "5-hour window",
        sevenDayTitle: "7-day window",
        resetsLine: { time, countdown in "Resets \(time) · in \(countdown)" },
        used: "Used",
        budget: "Budget",
        delta: "Delta",
        projected: "Projected",
        runout: "Runs out",
        exhausted: "Exhausted",
        tooEarlyNote: "Window just started; no projection yet",
        resetNote: "Window has reset; waiting for new data",
        noData: "No data",

        claudeCodeMissingTitle: "Claude Code not found",
        claudeCodeMissingBody: "AIUsage reads your quota through Claude Code, which is not installed on this Mac (or is not on your PATH — set its location in Settings → Claude Code).",
        installClaudeCode: "Install Claude Code",
        noQuotaInData: "Claude Code is running but reports no subscription quota. Rate limits only exist for Claude Pro and Max accounts; API-key accounts have nothing to show.",

        probeNow: "Query now",
        probeHint: "Sends one tiny Haiku request (~500 tokens, ≈ $0.001 API-equivalent). Included in a Max subscription; uses a negligible slice of quota. If no window is active, this starts a new 5-hour window.",
        probeClaudeNotInstalled: "Claude Code is not installed, or not on your PATH. Install it, or set its location in Settings → Claude Code.",
        probeClaudePathInvalid: "The claude path in Settings does not point to an executable.",
        probeTimeout: "Query timed out (60s)",
        probeNotLoggedIn: "Claude Code is installed but not signed in. Open Terminal, run `claude`, and sign in with your Claude Pro or Max account.",
        probeExited: { code, tail in "claude exited with code \(code)" + (tail.isEmpty ? "" : ": \(tail)") },
        probeNoEvent: "No rate_limit_event in output (API-key accounts have no subscription quota)",

        hookInstalled: "Statusline hook installed",
        hookNotInstalled: "Statusline hook not installed",
        install: "Install",
        reinstall: "Reinstall",
        hookHint: "The hook mirrors the JSON Claude Code feeds its status line into a local file that this app watches — passive and free. Installing backs up ~/.claude/settings.json and keeps your existing status line command running.",
        hookResourceMissing: "aiusage-statusline.sh is missing from the app bundle",
        hookSettingsNotObject: "~/.claude/settings.json is not a JSON object",

        settings: "Settings",
        general: "General",
        claudeCode: "Claude Code",
        menuBarShows: "Menu bar window",
        compactMenuBar: "Compact menu bar",
        compactMenuBarHint: "Show only the percentage (\"42%\") instead of \"5h 42% ▲9\". For crowded menu bars.",
        language: "Language",
        languageSystem: "System",
        showInClaudeCode: "Show usage line in Claude Code",
        showInClaudeCodeHint: "Prints \"[Opus] ctx 20% · 5h 19% · 7d 17%\" in Claude Code's status line. Only applies when you had no status line of your own. Changes show up within about a minute — Claude Code re-runs the status line on its next response or its 60-second timer. No restart needed.",
        claudePath: "claude path",
        claudePathPlaceholder: "Not found — enter full path",
        quit: "Quit"
    )

    static let zh = Strings(
        waitingForData: "等待数据",
        sourceStatusline: "statusline",
        sourceProbe: "主动查询",

        fiveHourTitle: "5 小时窗口",
        sevenDayTitle: "7 天窗口",
        resetsLine: { time, countdown in "重置 \(time) · \(countdown) 后" },
        used: "已用",
        budget: "预算",
        delta: "偏差",
        projected: "预计",
        runout: "用尽",
        exhausted: "已用尽",
        tooEarlyNote: "窗口刚开始，暂不投影",
        resetNote: "窗口已重置，等待下一次数据",
        noData: "暂无数据",

        claudeCodeMissingTitle: "未找到 Claude Code",
        claudeCodeMissingBody: "AIUsage 通过 Claude Code 读取额度，但这台 Mac 上没有安装它（或它不在 PATH 里——可在 设置 → Claude Code 指定位置）。",
        installClaudeCode: "安装 Claude Code",
        noQuotaInData: "Claude Code 在运行，但没有上报订阅额度。只有 Claude Pro / Max 账户才有速率限制窗口；API key 账户没有可显示的内容。",

        probeNow: "立即查询",
        probeHint: "发送一次极小的 Haiku 请求（约 500 tokens，≈ $0.001 API 等价）。Max 套餐内不另收费，只消耗极少量额度；若当前没有活跃窗口，会启动一个新的 5 小时窗口。",
        probeClaudeNotInstalled: "未安装 Claude Code，或它不在 PATH 里。请安装，或在 设置 → Claude Code 指定位置。",
        probeClaudePathInvalid: "设置里填写的 claude 路径不是可执行文件。",
        probeTimeout: "查询超时（60s）",
        probeNotLoggedIn: "已安装 Claude Code 但尚未登录。请在终端运行 `claude`，用你的 Claude Pro / Max 账户登录。",
        probeExited: { code, tail in "claude 退出码 \(code)" + (tail.isEmpty ? "" : "：\(tail)") },
        probeNoEvent: "输出里没有 rate_limit_event（API key 用户没有订阅额度）",

        hookInstalled: "statusline 钩子已安装",
        hookNotInstalled: "未安装 statusline 钩子",
        install: "安装",
        reinstall: "重新安装",
        hookHint: "钩子把 Claude Code 喂给状态栏的 JSON 镜像到本地文件，App 被动读取，零成本。安装前会备份 ~/.claude/settings.json，原有的状态栏命令会被保留并继续执行。",
        hookResourceMissing: "App 包里缺少 aiusage-statusline.sh",
        hookSettingsNotObject: "~/.claude/settings.json 不是 JSON 对象",

        settings: "设置",
        general: "通用",
        claudeCode: "Claude Code",
        menuBarShows: "菜单栏显示窗口",
        compactMenuBar: "精简菜单栏",
        compactMenuBarHint: "只显示百分比（\"42%\"），不显示 \"5h 42% ▲9\"。菜单栏拥挤时使用。",
        language: "语言",
        languageSystem: "跟随系统",
        showInClaudeCode: "在 Claude Code 里显示用量行",
        showInClaudeCodeHint: "在 Claude Code 状态栏打印 \"[Opus] ctx 20% · 5h 19% · 7d 17%\"。仅在你原本没有自己的状态栏时生效。切换后约一分钟内生效——Claude Code 在下一条回复或 60 秒定时器到时重跑状态栏。无需重启。",
        claudePath: "claude 路径",
        claudePathPlaceholder: "未找到，请填写完整路径",
        quit: "退出"
    )
}

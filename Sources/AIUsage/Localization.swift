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
    /// "Too early to project; projection from <time>"
    let tooEarlyNote: (_ from: String) -> String
    let resetNote: String
    let noData: String
    let windowIdle: String
    let repaceFromNow: String
    let repaceHelp: String
    /// "Pacing the remaining X% since <time>"
    let repacedSince: (_ remaining: String, _ since: String) -> String
    /// "overall ▲32": the delta against the original, un-re-paced budget
    let repaceOverall: (_ marker: String) -> String
    let repaceClear: String

    // Claude Code availability
    let claudeCodeMissingTitle: String
    let claudeCodeMissingBody: String
    let installClaudeCode: String
    let noQuotaInData: String
    let precisionNote: String

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

    // DeepSeek
    let deepseekBudgetTitle: String
    let deepseekEnable: String
    let deepseekEnableHint: String
    let deepseekAPIKey: String
    let deepseekAPIKeyHint: String
    let deepseekAPIKeySaved: String
    let deepseekSave: String
    let deepseekRefresh: String
    let deepseekMonthlyBudget: String
    let deepseekMonthlyBudgetHint: String
    let deepseekMonthlyBudgetAmount: String
    let deepseekLowBalance: String
    let deepseekNotifyLowBalance: String
    let deepseekBalance: String
    let deepseekToday: String
    let deepseekThisMonth: String
    let deepseekPerDay: String
    let deepseekPerDayBasis: (_ span: String) -> String
    let justNow: String
    let deepseekRunsOut: String
    let deepseekGathering: String
    let deepseekNoKey: String
    let deepseekUnauthorized: String
    let deepseekMalformed: String
    let deepseekSpent: String
    let alertLowBalanceTitle: String
    let alertLowBalanceBody: (_ amount: String, _ runout: String?) -> String

    // Startup & notifications
    let launchAtLogin: String
    let notifications: String
    let notifyOverPace: String
    let notifyRunningOut: String
    let notifyWindowReset: String
    let notificationsDenied: String
    let sendTestNotification: String
    let notificationsBannersOff: String
    let openNotificationSettings: String
    let alertOverPaceTitle: (_ window: String) -> String
    let alertOverPaceBody: (_ used: String, _ delta: String, _ projected: String, _ resetTime: String) -> String
    let alertRunningOutTitle: (_ window: String) -> String
    let alertRunningOutBody: (_ runoutTime: String, _ resetTime: String) -> String
    let alertResetTitle: (_ window: String) -> String
    let alertResetBody: String

    // Updates
    let updates: String
    let checkForUpdates: String
    let autoCheckForUpdates: String
    let updatesUnavailable: String

    // Settings
    let settings: String
    let general: String
    let claudeCode: String
    let menuBarShows: String
    let menuBarProvider: String
    let compactMenuBar: String
    let compactMenuBarHint: String
    let language: String
    let languageSystem: String
    let languageRelaunchHint: String
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
        tooEarlyNote: { from in "Too early to project; projection from \(from)" },
        resetNote: "Window has reset; waiting for new data",
        noData: "No data",
        windowIdle: "No active window. Your next message to Claude starts a new one.",
        repaceFromNow: "Re-pace from now",
        repaceHelp: "Treat what is used so far as spent and spread the remainder evenly over the time left.",
        repacedSince: { remaining, since in "Pacing the remaining \(remaining) since \(since)" },
        repaceOverall: { marker in "overall \(marker)" },
        repaceClear: "Clear",

        claudeCodeMissingTitle: "Claude Code not found",
        claudeCodeMissingBody: "AIUsage reads your quota through Claude Code, which is not installed on this Mac (or is not on your PATH — set its location in Settings → Claude Code).",
        installClaudeCode: "Install Claude Code",
        noQuotaInData: "Claude Code is running but reports no subscription quota. Rate limits only exist for Claude Pro and Max accounts; API-key accounts have nothing to show.",
        precisionNote: "Percentages come from Claude's rate-limit headers, which report whole points rounded down. Claude Code's /usage screen may read up to one point higher.",

        probeNow: "Query now",
        probeHint: "Sends one tiny Haiku request (~500 tokens, ≈ $0.001 API-equivalent). Covered by your Pro or Max subscription; uses a negligible slice of quota. If no window is active, this starts a new 5-hour window.",
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

        deepseekBudgetTitle: "DeepSeek monthly budget",
        deepseekEnable: "Track DeepSeek balance",
        deepseekEnableHint: "Polls the balance endpoint every 5 minutes. It is free and sends no model requests; spend is derived from balance changes, so amounts under ¥0.01 show up once they accumulate.",
        deepseekAPIKey: "API key",
        deepseekAPIKeyHint: "Stored in ~/Library/Application Support/AIUsage/deepseek.key (owner-only permissions) and sent only to api.deepseek.com/user/balance.",
        deepseekAPIKeySaved: "Key saved",
        deepseekSave: "Save",
        deepseekRefresh: "Refresh now",
        deepseekMonthlyBudget: "Monthly budget",
        deepseekMonthlyBudgetHint: "Pace the month like a Claude window: an even-pace line, over/under markers and the same notifications.",
        deepseekMonthlyBudgetAmount: "Amount per month",
        deepseekLowBalance: "Low-balance threshold",
        deepseekNotifyLowBalance: "Notify when the balance drops below the threshold",
        deepseekBalance: "Balance",
        deepseekToday: "Today",
        deepseekThisMonth: "This month",
        deepseekPerDay: "/day",
        deepseekPerDayBasis: { "/day (\($0))" },
        justNow: "just now",
        deepseekRunsOut: "Runs out",
        deepseekGathering: "Gathering history — the daily burn rate appears after a full day, so one afternoon isn't mistaken for a whole day.",
        deepseekNoKey: "Add your DeepSeek API key in Settings → DeepSeek.",
        deepseekUnauthorized: "DeepSeek rejected the API key (401).",
        deepseekMalformed: "Unexpected response from DeepSeek.",
        deepseekSpent: "Spent",
        alertLowBalanceTitle: "DeepSeek balance low",
        alertLowBalanceBody: { amount, runout in runout.map { "\(amount) left — runs out around \($0) at the current rate." } ?? "\(amount) left." },

        launchAtLogin: "Launch at login",
        notifications: "Notifications",
        notifyOverPace: "When a window goes over pace",
        notifyRunningOut: "When quota will run out before the reset",
        notifyWindowReset: "When the 5-hour window resets",
        notificationsDenied: "Notifications are turned off for AIUsage in System Settings → Notifications.",
        sendTestNotification: "Send test notification",
        notificationsBannersOff: "Notifications are allowed but the alert style is \"None\", so they only appear in Notification Center. Choose Banners or Alerts in System Settings.",
        openNotificationSettings: "Open System Settings",
        alertOverPaceTitle: { "\($0) over pace" },
        alertOverPaceBody: { used, delta, projected, reset in "\(used) used, \(delta) vs budget. Heading for \(projected) by the reset at \(reset)." },
        alertRunningOutTitle: { "\($0) running out" },
        alertRunningOutBody: { runout, reset in "At the current rate you hit the limit at \(runout), before the reset at \(reset)." },
        alertResetTitle: { "\($0) reset" },
        alertResetBody: "Fresh quota is available.",

        updates: "Updates",
        checkForUpdates: "Check for Updates…",
        autoCheckForUpdates: "Check for updates automatically",
        updatesUnavailable: "Update checks are only available in packaged release builds.",

        settings: "Settings",
        general: "General",
        claudeCode: "Claude Code",
        menuBarShows: "Menu bar window",
        menuBarProvider: "Menu bar shows",
        compactMenuBar: "Compact menu bar",
        compactMenuBarHint: "Show only the percentage (\"42%\") instead of \"5h 42% ▲9\". For crowded menu bars.",
        language: "Language",
        languageSystem: "System",
        languageRelaunchHint: "Update dialogs follow the new language after a relaunch.",
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
        tooEarlyNote: { from in "刚开始，暂不投影；\(from) 起显示预计" },
        resetNote: "窗口已重置，等待下一次数据",
        noData: "暂无数据",
        windowIdle: "当前没有活跃窗口。下一条发给 Claude 的消息会开启新窗口。",
        repaceFromNow: "从现在开始平均",
        repaceHelp: "把已用的部分视为沉没，只把余量平均分到剩余时间。",
        repacedSince: { remaining, since in "自 \(since) 起平均剩余 \(remaining)" },
        repaceOverall: { marker in "整体 \(marker)" },
        repaceClear: "清除",

        claudeCodeMissingTitle: "未找到 Claude Code",
        claudeCodeMissingBody: "AIUsage 通过 Claude Code 读取额度，但这台 Mac 上没有安装它（或它不在 PATH 里——可在 设置 → Claude Code 指定位置）。",
        installClaudeCode: "安装 Claude Code",
        noQuotaInData: "Claude Code 在运行，但没有上报订阅额度。只有 Claude Pro / Max 账户才有速率限制窗口；API key 账户没有可显示的内容。",
        precisionNote: "百分比来自 Claude 的速率限制响应头，只有整数精度且向下取整；Claude Code 的 /usage 可能比这里高 1 个点。",

        probeNow: "立即查询",
        probeHint: "发送一次极小的 Haiku 请求（约 500 tokens，≈ $0.001 API 等价）。Pro / Max 套餐内不另收费，只消耗极少量额度；若当前没有活跃窗口，会启动一个新的 5 小时窗口。",
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

        deepseekBudgetTitle: "DeepSeek 月预算",
        deepseekEnable: "跟踪 DeepSeek 余额",
        deepseekEnableHint: "每 5 分钟查询一次余额接口。免费、不发任何模型请求；花费由余额变化推算，不足 ¥0.01 的消耗会在累计后显示。",
        deepseekAPIKey: "API key",
        deepseekAPIKeyHint: "保存在 ~/Library/Application Support/AIUsage/deepseek.key（仅本用户可读），只会发送到 api.deepseek.com/user/balance。",
        deepseekAPIKeySaved: "已保存",
        deepseekSave: "保存",
        deepseekRefresh: "立即刷新",
        deepseekMonthlyBudget: "月预算",
        deepseekMonthlyBudgetHint: "把本月当作 Claude 窗口一样做 pace：匀速线、超/省标记和同样的通知。",
        deepseekMonthlyBudgetAmount: "每月金额",
        deepseekLowBalance: "余额不足阈值",
        deepseekNotifyLowBalance: "余额低于阈值时通知",
        deepseekBalance: "余额",
        deepseekToday: "今日",
        deepseekThisMonth: "本月",
        deepseekPerDay: "每天",
        deepseekPerDayBasis: { "每天 (\($0))" },
        justNow: "刚刚",
        deepseekRunsOut: "用尽",
        deepseekGathering: "正在积累历史。满一天后才显示每日燃烧率，避免把一个下午的用量当成全天。",
        deepseekNoKey: "请在 设置 → DeepSeek 填入 API key。",
        deepseekUnauthorized: "DeepSeek 拒绝了这个 API key（401）。",
        deepseekMalformed: "DeepSeek 返回了意外的内容。",
        deepseekSpent: "已花",
        alertLowBalanceTitle: "DeepSeek 余额不足",
        alertLowBalanceBody: { amount, runout in runout.map { "剩余 \(amount)，按当前速度约 \($0) 用完。" } ?? "剩余 \(amount)。" },

        launchAtLogin: "登录时启动",
        notifications: "通知",
        notifyOverPace: "窗口超速时",
        notifyRunningOut: "额度将在重置前用完时",
        notifyWindowReset: "5 小时窗口重置时",
        notificationsDenied: "AIUsage 的通知已在 系统设置 → 通知 中被关闭。",
        sendTestNotification: "发送测试通知",
        notificationsBannersOff: "通知已允许，但提示样式为\"无\"，所以只会出现在通知中心里不会弹出。请在系统设置里改为\"横幅\"或\"提醒\"。",
        openNotificationSettings: "打开系统设置",
        alertOverPaceTitle: { "\($0)超速" },
        alertOverPaceBody: { used, delta, projected, reset in "已用 \(used)，比预算 \(delta)。按此速度到 \(reset) 重置时将达 \(projected)。" },
        alertRunningOutTitle: { "\($0)即将用尽" },
        alertRunningOutBody: { runout, reset in "按当前速度将在 \(runout) 触顶，早于 \(reset) 的重置。" },
        alertResetTitle: { "\($0)已重置" },
        alertResetBody: "额度已刷新。",

        updates: "更新",
        checkForUpdates: "检查更新…",
        autoCheckForUpdates: "自动检查更新",
        updatesUnavailable: "只有打包的正式版才能检查更新。",

        settings: "设置",
        general: "通用",
        claudeCode: "Claude Code",
        menuBarShows: "菜单栏显示窗口",
        menuBarProvider: "菜单栏显示",
        compactMenuBar: "精简菜单栏",
        compactMenuBarHint: "只显示百分比（\"42%\"），不显示 \"5h 42% ▲9\"。菜单栏拥挤时使用。",
        language: "语言",
        languageSystem: "跟随系统",
        languageRelaunchHint: "更新对话框在重新启动后才切换语言。",
        showInClaudeCode: "在 Claude Code 里显示用量行",
        showInClaudeCodeHint: "在 Claude Code 状态栏打印 \"[Opus] ctx 20% · 5h 19% · 7d 17%\"。仅在你原本没有自己的状态栏时生效。切换后约一分钟内生效——Claude Code 在下一条回复或 60 秒定时器到时重跑状态栏。无需重启。",
        claudePath: "claude 路径",
        claudePathPlaceholder: "未找到，请填写完整路径",
        quit: "退出"
    )
}

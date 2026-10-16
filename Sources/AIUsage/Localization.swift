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
    let sourceOAuth: String

    // Windows
    let fiveHourTitle: String
    let sevenDayTitle: String
    let monthTitle: String
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
    /// "36% left · re-paced 1d 3h ago"
    let repacedSince: (_ remaining: String, _ ago: String) -> String
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
    let claudeEnable: String
    let claudeEnableHint: String
    let probeNow: String
    let probeHint: String
    let probeClaudeNotInstalled: String
    let probeClaudePathInvalid: String
    let probeTimeout: String
    let probeNotLoggedIn: String
    let probeExited: (_ code: Int32, _ stderrTail: String) -> String
    let probeNoEvent: String

    // OAuth query
    let oauthEnable: String
    let oauthEnableHint: String
    let oauthRefreshHint: String
    let oauthReread: String
    let oauthRereadHint: String
    let oauthNoCredentials: String
    let oauthKeychainNeedsApproval: String
    let oauthKeychainDenied: String
    let oauthKeychainError: (_ status: Int32) -> String
    let oauthTokenExpired: String
    let oauthUnauthorized: (_ status: Int) -> String
    let oauthRateLimited: String
    let oauthServerError: (_ status: Int) -> String
    let oauthNetworkError: String
    let oauthNoData: String

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

    // Codex
    let codexEnable: String
    let codexEnableHint: String
    let codexRefresh: String
    let codexPath: String
    let codexPathPlaceholder: String
    let codexNotInstalled: String
    let codexPathInvalid: String
    let codexInstall: String
    let codexOff: String
    let codexWindowIdle: String
    let codexLimitReached: String
    let codexTimeout: String
    let codexExited: (_ code: Int32, _ stderrTail: String) -> String
    let codexServerError: (_ message: String) -> String
    let codexNetworkError: String
    /// "paid through Nov 4"
    let codexPaidThrough: (_ date: String) -> String
    let opencodeGoEnable: String
    let opencodeGoEnableHint: String
    let opencodeGoAPIKeyHint: String
    let opencodeGoNoKey: String
    let opencodeGoUnauthorized: String
    let opencodeGoServerError: (_ status: Int) -> String
    let opencodeGoMalformed: String
    let opencodeGoNetworkError: String
    let opencodeGoWindowIdle: String

    // Layout
    let layout: String
    let layoutHint: String
    let layoutPanel: String
    let layoutMenuBar: String
    let layoutMoveUp: String
    let layoutMoveDown: String
    /// "Off — turn it on in the Codex tab"
    let layoutProviderOff: (_ tab: String) -> String
    let panelEmpty: String

    // Startup & notifications
    let launchAtLogin: String
    let notifications: String
    let notifyOverPace: String
    let notifyRunningOut: String
    let notifyOverPaceHint: String
    let notifyRunningOutHint: String
    let notifyWindowReset: String
    let notifyQuotaRestored: String
    let notifyQuotaRestoredHint: String
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
    let alertQuotaRestoredTitle: (_ window: String) -> String
    /// The reset time has not moved — that is the point worth saying.
    let alertQuotaRestoredBody: (_ used: String, _ resetTime: String) -> String

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

    // Sync
    let syncTab: String
    let syncEnable: String
    let syncEnableHint: String
    let syncEndpoint: String
    let syncInsecureEndpoint: String
    let syncToken: String
    let syncTokenHint: String
    let syncTokenSaved: String
    let syncTokenRejected: String
    let syncAccounts: String
    let syncAccountsHint: String
    let syncSendNow: String
    let syncLastSent: (_ ago: String) -> String
    let syncNeverSent: String
    let syncQueued: (_ count: Int) -> String
    let syncRejected: (_ detail: String) -> String

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
        case .month: return monthTitle
        }
    }

    /// Notifications name the provider; the menu's section header already does.
    func claudeWindowTitle(_ kind: AIUsageCore.WindowKind) -> String {
        "Claude " + windowTitle(kind)
    }

    func codexWindowTitle(_ kind: AIUsageCore.WindowKind) -> String {
        "Codex " + windowTitle(kind)
    }

    func opencodeGoWindowTitle(_ kind: AIUsageCore.WindowKind) -> String {
        "OpenCode Go " + windowTitle(kind)
    }

    static let en = Strings(
        waitingForData: "Waiting for data",
        sourceStatusline: "statusline",
        sourceProbe: "probe",
        sourceOAuth: "OAuth",

        fiveHourTitle: "5-hour window",
        sevenDayTitle: "7-day window",
        monthTitle: "Monthly window",
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
        repacedSince: { remaining, ago in "\(remaining) left · re-paced \(ago) ago" },
        repaceOverall: { marker in "overall \(marker)" },
        repaceClear: "Clear",

        claudeCodeMissingTitle: "Claude Code not found",
        claudeCodeMissingBody: "AIUsage reads your quota through Claude Code, which is not installed on this Mac (or is not on your PATH — set its location in Settings → Claude Code).",
        installClaudeCode: "Install Claude Code",
        noQuotaInData: "Claude Code is running but reports no subscription quota. Rate limits only exist for Claude Pro and Max accounts; API-key accounts have nothing to show.",
        precisionNote: "Percentages come from Claude's rate-limit headers, which report whole points rounded down. Claude Code's /usage screen may read up to one point higher.",

        claudeEnable: "Track Claude quota",
        claudeEnableHint: "Reads the 5-hour and 7-day windows of your Claude Pro or Max plan: passively from Claude Code's status line (the hook below), on demand with ↻, and, if you turn it on, through the OAuth query. Over-pace, running-out and reset notifications follow the switches in General.",
        probeNow: "Query now",
        probeHint: "Sends one tiny Haiku request (~500 tokens, ≈ $0.001 API-equivalent). Covered by your Pro or Max subscription; uses a negligible slice of quota. If no window is active, this starts a new 5-hour window.",
        probeClaudeNotInstalled: "Claude Code is not installed, or not on your PATH. Install it, or set its location in Settings → Claude Code.",
        probeClaudePathInvalid: "The claude path in Settings does not point to an executable.",
        probeTimeout: "Query timed out (60s)",
        probeNotLoggedIn: "Claude Code is installed but not signed in. Open Terminal, run `claude`, and sign in with your Claude Pro or Max account.",
        probeExited: { code, tail in "claude exited with code \(code)" + (tail.isEmpty ? "" : ": \(tail)") },
        probeNoEvent: "No rate_limit_event in output (API-key accounts have no subscription quota)",

        oauthEnable: "Query usage with Claude Code's sign-in (OAuth)",
        oauthEnableHint: "Off by default. In the background (every 2 minutes while you have the menu open, slowing to every 30 when you haven't looked for hours) and when you click ↻, AIUsage reads Claude Code's sign-in token from the Keychain (with macOS's `security` tool, as Claude Code does, so no prompt shows) and asks Anthropic's usage endpoint, the one behind Claude Code's /usage screen. Free: no tokens, never starts a 5-hour window, and it also sees usage from the desktop app and claude.ai. The endpoint is undocumented, and Anthropic's terms reserve Pro and Max sign-in tokens for Claude Code and claude.ai: use at your own risk. AIUsage keeps the token in memory only, never writes it anywhere, and never renews it itself: when it expires, AIUsage briefly starts Claude Code in the background, which renews it.",
        oauthRefreshHint: "Asks the OAuth usage endpoint. Free; never starts a 5-hour window.",
        oauthReread: "Re-read sign-in",
        oauthRereadHint: "After switching accounts in Claude Code (/login), read the new sign-in now. Otherwise AIUsage keeps using the old one until it expires. macOS may ask for Keychain access.",
        oauthNoCredentials: "No Claude Code sign-in in the Keychain. Run `claude` in Terminal and sign in.",
        oauthKeychainNeedsApproval: "AIUsage needs permission to read Claude Code's sign-in. Click ↻ and choose Always Allow.",
        oauthKeychainDenied: "Reading Claude Code's sign-in was denied. Click ↻ to be asked again.",
        oauthKeychainError: { "Couldn't read the Keychain (error \($0))." },
        oauthTokenExpired: "Claude Code's sign-in token has expired and Claude Code could not renew it. Run `claude` in Terminal, sign in again if asked, then try again.",
        oauthUnauthorized: { "The usage endpoint rejected Claude Code's sign-in (HTTP \($0)). Use Claude Code once so it renews, then try again." },
        oauthRateLimited: "Too many requests to the usage endpoint; AIUsage will try again later.",
        oauthServerError: { "The usage endpoint returned HTTP \($0)." },
        oauthNetworkError: "Couldn't reach api.anthropic.com.",
        oauthNoData: "The usage endpoint returned no 5-hour or 7-day window.",

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

        codexEnable: "Track Codex quota",
        codexEnableHint: "Reads the 5-hour and weekly windows of your ChatGPT plan through the Codex CLI (`codex app-server`) every 5 minutes and whenever you open the menu. A usage lookup, not a model request: free, and it uses no quota. Over-pace, running-out and reset notifications follow the switches in General.",
        codexRefresh: "Refresh now",
        codexPath: "codex path",
        codexPathPlaceholder: "Not found — enter full path",
        codexNotInstalled: "The Codex CLI is not installed, or not on your PATH. Install it, or set its location in Settings → Codex.",
        codexPathInvalid: "The codex path in Settings does not point to an executable.",
        codexInstall: "Install Codex CLI",
        codexOff: "Codex tracking is off. Turn it on in Settings → Codex.",
        codexWindowIdle: "Codex reported no such window for your plan.",
        codexLimitReached: "Limit reached",
        codexTimeout: "Codex did not answer in time (30s)",
        codexExited: { code, tail in "codex exited with code \(code)" + (tail.isEmpty ? "" : ": \(tail)") },
        codexServerError: { message in "Codex: \(message). If you are not signed in, run `codex login` in Terminal." },
        codexNetworkError: "Codex could not reach chatgpt.com (network error). It will try again at the next refresh.",
        codexPaidThrough: { "renews \($0)" },
        opencodeGoEnable: "Track OpenCode Go quota",
        opencodeGoEnableHint: "Reads your OpenCode Go subscription's 5-hour, weekly and monthly limits from OpenCode's usage endpoint (the one CodexBar reads): every 2 minutes after you open the menu, slowing to every 15 minutes while you are away, and whenever you click ↻. Free: no model requests. The endpoint is undocumented and may change.",
        opencodeGoAPIKeyHint: "The API key of your Go subscription from the OpenCode console, the one you give OpenCode's /connect. Stored in ~/Library/Application Support/AIUsage/opencode-go.key (owner-only permissions) and sent only to opencode.ai.",
        opencodeGoNoKey: "Add your OpenCode Go API key in Settings → OpenCode Go.",
        opencodeGoUnauthorized: "OpenCode rejected the API key. Check it in Settings → OpenCode Go, and that the Go subscription is active.",
        opencodeGoServerError: { "OpenCode answered HTTP \($0). It will try again at the next refresh." },
        opencodeGoMalformed: "OpenCode's answer had no quota in it. The endpoint may have changed, or the key has no Go subscription.",
        opencodeGoNetworkError: "Could not reach opencode.ai (network error). It will try again at the next refresh.",
        opencodeGoWindowIdle: "OpenCode Go reported no such window.",

        layout: "Layout",
        layoutHint: "What the menu's switcher and the menu bar show, in this order from left to right.",
        layoutPanel: "Menu",
        layoutMenuBar: "Menu bar",
        layoutMoveUp: "Move up",
        layoutMoveDown: "Move down",
        layoutProviderOff: { tab in "Off — turn it on in the \(tab) tab" },
        panelEmpty: "Nothing to show. Choose what the menu shows in Settings → General → Layout.",

        launchAtLogin: "Launch at login",
        notifications: "Notifications",
        notifyOverPace: "Over pace (early warning)",
        notifyRunningOut: "Running out (last call)",
        notifyOverPaceHint: "Usage crosses the tolerance: ±5 for 5h, ±3 for 7d",
        notifyRunningOutHint: "At the current rate the limit is 30 min (5h) / 12 h (7d) away",
        notifyWindowReset: "When the 5-hour window resets",
        notifyQuotaRestored: "Quota restored",
        notifyQuotaRestoredHint: "A reset credit zeroed usage; the window keeps its original reset time",
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
        alertQuotaRestoredTitle: { "\($0) quota restored" },
        alertQuotaRestoredBody: { used, reset in "Back to \(used) used. The window still resets at \(reset), so the restored quota has only until then." },

        updates: "Updates",
        checkForUpdates: "Check for Updates…",
        autoCheckForUpdates: "Check for updates automatically",
        updatesUnavailable: "Update checks are only available in packaged release builds.",

        settings: "Settings",
        general: "General",
        claudeCode: "Claude Code",
        menuBarShows: "Menu bar window",
        compactMenuBar: "Compact menu bar",
        compactMenuBarHint: "Show only the percentage (\"42%\") instead of \"5h 42% ▲9\". For crowded menu bars.",
        language: "Language",
        languageSystem: "System",
        languageRelaunchHint: "Update dialogs follow the new language after a relaunch.",
        showInClaudeCode: "Show usage line in Claude Code",
        showInClaudeCodeHint: "Prints \"[Opus] ctx 20% · 5h 19% · 7d 17%\" in Claude Code's status line. Only applies when you had no status line of your own. Changes show up within about a minute — Claude Code re-runs the status line on its next response or its 60-second timer. No restart needed.",
        claudePath: "claude path",
        claudePathPlaceholder: "Not found — enter full path",
        quit: "Quit",

        syncTab: "Sync",
        syncEnable: "Upload to a usage server",
        syncEnableHint: "Sends the Claude and Codex windows (and the DeepSeek balance, if you name an account for it) to your usage-mcp server whenever they change, at most once a minute, plus a heartbeat every 15 minutes. Nothing is sent anywhere else.",
        syncEndpoint: "Server",
        syncInsecureEndpoint: "The server address must start with https:// (http:// only for localhost).",
        syncToken: "Device token",
        syncTokenHint: "Create one on the server under Settings → Upload devices. Stored in ~/Library/Application Support/AIUsage/sync.token (owner-only) and sent only to the server above.",
        syncTokenSaved: "Token saved",
        syncTokenRejected: "The server rejected the device token (revoked or mistyped). Paste a new one.",
        syncAccounts: "Server accounts",
        syncAccountsHint: "The account slug on the server each provider's numbers go to. Leave one empty to not upload it.",
        syncSendNow: "Send now",
        syncLastSent: { "Last upload \($0)" },
        syncNeverSent: "Nothing uploaded yet",
        syncQueued: { "\($0) waiting" },
        syncRejected: { "The server refused: \($0)" }
    )

    static let zh = Strings(
        waitingForData: "等待数据",
        sourceStatusline: "statusline",
        sourceProbe: "主动查询",
        sourceOAuth: "OAuth",

        fiveHourTitle: "5 小时窗口",
        sevenDayTitle: "7 天窗口",
        monthTitle: "每月窗口",
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
        repacedSince: { remaining, ago in "剩余 \(remaining) · \(ago) 前重定" },
        repaceOverall: { marker in "整体 \(marker)" },
        repaceClear: "清除",

        claudeCodeMissingTitle: "未找到 Claude Code",
        claudeCodeMissingBody: "AIUsage 通过 Claude Code 读取额度，但这台 Mac 上没有安装它（或它不在 PATH 里——可在 设置 → Claude Code 指定位置）。",
        installClaudeCode: "安装 Claude Code",
        noQuotaInData: "Claude Code 在运行，但没有上报订阅额度。只有 Claude Pro / Max 账户才有速率限制窗口；API key 账户没有可显示的内容。",
        precisionNote: "百分比来自 Claude 的速率限制响应头，只有整数精度且向下取整；Claude Code 的 /usage 可能比这里高 1 个点。",

        claudeEnable: "跟踪 Claude 额度",
        claudeEnableHint: "读取 Claude Pro / Max 套餐的 5 小时和 7 天窗口：通过 Claude Code 状态栏被动获取（见下方钩子），点 ↻ 时主动查询，开启 OAuth 查询后也会走它。超速、即将用尽和重置通知沿用「通用」里的开关。",
        probeNow: "立即查询",
        probeHint: "发送一次极小的 Haiku 请求（约 500 tokens，≈ $0.001 API 等价）。Pro / Max 套餐内不另收费，只消耗极少量额度；若当前没有活跃窗口，会启动一个新的 5 小时窗口。",
        probeClaudeNotInstalled: "未安装 Claude Code，或它不在 PATH 里。请安装，或在 设置 → Claude Code 指定位置。",
        probeClaudePathInvalid: "设置里填写的 claude 路径不是可执行文件。",
        probeTimeout: "查询超时（60s）",
        probeNotLoggedIn: "已安装 Claude Code 但尚未登录。请在终端运行 `claude`，用你的 Claude Pro / Max 账户登录。",
        probeExited: { code, tail in "claude 退出码 \(code)" + (tail.isEmpty ? "" : "：\(tail)") },
        probeNoEvent: "输出里没有 rate_limit_event（API key 用户没有订阅额度）",

        oauthEnable: "用 Claude Code 的登录凭据查询用量（OAuth）",
        oauthEnableHint: "默认关闭。开启后在后台定时（刚打开过菜单时每 2 分钟，几小时没看则放慢到每 30 分钟）以及点 ↻ 时，AIUsage 从钥匙串读取 Claude Code 的登录令牌（和 Claude Code 一样通过 macOS 的 `security` 工具读取，不会弹窗），去请求 Anthropic 的用量接口，也就是 Claude Code /usage 页面用的那个。免费：不消耗 tokens，不会开启 5 小时窗口，桌面端和 claude.ai 上的用量也能看到。该接口没有官方文档，而且 Anthropic 条款规定 Pro / Max 的登录令牌只能用于 Claude Code 和 claude.ai：风险自负。AIUsage 只把令牌留在内存里，不写入任何地方，自己也不续期：令牌过期时，AIUsage 会在后台短暂启动一次 Claude Code，由它来续期。",
        oauthRefreshHint: "请求 OAuth 用量接口。免费，不会开启 5 小时窗口。",
        oauthReread: "重新读取登录凭据",
        oauthRereadHint: "在 Claude Code 里切换账号（/login）后，点这里立即读取新的登录凭据；否则 AIUsage 会继续用旧的，直到它过期。macOS 可能会询问钥匙串权限。",
        oauthNoCredentials: "钥匙串里没有 Claude Code 的登录凭据。请在终端运行 `claude` 并登录。",
        oauthKeychainNeedsApproval: "AIUsage 需要读取 Claude Code 登录凭据的权限。点 ↻，在弹窗里选“始终允许”。",
        oauthKeychainDenied: "读取 Claude Code 登录凭据被拒绝。点 ↻ 可再次询问。",
        oauthKeychainError: { "读取钥匙串失败（错误 \($0)）。" },
        oauthTokenExpired: "Claude Code 的登录令牌已过期，Claude Code 也未能自动续期。请在终端运行 `claude`，按提示重新登录后再试。",
        oauthUnauthorized: { "用量接口拒绝了 Claude Code 的登录凭据（HTTP \($0)）。用一次 Claude Code 让它续期后再试。" },
        oauthRateLimited: "请求用量接口过于频繁，稍后会自动重试。",
        oauthServerError: { "用量接口返回 HTTP \($0)。" },
        oauthNetworkError: "无法连接 api.anthropic.com。",
        oauthNoData: "用量接口没有返回 5 小时或 7 天窗口。",

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

        codexEnable: "跟踪 Codex 额度",
        codexEnableHint: "通过 Codex CLI（`codex app-server`）读取 ChatGPT 套餐的 5 小时和每周窗口，每 5 分钟一次，打开菜单时也会刷新。这是用量查询，不是模型请求：免费，不消耗额度。超速、即将用尽和重置通知沿用「通用」里的开关。",
        codexRefresh: "立即刷新",
        codexPath: "codex 路径",
        codexPathPlaceholder: "未找到，请填写完整路径",
        codexNotInstalled: "未安装 Codex CLI，或它不在 PATH 里。请安装，或在 设置 → Codex 指定位置。",
        codexPathInvalid: "设置里填写的 codex 路径不是可执行文件。",
        codexInstall: "安装 Codex CLI",
        codexOff: "Codex 跟踪未开启。请在 设置 → Codex 打开。",
        codexWindowIdle: "Codex 没有为你的套餐报告这个窗口。",
        codexLimitReached: "已触顶",
        codexTimeout: "Codex 未能及时响应（30s）",
        codexExited: { code, tail in "codex 退出码 \(code)" + (tail.isEmpty ? "" : "：\(tail)") },
        codexServerError: { message in "Codex：\(message)。如果尚未登录，请在终端运行 `codex login`。" },
        codexNetworkError: "Codex 无法连接 chatgpt.com（网络错误），下次刷新时会再试。",
        codexPaidThrough: { "\($0) 续费" },
        opencodeGoEnable: "跟踪 OpenCode Go 额度",
        opencodeGoEnableHint: "从 OpenCode 的用量接口（CodexBar 读的那个）读取 OpenCode Go 订阅的 5 小时、每周和每月额度：打开菜单后每 2 分钟一次，离开时放慢到每 15 分钟一次，点 ↻ 时也会刷新。免费：不发送模型请求。该接口没有官方文档，可能会变。",
        opencodeGoAPIKeyHint: "OpenCode 控制台里 Go 订阅的 API key，也就是在 OpenCode 的 /connect 里填的那个。保存在 ~/Library/Application Support/AIUsage/opencode-go.key（仅本人可读），只会发送给 opencode.ai。",
        opencodeGoNoKey: "请在 设置 → OpenCode Go 填写 OpenCode Go 的 API key。",
        opencodeGoUnauthorized: "OpenCode 拒绝了这个 API key。请在 设置 → OpenCode Go 检查 key，并确认 Go 订阅仍有效。",
        opencodeGoServerError: { "OpenCode 返回 HTTP \($0)，下次刷新时会再试。" },
        opencodeGoMalformed: "OpenCode 的返回里没有额度数据。可能接口变了，或者这个 key 没有 Go 订阅。",
        opencodeGoNetworkError: "无法连接 opencode.ai（网络错误），下次刷新时会再试。",
        opencodeGoWindowIdle: "OpenCode Go 没有报告这个窗口。",

        layout: "显示内容与顺序",
        layoutHint: "主界面（菜单）顶部的切换栏和菜单栏显示哪些服务，都按这个顺序从左到右排列。",
        layoutPanel: "主界面",
        layoutMenuBar: "菜单栏",
        layoutMoveUp: "上移",
        layoutMoveDown: "下移",
        layoutProviderOff: { tab in "未开启，请在「\(tab)」页打开" },
        panelEmpty: "没有要显示的内容。请在 设置 → 通用 → 显示内容与顺序 中选择。",

        launchAtLogin: "登录时启动",
        notifications: "通知",
        notifyOverPace: "超速（预警）",
        notifyRunningOut: "即将用尽（最后提醒）",
        notifyOverPaceHint: "用量越过容差时：5h ±5，7d ±3",
        notifyRunningOutHint: "按当前速度距用尽还有 30 分钟（5h）/ 12 小时（7d）时",
        notifyWindowReset: "5 小时窗口重置时",
        notifyQuotaRestored: "额度已恢复",
        notifyQuotaRestoredHint: "重置券把用量清零；窗口的重置时间不变",
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
        alertQuotaRestoredTitle: { "\($0)额度已恢复" },
        alertQuotaRestoredBody: { used, reset in "已用回落到 \(used)。窗口仍在 \(reset) 重置，恢复的额度只到那时为止。" },

        updates: "更新",
        checkForUpdates: "检查更新…",
        autoCheckForUpdates: "自动检查更新",
        updatesUnavailable: "只有打包的正式版才能检查更新。",

        settings: "设置",
        general: "通用",
        claudeCode: "Claude Code",
        menuBarShows: "菜单栏显示窗口",
        compactMenuBar: "精简菜单栏",
        compactMenuBarHint: "只显示百分比（\"42%\"），不显示 \"5h 42% ▲9\"。菜单栏拥挤时使用。",
        language: "语言",
        languageSystem: "跟随系统",
        languageRelaunchHint: "更新对话框在重新启动后才切换语言。",
        showInClaudeCode: "在 Claude Code 里显示用量行",
        showInClaudeCodeHint: "在 Claude Code 状态栏打印 \"[Opus] ctx 20% · 5h 19% · 7d 17%\"。仅在你原本没有自己的状态栏时生效。切换后约一分钟内生效——Claude Code 在下一条回复或 60 秒定时器到时重跑状态栏。无需重启。",
        claudePath: "claude 路径",
        claudePathPlaceholder: "未找到，请填写完整路径",
        quit: "退出",

        syncTab: "同步",
        syncEnable: "上传到用量服务器",
        syncEnableHint: "Claude 和 Codex 的窗口（以及填写了账户时的 DeepSeek 余额）变化时上传到你的 usage-mcp 服务器，最多每分钟一次，另外每 15 分钟发一次心跳。不会发到其他任何地方。",
        syncEndpoint: "服务器",
        syncInsecureEndpoint: "服务器地址必须以 https:// 开头（仅 localhost 可用 http://）。",
        syncToken: "设备令牌",
        syncTokenHint: "在服务器的 设置 → 上传设备 里生成。保存在 ~/Library/Application Support/AIUsage/sync.token（仅本人可读），只发送给上面的服务器。",
        syncTokenSaved: "令牌已保存",
        syncTokenRejected: "服务器拒绝了设备令牌（已吊销或填错）。请粘贴新的令牌。",
        syncAccounts: "服务器账户",
        syncAccountsHint: "每个来源的数据写入服务器上的哪个账户标识。留空则不上传。",
        syncSendNow: "立即发送",
        syncLastSent: { "上次上传 \($0)" },
        syncNeverSent: "尚未上传",
        syncQueued: { "\($0) 条待发送" },
        syncRejected: { "服务器拒绝：\($0)" }
    )
}

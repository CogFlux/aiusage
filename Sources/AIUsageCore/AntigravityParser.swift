import Foundation

/// How an Antigravity reading was obtained.
public enum AntigravitySource: String, Codable, Equatable, Sendable {
    /// Antigravity 2.0 (or renamed Gemini.app) local language server.
    case app
    /// `agy -p /usage --output-format json` non-interactive CLI report.
    case cli
    /// Antigravity IDE extension local language server.
    case ide
}

/// One quota pool inside Antigravity (e.g. "Gemini", "Claude / GPT", or a versioned pool like "Gemini 4 Argon").
public struct AntigravityQuotaGroup: Codable, Equatable, Sendable, Identifiable {
    /// Stable slug derived from the group or its buckets (e.g. "gemini", "claude-gpt").
    public var id: String
    /// Display title shown in the popover (e.g. "Gemini", "Claude / GPT", "Gemini 4 Argon").
    public var title: String
    /// Paced 5-hour / 7-day windows when the backend reports explicit cadence and reset time.
    public var windows: [UsageWindow]
    /// Fallback used percentage (0...100) when the source reports pool quota without an explicit
    /// 5h/7d cadence (legacy `GetUserStatus` / `GetCommandModelConfigs`, or missing reset time).
    public var fallbackUsedPercent: Double?
    public var fallbackResetsAt: Date?
    public var fallbackDescription: String?

    public init(id: String, title: String, windows: [UsageWindow] = [],
                fallbackUsedPercent: Double? = nil, fallbackResetsAt: Date? = nil,
                fallbackDescription: String? = nil) {
        self.id = id
        self.title = title
        self.windows = windows
        self.fallbackUsedPercent = fallbackUsedPercent
        self.fallbackResetsAt = fallbackResetsAt
        self.fallbackDescription = fallbackDescription
    }

    public func window(_ kind: WindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    public var limitReached: Bool {
        windows.contains { $0.usedPercent >= 100 } || (fallbackUsedPercent ?? 0) >= 100
    }
}

/// Antigravity quota snapshot parsed from the local language server or `agy` CLI.
public struct AntigravityUsage: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var source: AntigravitySource
    public var accountEmail: String?
    public var planName: String?
    public var availablePromptCredits: Double?
    public var availableFlowCredits: Double?
    public var groups: [AntigravityQuotaGroup]

    public init(observedAt: Date, source: AntigravitySource, accountEmail: String? = nil,
                planName: String? = nil, availablePromptCredits: Double? = nil,
                availableFlowCredits: Double? = nil, groups: [AntigravityQuotaGroup]) {
        self.observedAt = observedAt
        self.source = source
        self.accountEmail = accountEmail
        self.planName = planName
        self.availablePromptCredits = availablePromptCredits
        self.availableFlowCredits = availableFlowCredits
        self.groups = groups
    }

    public func group(_ id: String) -> AntigravityQuotaGroup? {
        groups.first { $0.id == id }
    }

    public var limitReached: Bool {
        groups.contains { $0.limitReached }
    }

    /// The most constrained (highest used%) window of `kind` across all groups, for the menu bar
    /// and the overview chart. Ties keep group order (Gemini before Claude / GPT).
    public func representativeWindow(_ kind: WindowKind) -> UsageWindow? {
        var best: UsageWindow?
        for group in groups {
            guard let candidate = group.window(kind) else { continue }
            if let current = best {
                if candidate.usedPercent > current.usedPercent { best = candidate }
            } else {
                best = candidate
            }
        }
        return best
    }

    /// Representative windows for each cadence present across groups.
    public var representativeWindows: [UsageWindow] {
        WindowKind.claudeKinds.compactMap { representativeWindow($0) }
    }

    /// Highest used% across all fallback-only groups (used when no structured 5h/7d window exists).
    public var fallbackUsedPercent: Double? {
        groups.compactMap(\.fallbackUsedPercent).max()
    }

    public func mergingIdentity(email: String?, planName: String?,
                                availablePromptCredits: Double?, availableFlowCredits: Double?) -> AntigravityUsage {
        var copy = self
        if copy.accountEmail == nil { copy.accountEmail = email }
        if copy.planName == nil { copy.planName = planName }
        if copy.availablePromptCredits == nil { copy.availablePromptCredits = availablePromptCredits }
        if copy.availableFlowCredits == nil { copy.availableFlowCredits = availableFlowCredits }
        return copy
    }
}

/// Pure parsers and process-matching helpers for Antigravity, modelled on CodexBar's
/// `AntigravityStatusProbe` and `AntigravityQuotaSummaryParser`.
public enum AntigravityParser {
    public enum ParseError: Error, Equatable {
        case invalidJSON
        case apiError(String)
        case emptyQuota
    }

    public enum ProcessKind: Equatable, Sendable {
        case app
        case ide
    }

    public struct IdentityInfo: Equatable, Sendable {
        public var email: String?
        public var planName: String?
        public var availablePromptCredits: Double?
        public var availableFlowCredits: Double?
    }

    // MARK: - RetrieveUserQuotaSummary (local Connect-RPC)

    /// Parses `POST /exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`.
    /// Accepts `{ "response": { "groups": [...] } }`, `{ "summary": { "groups": [...] } }`,
    /// or top-level `{ "groups": [...] }`.
    public static func parseQuotaSummary(_ data: Data, observedAt: Date,
                                         source: AntigravitySource = .app) throws -> AntigravityUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        if let codeError = invalidCode(root["code"]) {
            throw ParseError.apiError(codeError)
        }
        let payload = (root["response"] as? [String: Any])
            ?? (root["summary"] as? [String: Any])
            ?? root
        return try buildQuotaSummary(payload, observedAt: observedAt, source: source)
    }

    // MARK: - `agy -p /usage --output-format json`

    /// Parses the non-interactive JSON output of `agy -p /usage --output-format json`.
    public static func parseCLIUsageReport(_ data: Data, observedAt: Date) throws -> AntigravityUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        guard (root["status"] as? String)?.uppercased() == "SUCCESS",
              let command = root["command"] as? [String: Any],
              (command["name"] as? String)?.lowercased() == "usage",
              let payload = command["data"] as? [String: Any]
        else {
            throw ParseError.emptyQuota
        }
        return try buildQuotaSummary(payload, observedAt: observedAt, source: .cli)
    }

    private static func buildQuotaSummary(_ payload: [String: Any], observedAt: Date,
                                          source: AntigravitySource) throws -> AntigravityUsage {
        guard let rawGroups = payload["groups"] as? [[String: Any]], !rawGroups.isEmpty else {
            throw ParseError.emptyQuota
        }
        var groups: [AntigravityQuotaGroup] = []
        for rawGroup in rawGroups {
            guard let rawBuckets = rawGroup["buckets"] as? [[String: Any]] else { continue }
            let rawName = (rawGroup["displayName"] as? String)
                ?? (rawGroup["display_name"] as? String)
                ?? (rawGroup["name"] as? String)
                ?? ""
            let title = normalizedGroupTitle(rawName)
            let groupID = normalizedGroupID(forTitle: title)

            var windowsByKind: [WindowKind: UsageWindow] = [:]
            var fallbackUsed: Double?
            var fallbackReset: Date?
            var fallbackDesc: String?

            for bucket in rawBuckets {
                if (bucket["disabled"] as? Bool) == true { continue }
                guard let remaining = extractRemainingFraction(bucket) else { continue }
                let clamped = max(0, min(1, remaining))
                let usedPercent = max(0, min(100, (1 - clamped) * 100))

                let resetRaw = (bucket["resetTime"] as? String) ?? (bucket["reset_time"] as? String)
                let resetDate = resetRaw.flatMap(parseTimestamp)
                let desc = (bucket["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

                let windowField = bucket["window"] as? String
                let bucketID = (bucket["bucketId"] as? String)
                    ?? (bucket["bucket_id"] as? String)
                    ?? (bucket["id"] as? String)
                    ?? ""
                let bucketName = (bucket["displayName"] as? String)
                    ?? (bucket["display_name"] as? String)
                    ?? (bucket["name"] as? String)
                    ?? ""

                if let kind = detectWindowKind(window: windowField, bucketID: bucketID, displayName: bucketName),
                   let resetDate {
                    let candidate = UsageWindow(kind: kind, usedPercent: usedPercent,
                                                resetsAt: resetDate, observedAt: observedAt)
                    if let existing = windowsByKind[kind] {
                        if candidate.usedPercent > existing.usedPercent {
                            windowsByKind[kind] = candidate
                        }
                    } else {
                        windowsByKind[kind] = candidate
                    }
                } else {
                    if fallbackUsed == nil || usedPercent > (fallbackUsed ?? -1) {
                        fallbackUsed = usedPercent
                        fallbackReset = resetDate
                        fallbackDesc = desc?.isEmpty == true ? nil : desc
                    }
                }
            }

            let orderedWindows = WindowKind.claudeKinds.compactMap { windowsByKind[$0] }
            guard !orderedWindows.isEmpty || fallbackUsed != nil else { continue }

            // Merge if two groups normalize to the same id.
            if let idx = groups.firstIndex(where: { $0.id == groupID }) {
                var existing = groups[idx]
                for w in orderedWindows {
                    if let cur = existing.window(w.kind) {
                        if w.usedPercent > cur.usedPercent {
                            existing.windows.removeAll { $0.kind == w.kind }
                            existing.windows.append(w)
                        }
                    } else {
                        existing.windows.append(w)
                    }
                }
                existing.windows.sort { sortRank($0.kind) < sortRank($1.kind) }
                if let fb = fallbackUsed, fb > (existing.fallbackUsedPercent ?? -1) {
                    existing.fallbackUsedPercent = fb
                    existing.fallbackResetsAt = fallbackReset
                    existing.fallbackDescription = fallbackDesc
                }
                groups[idx] = existing
            } else {
                groups.append(AntigravityQuotaGroup(
                    id: groupID,
                    title: title,
                    windows: orderedWindows,
                    fallbackUsedPercent: orderedWindows.isEmpty ? fallbackUsed : nil,
                    fallbackResetsAt: orderedWindows.isEmpty ? fallbackReset : nil,
                    fallbackDescription: orderedWindows.isEmpty ? fallbackDesc : nil
                ))
            }
        }

        guard !groups.isEmpty else { throw ParseError.emptyQuota }
        groups.sort { groupSortRank($0) < groupSortRank($1) }
        return AntigravityUsage(observedAt: observedAt, source: source, groups: groups)
    }

    // MARK: - GetUserStatus / GetCommandModelConfigs (identity + legacy fallback)

    /// Extracts email, plan label, and available AI credits from `GetUserStatus` without requiring model quotas.
    public static func parseIdentity(_ data: Data) -> IdentityInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              invalidCode(root["code"]) == nil,
              let userStatus = root["userStatus"] as? [String: Any]
        else { return nil }

        let email = nonEmpty(userStatus["email"] as? String)
        let userTierName = nonEmpty((userStatus["userTier"] as? [String: Any])?["name"] as? String)
        let planStatus = userStatus["planStatus"] as? [String: Any]
        let planInfo = planStatus?["planInfo"] as? [String: Any]
        let planInfoName = [
            planInfo?["planDisplayName"],
            planInfo?["displayName"],
            planInfo?["productName"],
            planInfo?["planName"],
            planInfo?["planShortName"],
        ].compactMap { nonEmpty($0 as? String) }.first

        let promptCredits = JSONNumber.double(planStatus?["availablePromptCredits"])
        let flowCredits = JSONNumber.double(planStatus?["availableFlowCredits"])

        return IdentityInfo(
            email: email,
            planName: userTierName ?? planInfoName,
            availablePromptCredits: promptCredits,
            availableFlowCredits: flowCredits
        )
    }

    /// Parses `POST /exa.language_server_pb.LanguageServerService/GetUserStatus` (fallback when
    /// `RetrieveUserQuotaSummary` is unavailable, e.g. Antigravity IDE or older builds).
    public static func parseUserStatus(_ data: Data, observedAt: Date,
                                       source: AntigravitySource = .ide) throws -> AntigravityUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        if let codeError = invalidCode(root["code"]) {
            throw ParseError.apiError(codeError)
        }
        guard let userStatus = root["userStatus"] as? [String: Any] else {
            throw ParseError.emptyQuota
        }
        let identity = parseIdentity(data)
        let configs = ((userStatus["cascadeModelConfigData"] as? [String: Any])?["clientModelConfigs"] as? [[String: Any]]) ?? []
        let groups = groupModelConfigs(configs)
        guard !groups.isEmpty else { throw ParseError.emptyQuota }

        return AntigravityUsage(
            observedAt: observedAt,
            source: source,
            accountEmail: identity?.email,
            planName: identity?.planName,
            availablePromptCredits: identity?.availablePromptCredits,
            availableFlowCredits: identity?.availableFlowCredits,
            groups: groups
        )
    }

    /// Parses `POST /exa.language_server_pb.LanguageServerService/GetCommandModelConfigs`.
    public static func parseCommandModelConfigs(_ data: Data, observedAt: Date,
                                                source: AntigravitySource = .ide) throws -> AntigravityUsage {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }
        if let codeError = invalidCode(root["code"]) {
            throw ParseError.apiError(codeError)
        }
        let configs = (root["clientModelConfigs"] as? [[String: Any]]) ?? []
        let groups = groupModelConfigs(configs)
        guard !groups.isEmpty else { throw ParseError.emptyQuota }
        return AntigravityUsage(observedAt: observedAt, source: source, groups: groups)
    }

    private static func groupModelConfigs(_ configs: [[String: Any]]) -> [AntigravityQuotaGroup] {
        var geminiBest: (used: Double, reset: Date?)?
        var claudeBest: (used: Double, reset: Date?)?

        for config in configs {
            guard let quotaInfo = config["quotaInfo"] as? [String: Any],
                  let remaining = JSONNumber.double(quotaInfo["remainingFraction"])
            else { continue }

            let label = (config["label"] as? String ?? "").lowercased()
            let modelID = ((config["modelOrAlias"] as? [String: Any])?["model"] as? String ?? "").lowercased()
            let combined = modelID + " " + label

            // Skip auxiliary models (lite, autocomplete, image), matching CodexBar.
            if combined.contains("lite") || combined.contains("autocomplete") ||
                modelID.hasPrefix("tab_") || combined.contains("image") {
                continue
            }

            let used = max(0, min(100, (1 - max(0, min(1, remaining))) * 100))
            let reset = (quotaInfo["resetTime"] as? String).flatMap(parseTimestamp)

            let isClaudeGPT = combined.contains("claude") || combined.contains("gpt") || combined.contains("openai")
            let isGemini = combined.contains("gemini") && (combined.contains("pro") || combined.contains("flash"))

            if isClaudeGPT {
                if claudeBest == nil || used > (claudeBest?.used ?? -1) {
                    claudeBest = (used, reset)
                }
            } else if isGemini {
                if geminiBest == nil || used > (geminiBest?.used ?? -1) {
                    geminiBest = (used, reset)
                }
            }
        }

        var groups: [AntigravityQuotaGroup] = []
        if let gemini = geminiBest {
            groups.append(AntigravityQuotaGroup(
                id: "gemini",
                title: "Gemini",
                windows: [],
                fallbackUsedPercent: gemini.used,
                fallbackResetsAt: gemini.reset
            ))
        }
        if let claude = claudeBest {
            groups.append(AntigravityQuotaGroup(
                id: "claude-gpt",
                title: "Claude / GPT",
                windows: [],
                fallbackUsedPercent: claude.used,
                fallbackResetsAt: claude.reset
            ))
        }
        return groups
    }

    // MARK: - Process command line classification & flag parsing

    /// Classifies a process command line as Antigravity 2.0/Gemini desktop app or Antigravity IDE
    /// extension language server; nil for unrelated processes.
    public static func classifyLanguageServer(commandLine: String) -> ProcessKind? {
        let lower = commandLine.lowercased()
        let lsPattern = #"(^|[/\\])language(?:_|-)server(?:[_-][a-z0-9]+)*(?:\.exe)?(\s|$)"#
        guard lower.range(of: lsPattern, options: .regularExpression) != nil else { return nil }

        let isAntigravity = (lower.contains("--app_data_dir") && lower.contains("antigravity"))
            || lower.contains("antigravity.app/")
            || lower.contains("/gemini.app/")
            || lower.contains("antigravity ide.app/")
            || lower.contains("/antigravity/")
        guard isAntigravity else { return nil }

        let ideMarkers = [
            "antigravity ide.app/",
            "--app_data_dir antigravity-ide",
            "--app_data_dir=antigravity-ide",
            "/extensions/antigravity/bin/language_server",
        ]
        return ideMarkers.contains(where: { lower.contains($0) }) ? .ide : .app
    }

    /// Extracts `--flag value` or `--flag=value` from a command line or argv list.
    public static func extractFlag(_ flag: String, from arguments: [String]) -> String? {
        let lowerFlag = flag.lowercased()
        for i in arguments.indices {
            let arg = arguments[i]
            let lowerArg = arg.lowercased()
            if lowerArg == lowerFlag {
                let next = i + 1
                if next < arguments.count, !arguments[next].isEmpty {
                    return arguments[next]
                }
            } else if lowerArg.hasPrefix(lowerFlag + "=") {
                let value = String(arg.dropFirst(flag.count + 1))
                if !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Parses the `argv` array from a Darwin `KERN_PROCARGS2` buffer.
    public static func parseProcArgs2(_ data: Data) -> [String]? {
        let intSize = MemoryLayout<Int32>.size
        guard data.count >= intSize else { return nil }
        let argc = data.withUnsafeBytes { Int(Int32(littleEndian: $0.loadUnaligned(as: Int32.self))) }
        guard argc >= 0, argc <= data.count else { return nil }

        let bytes = [UInt8](data)
        var offset = intSize
        guard let execEnd = bytes[offset...].firstIndex(of: 0) else { return nil }
        offset = execEnd + 1
        while offset < bytes.count, bytes[offset] == 0 { offset += 1 }

        var args: [String] = []
        args.reserveCapacity(argc)
        for _ in 0..<argc {
            guard offset < bytes.count,
                  let end = bytes[offset...].firstIndex(of: 0),
                  let arg = String(bytes: bytes[offset..<end], encoding: .utf8)
            else { return nil }
            args.append(arg)
            offset = end + 1
        }
        return args
    }

    // MARK: - Helpers

    private static func extractRemainingFraction(_ bucket: [String: Any]) -> Double? {
        if let direct = JSONNumber.double(bucket["remainingFraction"]) { return direct }
        if let direct = JSONNumber.double(bucket["remaining_fraction"]) { return direct }
        if let remaining = bucket["remaining"] as? [String: Any] {
            if let nested = JSONNumber.double(remaining["remainingFraction"]) { return nested }
            if let nested = JSONNumber.double(remaining["remaining_fraction"]) { return nested }
            if let oneofCase = remaining["case"] as? String,
               oneofCase == "remainingFraction" || oneofCase == "remaining_fraction",
               let val = JSONNumber.double(remaining["value"]) {
                return val
            }
        }
        return nil
    }

    private static let sessionAliases: Set<String> = [
        "session", "5h", "5-hour", "five hour", "five-hour",
    ]
    private static let weeklyAliases: Set<String> = [
        "weekly", "7d", "7-day", "seven day", "seven-day",
    ]

    private static func detectWindowKind(window: String?, bucketID: String, displayName: String) -> WindowKind? {
        let explicit = window?.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = (explicit?.isEmpty == false) ? [explicit!] : [bucketID, displayName]
        var candidates: Set<String> = []
        for raw in sources {
            let norm = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
                .replacingOccurrences(of: "_", with: "-")
            guard !norm.isEmpty else { continue }
            var variants = [norm]
            if norm.hasSuffix(" limit") {
                variants.append(String(norm.dropLast(" limit".count)))
            }
            for v in variants {
                candidates.insert(v)
                for alias in sessionAliases.union(weeklyAliases) where v.hasSuffix("-\(alias)") || v.hasSuffix(" \(alias)") {
                    candidates.insert(alias)
                }
            }
        }
        if !candidates.isDisjoint(with: sessionAliases) { return .fiveHour }
        if !candidates.isDisjoint(with: weeklyAliases) { return .sevenDay }
        return nil
    }

    private static func normalizedGroupTitle(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        // Keep versioned groups (e.g. "Gemini 4 Argon") under their own name.
        if lower.contains("gemini"), !trimmed.contains(where: \.isNumber) {
            return "Gemini"
        }
        if lower.contains("claude") || lower.contains("gpt") {
            return "Claude / GPT"
        }
        return trimmed.isEmpty ? "Quota" : trimmed
    }

    private static func normalizedGroupID(forTitle title: String) -> String {
        switch title {
        case "Gemini": return "gemini"
        case "Claude / GPT": return "claude-gpt"
        default:
            let slug = title.lowercased().map { ch -> Character in
                ch.isLetter || ch.isNumber ? ch : "-"
            }
            let collapsed = String(slug).split(separator: "-").joined(separator: "-")
            return collapsed.isEmpty ? "quota" : collapsed
        }
    }

    private static func groupSortRank(_ group: AntigravityQuotaGroup) -> (Int, String) {
        switch group.id {
        case "gemini": return (0, group.title)
        case "claude-gpt": return (1, group.title)
        default: return (2, group.title.lowercased())
        }
    }

    private static func sortRank(_ kind: WindowKind) -> Int {
        switch kind {
        case .fiveHour: return 0
        case .sevenDay: return 1
        case .month: return 2
        }
    }

    private static func invalidCode(_ raw: Any?) -> String? {
        guard let raw else { return nil }
        if let num = raw as? Int { return num == 0 ? nil : "\(num)" }
        if let str = raw as? String {
            let lower = str.lowercased()
            if lower == "ok" || lower == "success" || str == "0" { return nil }
            return str
        }
        return nil
    }

    public static func parseTimestamp(_ value: String) -> Date? {
        if let date = OAuthUsageParser.parseTimestamp(value) { return date }
        if let seconds = Double(value) { return Date(timeIntervalSince1970: seconds) }
        return nil
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}

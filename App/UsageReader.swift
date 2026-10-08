import Foundation

enum UsageReader {
    static func read() throws -> UsageData {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let database = home.appendingPathComponent(".codex/state_5.sqlite")
        let midnight = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        let today = try scalar("select coalesce(sum(tokens_used),0) from threads where archived=0 and created_at >= \(Int(midnight));", database)
        let all = try scalar("select coalesce(sum(tokens_used),0) from threads;", database)
        let threads = try scalar("select count(*) from threads where archived=0;", database)
        let modelTokens = try query("select coalesce(model,''), coalesce(sum(tokens_used),0) from threads group by 1;", database)
        let todayModelTokens = try query("select coalesce(model,''), coalesce(sum(tokens_used),0) from threads where created_at >= \(Int(midnight)) group by 1;", database)
        let recent = try query("select id, coalesce(tokens_used,0), replace(replace(replace(substr(coalesce(title,''),1,120),char(9),' '),char(10),' '),char(13),' ') from threads where archived=0 order by updated_at desc limit 6;", database)
            .split(separator: "\n")
            .compactMap { line -> RecentThread? in
                let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard fields.count >= 3 else { return nil }
                return RecentThread(
                    id: String(fields[0]),
                    title: String(fields[2]).trimmingCharacters(in: .whitespaces),
                    tokensUsed: Int(fields[1]) ?? 0
                )
            }
        let limits = latestLimits(home: home)
        return UsageData(
            updatedAt: .now,
            todayTokens: Int(today) ?? 0,
            totalTokens: Int(all) ?? 0,
            threadCount: Int(threads) ?? 0,
            estimatedCost: codexCost(modelTokens),
            todayCost: codexCost(todayModelTokens),
            fiveHour: limits.first { $0.windowMinutes == 300 },
            weekly: limits.first { $0.windowMinutes == 10080 },
            recentThreads: recent
        )
    }

    /// Observed split of Codex usage from rollout token_count events (last 24 h
    /// of local sessions on 2026-10-06): ~95 % of tokens are cached input,
    /// which is priced far below fresh input.
    private static let codexUncachedShare = 0.0440
    private static let codexCachedShare = 0.9517
    private static let codexOutputShare = 0.0043

    private static func codexCost(_ modelTokens: String) -> Double {
        var total = 0.0
        for line in modelTokens.split(separator: "\n") {
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count == 2,
                  let tokens = Double(fields[1]),
                  let rates = ModelPricing.rates(for: String(fields[0])) else { continue }
            total += tokens * (codexUncachedShare * rates.input
                + codexCachedShare * rates.cachedInput
                + codexOutputShare * rates.output) / 1_000_000
        }
        return total
    }

    static func readOpenCode() throws -> OpenCodeUsageData {
        let database = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/opencode.db")
        let totals = try query("select count(*), coalesce(sum(tokens_input),0), coalesce(sum(tokens_output),0), coalesce(sum(tokens_reasoning),0), coalesce(sum(tokens_cache_read),0), coalesce(sum(tokens_cache_write),0), coalesce(sum(cost),0) from session;", database)
        let fields = totals.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count == 7 else { throw ReaderError.openCode }
        let sessions = try query("select id, replace(replace(replace(substr(title,1,120),char(9),' '),char(10),' '),char(13),' '), coalesce(model,''), time_updated, tokens_input, tokens_output, tokens_reasoning, tokens_cache_read, tokens_cache_write from session order by time_updated desc limit 6;", database)
            .split(separator: "\n")
            .compactMap { line -> OpenCodeSession? in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count == 9 else { return nil }
                let timestamp = Double(columns[3]) ?? 0
                return OpenCodeSession(
                    id: String(columns[0]),
                    title: String(columns[1]).trimmingCharacters(in: .whitespaces),
                    model: openCodeModel(String(columns[2])),
                    updatedAt: Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp),
                    input: Int(columns[4]) ?? 0,
                    output: Int(columns[5]) ?? 0,
                    reasoning: Int(columns[6]) ?? 0,
                    cacheRead: Int(columns[7]) ?? 0,
                    cacheWrite: Int(columns[8]) ?? 0
                )
            }
        let midnight = Int(Calendar.current.startOfDay(for: .now).timeIntervalSince1970) * 1000
        let today = try scalar("select coalesce(sum(json_extract(data,'$.tokens.input')),0) + coalesce(sum(json_extract(data,'$.tokens.output')),0) + coalesce(sum(json_extract(data,'$.tokens.reasoning')),0) + coalesce(sum(json_extract(data,'$.tokens.cache.read')),0) + coalesce(sum(json_extract(data,'$.tokens.cache.write')),0) from message where time_created >= \(midnight);", database)
        let todayCost = try scalar("select coalesce(sum(json_extract(data,'$.cost')),0) from message where time_created >= \(midnight);", database)
        return OpenCodeUsageData(
            updatedAt: .now,
            todayTokens: Int(today) ?? 0,
            sessionCount: Int(fields[0]) ?? 0,
            input: Int(fields[1]) ?? 0,
            output: Int(fields[2]) ?? 0,
            reasoning: Int(fields[3]) ?? 0,
            cacheRead: Int(fields[4]) ?? 0,
            cacheWrite: Int(fields[5]) ?? 0,
            cost: Double(fields[6]) ?? 0,
            todayCost: Double(todayCost) ?? 0,
            recentSessions: sessions
        )
    }

    private static func openCodeModel(_ value: String) -> String {
        guard value.hasPrefix("{"), let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, !id.isEmpty else { return value }
        return id
    }

    static func readCline() throws -> ClineUsageData {
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cline/data/sessions")
        let fm = FileManager.default
        guard let folders = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            throw ReaderError.cline
        }
        var sessions: [ClineSession] = []
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var cost = 0.0
        var todayCost = 0.0
        var today = 0
        let midnight = Calendar.current.startOfDay(for: .now)
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  !folder.lastPathComponent.contains("__agent_"),
                  let files = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]),
                  let meta = files.first(where: { $0.lastPathComponent == "\(folder.lastPathComponent).json" })
                      ?? files.first(where: { $0.pathExtension == "json" && !$0.lastPathComponent.hasSuffix(".messages.json") && !$0.lastPathComponent.hasSuffix(".compaction.json") }),
                  let data = try? Data(contentsOf: meta),
                  let record = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let metadata = record["metadata"] as? [String: Any] ?? [:]
            // Prefer Cline's aggregate totals (session plus spawned subagents); fall back to session-only usage.
            let usage = (metadata["aggregateUsage"] as? [String: Any]) ?? (metadata["usage"] as? [String: Any]) ?? [:]
            let modified = (try? meta.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
            let started = clineDate(record["started_at"], fallback: modified)
            let sessionInput = usage["inputTokens"] as? Int ?? 0
            let sessionOutput = usage["outputTokens"] as? Int ?? 0
            let sessionCacheRead = usage["cacheReadTokens"] as? Int ?? 0
            let sessionCacheWrite = usage["cacheWriteTokens"] as? Int ?? 0
            let sessionModel = record["model"] as? String ?? ""
            input += sessionInput
            output += sessionOutput
            cacheRead += sessionCacheRead
            cacheWrite += sessionCacheWrite
            let recordedCost = usage["totalCost"] as? Double ?? 0
            let sessionCost: Double
            if recordedCost > 0 {
                sessionCost = recordedCost
            } else if let estimate = ModelPricing.cost(model: sessionModel, input: sessionInput, cachedInput: sessionCacheRead + sessionCacheWrite, output: sessionOutput) {
                // Sessions covered by cline-pass record no cost; estimate the same usage at list prices.
                sessionCost = estimate
            } else {
                sessionCost = 0
            }
            cost += sessionCost
            if started >= midnight {
                today += sessionInput + sessionOutput
                todayCost += sessionCost
            }
            sessions.append(ClineSession(
                id: record["session_id"] as? String ?? folder.lastPathComponent,
                title: clineTitle(metadata["title"]),
                model: sessionModel,
                startedAt: started,
                input: sessionInput,
                output: sessionOutput,
                cacheRead: sessionCacheRead,
                cacheWrite: sessionCacheWrite
            ))
        }
        sessions.sort { $0.startedAt > $1.startedAt }
        return ClineUsageData(
            updatedAt: .now,
            todayTokens: today,
            sessionCount: sessions.count,
            input: input,
            output: output,
            cacheRead: cacheRead,
            cacheWrite: cacheWrite,
            cost: cost,
            todayCost: todayCost,
            recentSessions: Array(sessions.prefix(6))
        )
    }

    private static func clineTitle(_ value: Any?) -> String {
        (value as? String ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func clineDate(_ value: Any?, fallback: Date) -> Date {
        guard let string = value as? String else { return fallback }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string) ?? fallback
    }

    private static func scalar(_ sql: String, _ database: URL) throws -> String {
        try query(sql, database).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func query(_ sql: String, _ database: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-readonly", "-separator", "\t", database.path, sql]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ReaderError.database }
        return String(decoding: data, as: UTF8.self)
    }

    private static func latestLimits(home: URL) -> [UsageLimit] {
        let fm = FileManager.default
        let roots = [".codex/sessions", ".codex/archived_sessions"].map { home.appendingPathComponent($0) }
        var files: [(URL, Date)] = []
        for root in roots {
            guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                if let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate {
                    files.append((url, modified))
                }
            }
        }
        files.sort { $0.1 > $1.1 }
        var latest: (Date, [UsageLimit])?
        for (file, modified) in files {
            if let latest, modified <= latest.0 { break }
            guard let data = try? tail(of: file),
                  let tail = String(data: data.suffix(128 * 1024), encoding: .utf8) else { continue }
            for line in tail.split(separator: "\n").reversed() {
                guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let payload = record["payload"] as? [String: Any],
                      let rate = (payload["rate_limits"] as? [String: Any]) ?? ((payload["info"] as? [String: Any])?["rate_limits"] as? [String: Any]),
                      (rate["limit_id"] as? String == nil || rate["limit_id"] as? String == "codex"),
                      rate["primary"] is [String: Any] else { continue }
                let timestamp = (record["timestamp"] as? String).flatMap(ISO8601DateFormatter().date(from:)) ?? modified
                let found = limits(rate, now: .now)
                if !found.isEmpty, latest.map({ timestamp > $0.0 }) ?? true { latest = (timestamp, found) }
                break
            }
        }
        return latest?.1 ?? []
    }

    private static func tail(of file: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: end > 128 * 1024 ? end - 128 * 1024 : 0)
        return try handle.readToEnd() ?? Data()
    }

    private static func limits(_ rate: [String: Any], now: Date) -> [UsageLimit] {
        ["primary", "secondary"].compactMap { key in
            guard let item = rate[key] as? [String: Any], let used = item["used_percent"] as? Double else { return nil }
            let reset = (item["resets_at"] as? Double).map { Date(timeIntervalSince1970: $0) }
            let minutes = item["window_minutes"] as? Int ?? 0
            return UsageLimit(usedPercent: reset.map { $0 <= now } == true ? 0 : used, resetsAt: reset, windowMinutes: minutes)
        }
    }

    private enum ReaderError: LocalizedError {
        case database, openCode, cline
        var errorDescription: String? {
            switch self {
            case .database: "Couldn’t read the local usage database."
            case .openCode: "Couldn’t read OpenCode’s local usage database."
            case .cline: "Couldn’t read Cline’s local session data."
            }
        }
    }
}

struct OpenCodeUsageData {
    var updatedAt: Date
    var todayTokens: Int
    var sessionCount: Int
    var input: Int
    var output: Int
    var reasoning: Int
    var cacheRead: Int
    var cacheWrite: Int
    var cost: Double
    var todayCost: Double
    var recentSessions: [OpenCodeSession]
    var fiveHour: UsageLimit? = nil
    var weekly: UsageLimit? = nil
    var monthly: UsageLimit? = nil
    var limitsError: String? = nil

    var totalTokens: Int { input + output + reasoning + cacheRead + cacheWrite }
    var hasLimits: Bool { fiveHour != nil || weekly != nil || monthly != nil }
    static let empty = OpenCodeUsageData(updatedAt: .now, todayTokens: 0, sessionCount: 0, input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0, todayCost: 0, recentSessions: [])
}

struct OpenCodeSession: Identifiable {
    var id: String
    var title: String
    var model: String
    var updatedAt: Date
    var input: Int
    var output: Int
    var reasoning: Int
    var cacheRead: Int
    var cacheWrite: Int

    var totalTokens: Int { input + output + reasoning + cacheRead + cacheWrite }
}

struct ClineUsageData {
    var updatedAt: Date
    var todayTokens: Int
    var sessionCount: Int
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int
    var cost: Double
    var todayCost: Double
    var recentSessions: [ClineSession]
    var fiveHour: UsageLimit? = nil
    var weekly: UsageLimit? = nil
    var monthly: UsageLimit? = nil
    var limitsError: String? = nil

    var totalTokens: Int { input + output }
    var hasLimits: Bool { fiveHour != nil || weekly != nil || monthly != nil }
    static let empty = ClineUsageData(updatedAt: .now, todayTokens: 0, sessionCount: 0, input: 0, output: 0, cacheRead: 0, cacheWrite: 0, cost: 0, todayCost: 0, recentSessions: [])
}

struct ClineSession: Identifiable {
    var id: String
    var title: String
    var model: String
    var startedAt: Date
    var input: Int
    var output: Int
    var cacheRead: Int
    var cacheWrite: Int

    var totalTokens: Int { input + output }
}

/// Pay-as-you-go API list prices in USD per 1M tokens, used to estimate the
/// dollar value of local usage. Sources checked 2026-10-07:
/// OpenAI (developers.openai.com/api/docs/pricing, standard tier),
/// DeepSeek (api-docs.deepseek.com, peak-hour rates),
/// Z.ai (docs.z.ai), Moonshot (platform.kimi.ai).
enum ModelPricing {
    struct Rates {
        let input: Double
        let cachedInput: Double
        let output: Double
    }

    private static let table: [String: Rates] = [
        // OpenAI
        "gpt-6-astra": Rates(input: 10.00, cachedInput: 1.00, output: 50.00),
        "gpt-6.1-sol": Rates(input: 2.00, cachedInput: 0.10, output: 10.00),
        "gpt-6-luna": Rates(input: 0.10, cachedInput: 0.01, output: 0.50),
        "gpt-6-sol": Rates(input: 2.00, cachedInput: 0.20, output: 10.00),
        "gpt-5.6-sol": Rates(input: 4.00, cachedInput: 0.40, output: 20.00),
        "gpt-5.6-terra": Rates(input: 2.00, cachedInput: 0.20, output: 12.00),
        "gpt-5.6-luna": Rates(input: 0.20, cachedInput: 0.02, output: 1.20),
        "gpt-5.5": Rates(input: 5.00, cachedInput: 0.50, output: 30.00),
        "gpt-5.4": Rates(input: 2.50, cachedInput: 0.25, output: 15.00),
        "gpt-5.4-mini": Rates(input: 0.75, cachedInput: 0.075, output: 4.50),
        "gpt-5.2": Rates(input: 1.75, cachedInput: 0.175, output: 14.00),
        "gpt-5.3-codex": Rates(input: 1.75, cachedInput: 0.175, output: 14.00),
        // gpt-5.2-codex is not on the public price list; matched to gpt-5.3-codex.
        "gpt-5.2-codex": Rates(input: 1.75, cachedInput: 0.175, output: 14.00),
        // Codex background reviewer; priced as the closest public Codex model.
        "codex-auto-review": Rates(input: 1.75, cachedInput: 0.175, output: 14.00),
        // DeepSeek
        "deepseek-flash": Rates(input: 0.30, cachedInput: 0.006, output: 1.20),
        "deepseek-v4.1-flash": Rates(input: 0.30, cachedInput: 0.006, output: 1.20),
        "deepseek-v4-flash": Rates(input: 0.30, cachedInput: 0.006, output: 1.20),
        "deepseek-v4-pro": Rates(input: 1.32, cachedInput: 0.044, output: 3.96),
        // Z.ai
        "glm-5.3-flash": Rates(input: 0.15, cachedInput: 0.03, output: 0.50),
        "glm-5.3": Rates(input: 1.40, cachedInput: 0.26, output: 4.40),
        "glm-5.2": Rates(input: 1.40, cachedInput: 0.26, output: 4.40),
        "glm-5.1": Rates(input: 1.40, cachedInput: 0.26, output: 4.40),
        // Moonshot (cache-hit price fitted from local usage records)
        "kimi-k3": Rates(input: 3.00, cachedInput: 0.30, output: 15.00),
    ]

    /// Rates for a model id, ignoring any provider prefix ("cline-pass/glm-5.2" → "glm-5.2").
    static func rates(for model: String) -> Rates? {
        let name = (model.lowercased().split(separator: "/").last.map { String($0) } ?? "")
            .trimmingCharacters(in: .whitespaces)
        return table[name]
    }

    /// Estimated USD cost for a token count at list prices, or nil for unpriced models.
    /// `cachedInput` must be a subset of `input`, as in Cline's accounting.
    static func cost(model: String, input: Int, cachedInput: Int, output: Int) -> Double? {
        guard let rates = rates(for: model) else { return nil }
        let uncached = max(0, input - cachedInput)
        return (Double(uncached) * rates.input
            + Double(cachedInput) * rates.cachedInput
            + Double(output) * rates.output) / 1_000_000
    }
}

/// Quota windows for the ClinePass subscription shown on the Cline tab,
/// fetched live from Cline's own service. The request reuses Cline's
/// existing sign-in session read-only; this app never refreshes, copies,
/// or stores the credential.
enum ClineLimitsReader {
    struct Limits {
        var fiveHour: UsageLimit?
        var weekly: UsageLimit?
        var monthly: UsageLimit?
    }

    static func fetch() async throws -> Limits {
        guard let token = sessionToken() else { return Limits() }
        var request = URLRequest(url: URL(string: "https://api.cline.bot/api/v1/users/me/plan/usage-limits")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LimitsError.unreadable("Cline") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw LimitsError.clineRejected
        case 429: throw LimitsError.busy("Cline")
        default: throw LimitsError.server("Cline", http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["success"] as? Bool == true,
              let payload = root["data"] as? [String: Any],
              let limits = payload["limits"] as? [[String: Any]] else { throw LimitsError.unreadable("Cline") }

        var result = Limits()
        for limit in limits {
            guard let type = limit["type"] as? String,
                  let used = (limit["percentUsed"] as? NSNumber)?.doubleValue else { continue }
            let reset = (limit["resetsAt"] as? String).flatMap(parseTimestamp)
            switch type {
            case "five_hour":
                result.fiveHour = UsageLimit(usedPercent: used, resetsAt: reset, windowMinutes: 300)
            case "weekly":
                result.weekly = UsageLimit(usedPercent: used, resetsAt: reset, windowMinutes: 10_080)
            case "monthly":
                result.monthly = UsageLimit(usedPercent: used, resetsAt: reset, windowMinutes: 43_200)
            default:
                continue
            }
        }
        return result
    }

    /// The bearer token from Cline's settings file, preferring the `cline`
    /// entry (shared by ClinePass) and then `cline-pass`. Within an entry the
    /// order matches Cline's own resolver: `auth.accessToken`, `apiKey`,
    /// `auth.apiKey`.
    private static func sessionToken() -> String? {
        let environment = ProcessInfo.processInfo.environment
        var candidates: [URL] = []
        if let path = environment["CLINE_PROVIDER_SETTINGS_PATH"], !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }
        if let dir = environment["CLINE_DATA_DIR"], !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("settings/providers.json"))
        }
        if let dir = environment["CLINE_DIR"], !dir.isEmpty {
            candidates.append(URL(fileURLWithPath: dir).appendingPathComponent("data/settings/providers.json"))
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cline/data/settings/providers.json"))

        for url in candidates {
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let providers = root["providers"] as? [String: Any] else { continue }
            for id in ["cline", "cline-pass"] {
                guard let settings = (providers[id] as? [String: Any])?["settings"] as? [String: Any] else { continue }
                let auth = settings["auth"] as? [String: Any]
                let tokens: [String?] = [
                    auth?["accessToken"] as? String,
                    settings["apiKey"] as? String,
                    auth?["apiKey"] as? String,
                ]
                for case let token? in tokens where !token.isEmpty { return token }
            }
        }
        return nil
    }
}

/// Quota windows for the OpenCode Go subscription shown on the OpenCode
/// tab, fetched live from opencode.ai with the API key the OpenCode CLI
/// already stores locally.
enum OpenCodeLimitsReader {
    struct Limits {
        var fiveHour: UsageLimit?
        var weekly: UsageLimit?
        var monthly: UsageLimit?
    }

    static func fetch() async throws -> Limits {
        guard let key = apiKey() else { return Limits() }
        var request = URLRequest(url: URL(string: "https://opencode.ai/zen/go/v1/usage")!)
        request.timeoutInterval = 15
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LimitsError.unreadable("OpenCode Go") }
        switch http.statusCode {
        case 200: break
        case 401, 403: throw LimitsError.openCodeRejected
        case 429: throw LimitsError.busy("OpenCode Go")
        default: throw LimitsError.server("OpenCode Go", http.statusCode)
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = root["usage"] as? [String: Any] else { throw LimitsError.unreadable("OpenCode Go") }

        func window(_ name: String, minutes: Int) -> UsageLimit? {
            guard let item = usage[name] as? [String: Any],
                  let used = (item["percent"] as? NSNumber)?.doubleValue else { return nil }
            let reset = (item["resetsAt"] as? String).flatMap(parseTimestamp)
            return UsageLimit(usedPercent: used, resetsAt: reset, windowMinutes: minutes)
        }

        return Limits(
            fiveHour: window("rolling", minutes: 300),
            weekly: window("weekly", minutes: 10_080),
            monthly: window("monthly", minutes: 43_200)
        )
    }

    /// The `opencode-go` API key from OpenCode's local auth file.
    private static func apiKey() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/opencode/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["opencode-go"] as? [String: Any],
              let key = entry["key"] as? String, !key.isEmpty else { return nil }
        return key
    }
}

/// Errors surfaced on the Cline and OpenCode tabs when a live quota check
/// fails. Missing credentials are not errors: the section simply stays
/// hidden until the tool has a sign-in.
enum LimitsError: LocalizedError {
    case clineRejected, openCodeRejected
    case unreachable(String), busy(String), server(String, Int), unreadable(String)

    var errorDescription: String? {
        switch self {
        case .clineRejected: "Cline sign-in was rejected — run `cline auth` in Terminal."
        case .openCodeRejected: "OpenCode Go key was rejected — run `opencode auth login`."
        case .unreachable(let name): "Couldn’t reach \(name) to check limits."
        case .busy(let name): "\(name) is rate limiting the usage check."
        case .server(let name, let status): "\(name) limit check failed (HTTP \(status))."
        case .unreadable(let name): "Couldn’t read \(name)’s limit response."
        }
    }
}

/// Parses the ISO-8601 timestamps the limit APIs return, including the
/// nanosecond-precision fractions Cline sends.
private func parseTimestamp(_ value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = formatter.date(from: value) { return date }
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)
}

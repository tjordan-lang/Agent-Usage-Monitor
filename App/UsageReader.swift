import Foundation

enum UsageReader {
    static func read() throws -> UsageData {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let database = home.appendingPathComponent(".codex/state_5.sqlite")
        let midnight = Calendar.current.startOfDay(for: .now).timeIntervalSince1970
        let today = try scalar("select coalesce(sum(tokens_used),0) from threads where archived=0 and created_at >= \(Int(midnight));", database)
        let all = try scalar("select coalesce(sum(tokens_used),0) from threads;", database)
        let threads = try scalar("select count(*) from threads where archived=0;", database)
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
            fiveHour: limits.first { $0.windowMinutes == 300 },
            weekly: limits.first { $0.windowMinutes == 10080 },
            recentThreads: recent
        )
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
                    model: String(columns[2]),
                    updatedAt: Date(timeIntervalSince1970: timestamp > 10_000_000_000 ? timestamp / 1000 : timestamp),
                    input: Int(columns[4]) ?? 0,
                    output: Int(columns[5]) ?? 0,
                    reasoning: Int(columns[6]) ?? 0,
                    cacheRead: Int(columns[7]) ?? 0,
                    cacheWrite: Int(columns[8]) ?? 0
                )
            }
        return OpenCodeUsageData(
            updatedAt: .now,
            sessionCount: Int(fields[0]) ?? 0,
            input: Int(fields[1]) ?? 0,
            output: Int(fields[2]) ?? 0,
            reasoning: Int(fields[3]) ?? 0,
            cacheRead: Int(fields[4]) ?? 0,
            cacheWrite: Int(fields[5]) ?? 0,
            cost: Double(fields[6]) ?? 0,
            recentSessions: sessions
        )
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
        case database, openCode
        var errorDescription: String? {
            switch self {
            case .database: "Couldn’t read the local usage database."
            case .openCode: "Couldn’t read OpenCode’s local usage database."
            }
        }
    }
}

struct OpenCodeUsageData {
    var updatedAt: Date
    var sessionCount: Int
    var input: Int
    var output: Int
    var reasoning: Int
    var cacheRead: Int
    var cacheWrite: Int
    var cost: Double
    var recentSessions: [OpenCodeSession]

    var totalTokens: Int { input + output + reasoning + cacheRead + cacheWrite }
    static let empty = OpenCodeUsageData(updatedAt: .now, sessionCount: 0, input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0, cost: 0, recentSessions: [])
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

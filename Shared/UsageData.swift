import Foundation

let usageGroup = "group.tyronejordan.codexusage"
let usageFile = "usage.json"

struct UsageData: Codable {
    var updatedAt: Date
    var todayTokens: Int
    var totalTokens: Int
    var threadCount: Int
    var fiveHour: UsageLimit? = nil
    var weekly: UsageLimit? = nil
    var recentThreads: [RecentThread] = []

    static let empty = UsageData(updatedAt: .now, todayTokens: 0, totalTokens: 0, threadCount: 0)

    var controlLabel: String {
        let five = fiveHour.map { "5h \(Int($0.percentLeft.rounded()))% left" } ?? "5h —"
        let week = weekly.map { "Week \(Int($0.percentLeft.rounded()))% left" } ?? "Week —"
        return "\(five) · \(week)"
    }
}

struct RecentThread: Codable, Identifiable {
    var id: String
    var title: String
    var tokensUsed: Int
}

struct UsageLimit: Codable {
    var usedPercent: Double
    var resetsAt: Date?
    var windowMinutes: Int

    var percentLeft: Double { max(0, min(100, 100 - usedPercent)) }
}

func sharedUsageURL() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: usageGroup)?
        .appendingPathComponent(usageFile)
}

func readSharedUsage() -> UsageData {
    guard let url = sharedUsageURL(), let data = try? Data(contentsOf: url),
          let usage = try? JSONDecoder().decode(UsageData.self, from: data) else { return .empty }
    return usage
}

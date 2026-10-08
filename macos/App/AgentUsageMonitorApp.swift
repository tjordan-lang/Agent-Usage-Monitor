import Combine
import SwiftUI
import WidgetKit

@main
struct AgentUsageMonitorApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        WindowGroup("Agent Usage Monitor") {
            UsageView(store: store)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 460, height: 580)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var usage = readSharedUsage()
    @Published var error: String?
    @Published var openCode = OpenCodeUsageData.empty
    @Published var openCodeError: String?
    @Published var cline = ClineUsageData.empty
    @Published var clineError: String?

    /// Quota checks hit remote services, so they run on a slower cadence
    /// than the local database reads.
    private var lastLimitsRefresh = Date.distantPast

    init() {
        Task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func refresh() async {
        do {
            usage = try await Task.detached(priority: .utility) { try UsageReader.read() }.value
            error = nil
            if let url = sharedUsageURL() {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(usage).write(to: url, options: .atomic)
            }
            ControlCenter.shared.reloadControls(ofKind: "local.tyronejordan.AgentUsageMonitor.usage")
        } catch {
            self.error = error.localizedDescription
        }
        do {
            var fresh = try await Task.detached(priority: .utility) { try UsageReader.readOpenCode() }.value
            // The local read replaces the whole struct; carry the slower
            // quota checks forward so the limit bars survive between them.
            fresh.fiveHour = openCode.fiveHour
            fresh.weekly = openCode.weekly
            fresh.monthly = openCode.monthly
            fresh.limitsError = openCode.limitsError
            openCode = fresh
            openCodeError = nil
        } catch {
            openCodeError = error.localizedDescription
        }
        do {
            var fresh = try await Task.detached(priority: .utility) { try UsageReader.readCline() }.value
            fresh.fiveHour = cline.fiveHour
            fresh.weekly = cline.weekly
            fresh.monthly = cline.monthly
            fresh.limitsError = cline.limitsError
            cline = fresh
            clineError = nil
        } catch {
            clineError = error.localizedDescription
        }
        if Date().timeIntervalSince(lastLimitsRefresh) >= 240 {
            lastLimitsRefresh = .now
            do {
                let limits = try await Task.detached(priority: .utility) { try await ClineLimitsReader.fetch() }.value
                cline.fiveHour = limits.fiveHour
                cline.weekly = limits.weekly
                cline.monthly = limits.monthly
                cline.limitsError = nil
            } catch {
                cline.limitsError = error.localizedDescription
            }
            do {
                let limits = try await Task.detached(priority: .utility) { try await OpenCodeLimitsReader.fetch() }.value
                openCode.fiveHour = limits.fiveHour
                openCode.weekly = limits.weekly
                openCode.monthly = limits.monthly
                openCode.limitsError = nil
            } catch {
                openCode.limitsError = error.localizedDescription
            }
        }
    }
}

private struct UsageView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        TabView {
            CodexTab(store: store)
                .tabItem { Label("Codex", systemImage: "sparkle") }
            OpenCodeTab(store: store)
                .tabItem { Label("OpenCode", systemImage: "chevron.left.forwardslash.chevron.right") }
            ClineTab(store: store)
                .tabItem { Label("Cline", systemImage: "brain") }
        }
        .frame(minWidth: 440, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .help("Refresh usage")
            }
        }
        .task { await store.refresh() }
    }
}

private struct CodexTab: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            Section("Limits") {
                LimitRow(title: "5-hour limit", icon: "clock", limit: store.usage.fiveHour)
                LimitRow(title: "Weekly limit", icon: "calendar", limit: store.usage.weekly)
            }

            Section {
                LabeledContent("Tokens used today") {
                    Text(store.usage.todayTokens.formatted()).monospacedDigit()
                }
                LabeledContent("Tokens used all time") {
                    Text(store.usage.totalTokens.formatted()).monospacedDigit()
                }
                LabeledContent("Active threads") {
                    Text(store.usage.threadCount.formatted()).monospacedDigit()
                }
                if let cost = store.usage.estimatedCost {
                    LabeledContent("Estimated cost today") {
                        Text((store.usage.todayCost ?? 0).formatted(.currency(code: "USD")))
                    }
                    .help("Estimated at current API list prices for the models used")
                    LabeledContent("Estimated cost all time") {
                        Text(cost.formatted(.currency(code: "USD")))
                    }
                    .help("Estimated at current API list prices for the models used")
                }
            } header: {
                Text("Usage")
            } footer: {
                Text("Updated ") + Text(store.usage.updatedAt, style: .time)
            }

            if !store.usage.recentThreads.isEmpty {
                Section("Recent Threads") {
                    ForEach(store.usage.recentThreads) { thread in
                        LabeledContent {
                            Text(thread.tokensUsed.formatted()).monospacedDigit()
                        } label: {
                            Text(thread.title.isEmpty ? "Untitled thread" : thread.title)
                                .lineLimit(2)
                        }
                    }
                }
            }

            if let error = store.error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct OpenCodeTab: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            if store.openCode.hasLimits || store.openCode.limitsError != nil {
                Section("Limits") {
                    if let limit = store.openCode.fiveHour {
                        LimitRow(title: "5-hour limit", icon: "clock", limit: limit)
                    }
                    if let limit = store.openCode.weekly {
                        LimitRow(title: "Weekly limit", icon: "calendar", limit: limit)
                    }
                    if let limit = store.openCode.monthly {
                        LimitRow(title: "Monthly limit", icon: "calendar.badge.clock", limit: limit)
                    }
                    if !store.openCode.hasLimits, let error = store.openCode.limitsError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                LabeledContent("Tokens used today") {
                    Text(store.openCode.todayTokens.formatted()).monospacedDigit()
                }
                LabeledContent("Total tokens") {
                    Text(store.openCode.totalTokens.formatted()).monospacedDigit()
                }
                LabeledContent("Input tokens") {
                    Text((store.openCode.input + store.openCode.cacheRead + store.openCode.cacheWrite).formatted()).monospacedDigit()
                }
                LabeledContent("Output tokens") {
                    Text((store.openCode.output + store.openCode.reasoning).formatted()).monospacedDigit()
                }
                LabeledContent("Sessions") {
                    Text(store.openCode.sessionCount.formatted()).monospacedDigit()
                }
                LabeledContent("Estimated cost today") {
                    Text(store.openCode.todayCost.formatted(.currency(code: "USD")))
                }
                .help("Cost recorded by OpenCode from per-model API pricing")
                LabeledContent("Estimated cost all time") {
                    Text(store.openCode.cost.formatted(.currency(code: "USD")))
                }
                .help("Cost recorded by OpenCode from per-model API pricing")
            } header: {
                Text("Usage")
            } footer: {
                Text("Local OpenCode database · Updated ") + Text(store.openCode.updatedAt, style: .time)
            }

            if !store.openCode.recentSessions.isEmpty {
                Section("Recent Sessions") {
                    ForEach(store.openCode.recentSessions) { session in
                        LabeledContent {
                            Text(session.totalTokens.formatted()).monospacedDigit()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title.isEmpty ? "Untitled session" : session.title)
                                    .lineLimit(2)
                                Text(session.model.isEmpty ? session.updatedAt.formatted(date: .abbreviated, time: .shortened) : "\(session.model) · \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            if let error = store.openCodeError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ClineTab: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        Form {
            if store.cline.hasLimits || store.cline.limitsError != nil {
                Section("Limits") {
                    if let limit = store.cline.fiveHour {
                        LimitRow(title: "5-hour limit", icon: "clock", limit: limit)
                    }
                    if let limit = store.cline.weekly {
                        LimitRow(title: "Weekly limit", icon: "calendar", limit: limit)
                    }
                    if let limit = store.cline.monthly {
                        LimitRow(title: "Monthly limit", icon: "calendar.badge.clock", limit: limit)
                    }
                    if !store.cline.hasLimits, let error = store.cline.limitsError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                LabeledContent("Tokens used today") {
                    Text(store.cline.todayTokens.formatted()).monospacedDigit()
                }
                LabeledContent("Total tokens") {
                    Text(store.cline.totalTokens.formatted()).monospacedDigit()
                }
                LabeledContent("Input tokens") {
                    Text(store.cline.input.formatted()).monospacedDigit()
                }
                LabeledContent("Output tokens") {
                    Text(store.cline.output.formatted()).monospacedDigit()
                }
                LabeledContent("Estimated cost today") {
                    Text(store.cline.todayCost.formatted(.currency(code: "USD")))
                }
                .help("Recorded by Cline where available; other sessions estimated at API list prices")
                LabeledContent("Estimated cost all time") {
                    Text(store.cline.cost.formatted(.currency(code: "USD")))
                }
                .help("Recorded by Cline where available; other sessions estimated at API list prices")
                LabeledContent("Sessions") {
                    Text(store.cline.sessionCount.formatted()).monospacedDigit()
                }
            } header: {
                Text("Usage")
            } footer: {
                Text("Local Cline sessions · Updated ") + Text(store.cline.updatedAt, style: .time)
            }

            if !store.cline.recentSessions.isEmpty {
                Section("Recent Sessions") {
                    ForEach(store.cline.recentSessions) { session in
                        LabeledContent {
                            Text(session.totalTokens.formatted()).monospacedDigit()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.title.isEmpty ? "Untitled session" : session.title)
                                    .lineLimit(2)
                                Text(session.model.isEmpty ? session.startedAt.formatted(date: .abbreviated, time: .shortened) : "\(session.model) · \(session.startedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            }

            if let error = store.clineError {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct LimitRow: View {
    let title: String
    let icon: String
    let limit: UsageLimit?

    private var tint: Color {
        let left = limit?.percentLeft ?? 100
        if left <= 10 { return .red }
        if left <= 30 { return .orange }
        return .green
    }

    /// Clock time for the parenthesized part of the reset line. The clock
    /// time alone is enough while the reset is today; the weekday and then
    /// the date are added as it gets further out, so the weekly and monthly
    /// bars stay unambiguous.
    private func resetClock(_ date: Date) -> String {
        if Calendar.current.isDateInToday(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if date.timeIntervalSinceNow < 7 * 24 * 60 * 60 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Text(limit.map { "\(Int($0.percentLeft.rounded()))% left" } ?? "—")
                    .monospacedDigit()
                    .foregroundStyle(tint)
            } label: {
                Label(title, systemImage: icon)
            }
            ProgressView(value: limit?.percentLeft ?? 0, total: 100)
                .tint(tint)
            if let reset = limit?.resetsAt {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Resets")
                    Text(reset, style: .relative)
                    Text("(\(resetClock(reset)))")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text(limit == nil ? "Usage unavailable" : "Reset time unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

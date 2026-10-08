import AppKit
import Combine
import SwiftUI
import WidgetKit

@main
struct CodexUsageApp: App {
    @StateObject private var store = UsageStore()

    var body: some Scene {
        WindowGroup("Codex Usage") {
            UsageView(store: store)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class UsageStore: ObservableObject {
    @Published var usage = readSharedUsage()
    @Published var error: String?
    @Published var openCode = OpenCodeUsageData.empty
    @Published var openCodeError: String?

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
            ControlCenter.shared.reloadControls(ofKind: "local.tyronejordan.CodexUsageControl.usage")
        } catch {
            self.error = error.localizedDescription
        }
        do {
            openCode = try await Task.detached(priority: .utility) { try UsageReader.readOpenCode() }.value
            openCodeError = nil
        } catch {
            openCodeError = error.localizedDescription
        }
    }
}

private struct UsageView: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(LinearGradient(colors: [.cyan, .blue], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Usage").font(.title3.weight(.semibold))
                    Text("Updated at \(store.usage.updatedAt, style: .time)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { Task { await store.refresh() } } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh usage")
            }
            TabView {
                CodexTab(store: store)
                    .tabItem { Label("Codex", systemImage: "sparkle") }
                OpenCodeTab(store: store)
                    .tabItem { Label("OpenCode", systemImage: "chevron.left.forwardslash.chevron.right") }
            }
            .frame(height: 490)
        }
        .padding(18)
        .frame(width: 380)
        .background {
            ZStack(alignment: .topLeading) {
                Color(nsColor: .windowBackgroundColor)
                LinearGradient(colors: [.cyan.opacity(0.08), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            .ignoresSafeArea()
        }
        .task { await store.refresh() }
    }
}

private struct CodexTab: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
            VStack(spacing: 10) {
                LimitCard(title: "5-hour limit", icon: "clock", limit: store.usage.fiveHour)
                LimitCard(title: "Weekly limit", icon: "calendar", limit: store.usage.weekly)
            }

            VStack(spacing: 0) {
                MetricRow(title: "TOKENS USED TODAY", value: store.usage.todayTokens.formatted(), unit: "tokens")
                Divider().padding(.vertical, 10)
                MetricRow(title: "TOKENS USED ALL TIME", value: store.usage.totalTokens.formatted(), unit: "tokens")
                Divider().padding(.vertical, 10)
                MetricRow(title: "ACTIVE THREADS", value: store.usage.threadCount.formatted(), unit: "threads")
            }
            .padding(14)
            .usageCard()

            if !store.usage.recentThreads.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("RECENT THREADS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(Array(store.usage.recentThreads.enumerated()), id: \.element.id) { index, thread in
                            if index > 0 { Divider().padding(.vertical, 9) }
                            HStack(alignment: .center, spacing: 12) {
                                Text(thread.title.isEmpty ? "Untitled thread" : thread.title)
                                    .font(.callout)
                                    .lineLimit(2)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text("TOKENS")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(thread.tokensUsed.formatted())
                                        .font(.callout.weight(.medium).monospacedDigit())
                                }
                            }
                        }
                    }
                }
                .padding(14)
                .usageCard()
            }

                if let error = store.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct OpenCodeTab: View {
    @ObservedObject var store: UsageStore

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(.purple)
                    Text("Local OpenCode usage")
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(store.openCode.updatedAt, style: .time)
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(13)
                .usageCard()

                VStack(spacing: 0) {
                    MetricRow(title: "TOTAL TOKENS", value: store.openCode.totalTokens.formatted(), unit: "tokens")
                    Divider().padding(.vertical, 9)
                    MetricRow(title: "INPUT TOKENS", value: (store.openCode.input + store.openCode.cacheRead + store.openCode.cacheWrite).formatted(), unit: "tokens")
                    Divider().padding(.vertical, 9)
                    MetricRow(title: "OUTPUT TOKENS", value: (store.openCode.output + store.openCode.reasoning).formatted(), unit: "tokens")
                    Divider().padding(.vertical, 9)
                    MetricRow(title: "SESSIONS", value: store.openCode.sessionCount.formatted(), unit: "sessions")
                }
                .padding(14)
                .usageCard()

                if !store.openCode.recentSessions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("RECENT SESSIONS")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        VStack(spacing: 0) {
                            ForEach(Array(store.openCode.recentSessions.enumerated()), id: \.element.id) { index, session in
                                if index > 0 { Divider().padding(.vertical, 9) }
                                HStack(alignment: .center, spacing: 10) {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.title.isEmpty ? "Untitled session" : session.title)
                                            .font(.callout).lineLimit(2)
                                        Text(session.model.isEmpty ? session.updatedAt.formatted(date: .abbreviated, time: .shortened) : "\(session.model) · \(session.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    VStack(alignment: .trailing, spacing: 2) {
                                        Text("TOKENS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                                        Text(session.totalTokens.formatted()).font(.callout.weight(.medium).monospacedDigit())
                                    }
                                }
                            }
                        }
                    }
                    .padding(14)
                    .usageCard()
                }

                if let error = store.openCodeError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, 8)
        }
    }
}

private struct LimitCard: View {
    let title: String
    let icon: String
    let limit: UsageLimit?

    private var tint: Color {
        let left = limit?.percentLeft ?? 100
        if left <= 10 { return .red }
        if left <= 30 { return .orange }
        return .mint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(tint)
                Text(title).font(.subheadline.weight(.medium))
                Spacer()
                Text(limit.map { "\(Int($0.percentLeft.rounded()))% left" } ?? "—")
                    .font(.title3.weight(.bold).monospacedDigit())
            }
            ProgressView(value: limit?.percentLeft ?? 0, total: 100)
                .tint(tint)
                .controlSize(.small)
            if let reset = limit?.resetsAt {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Resets")
                    Text(reset, style: .relative)
                }
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(limit == nil ? "Usage unavailable" : "Reset time unavailable")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .usageCard()
    }
}

private extension View {
    func usageCard() -> some View {
        background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.white.opacity(0.07)))
    }
}

private struct MetricRow: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value).font(.title3.weight(.semibold).monospacedDigit())
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

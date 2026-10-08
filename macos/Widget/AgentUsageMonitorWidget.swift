import AppIntents
import SwiftUI
import WidgetKit

@main
struct AgentUsageMonitorWidgetBundle: WidgetBundle {
    var body: some Widget { AgentUsageMonitorControl() }
}

struct AgentUsageMonitorControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.tyronejordan.AgentUsageMonitor.usage", provider: Provider()) { value in
            ControlWidgetButton(action: OpenURLIntent(URL(string: "agentusage://open")!)) {
                Label(value, systemImage: "chart.bar.xaxis")
            }
        }
        .displayName("Agent Usage Monitor")
        .description("Show your current usage and open the usage monitor.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: String { "5h — · Week —" }
        func currentValue() async throws -> String { readSharedUsage().controlLabel }
    }
}

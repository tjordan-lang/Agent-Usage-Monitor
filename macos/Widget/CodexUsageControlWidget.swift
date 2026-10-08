import AppIntents
import SwiftUI
import WidgetKit

@main
struct CodexUsageWidgetBundle: WidgetBundle {
    var body: some Widget { CodexUsageControl() }
}

struct CodexUsageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "local.tyronejordan.CodexUsageControl.usage", provider: Provider()) { value in
            ControlWidgetButton(action: OpenURLIntent(URL(string: "codexusage://open")!)) {
                Label(value, systemImage: "chart.bar.xaxis")
            }
        }
        .displayName("Codex Usage")
        .description("Show your current Codex usage and open the usage monitor.")
    }

    struct Provider: ControlValueProvider {
        var previewValue: String { "5h — · Week —" }
        func currentValue() async throws -> String { readSharedUsage().controlLabel }
    }
}

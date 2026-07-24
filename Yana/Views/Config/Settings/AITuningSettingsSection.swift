import SwiftUI

/// AI request tuning knobs: temperature, token/length/limit/timeout/retry knobs.
struct AITuningSettingsSection: View {
    @State private var settings = AppSettings()

    var body: some View {
        Section("AI Tuning") {
            HStack {
                Text("Temperature")
                Slider(value: $settings.aiTemperature, in: 0...1, step: 0.05)
                Text(settings.aiTemperature, format: .number.precision(.fractionLength(2)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Stepper("Max Tokens: \(settings.aiMaxTokens)", value: $settings.aiMaxTokens, in: 256...8000, step: 256)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
            DisclosureGroup("Advanced") {
                Stepper("Max Prompt Length: \(settings.aiMaxPromptLength)", value: $settings.aiMaxPromptLength, in: 100...4000, step: 100)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Daily Limit: \(settings.aiDefaultDailyLimit)", value: $settings.aiDefaultDailyLimit, in: 0...5000, step: 50)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Monthly Limit: \(settings.aiDefaultMonthlyLimit)", value: $settings.aiDefaultMonthlyLimit, in: 0...50000, step: 100)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Request Timeout: \(settings.aiRequestTimeout)s", value: $settings.aiRequestTimeout, in: 10...600, step: 10)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Max Retries: \(settings.aiMaxRetries)", value: $settings.aiMaxRetries, in: 0...10)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Retry Delay: \(settings.aiRetryDelay)s", value: $settings.aiRetryDelay, in: 0...60)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
                Stepper("Request Delay: \(settings.aiRequestDelay)s", value: $settings.aiRequestDelay, in: 0...60)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

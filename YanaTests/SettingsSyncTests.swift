import Foundation
import Testing
@testable import Yana

@MainActor
@Suite("SettingsSync")
struct SettingsSyncTests {

    private func freshDefaults(label: String = "") -> UserDefaults {
        let suite = "SettingsSyncTests.\(label).\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: Round-trip

    @Test func roundTripSyncedSettings() throws {
        let src = AppSettings(defaults: freshDefaults(label: "src"))
        // Set a variety of synced values.
        src.activeAIProvider = .anthropic
        src.retentionDays = 14
        src.backgroundInterval = 1800.0
        src.redditEnabled = true
        src.redditUserAgent = "TestAgent/2"
        src.youtubeEnabled = true
        src.notificationsEnabled = true
        src.openaiAPIURL = "https://custom.api/v1"
        src.openaiModel = "gpt-4o"
        src.anthropicModel = "claude-sonnet-4-6"
        src.geminiModel = "gemini-2.5-pro"
        src.mistralModel = "mistral-large-latest"
        src.qwenModel = "qwen3.5-plus"
        src.deepseekModel = "deepseek-v4-pro"
        src.aiTemperature = 0.7
        src.aiMaxTokens = 4000
        src.aiMaxPromptLength = 1000
        src.aiDefaultDailyLimit = 500
        src.aiDefaultMonthlyLimit = 5000
        src.aiRequestTimeout = 60
        src.aiMaxRetries = 5
        src.aiRetryDelay = 4
        src.aiRequestDelay = 3
        src.articleTextSize = .large
        src.articleFont = .serif
        src.useSystemBrowser = true
        src.articleFullscreenEnabled = true

        let data = src.exportSyncedSettings()
        #expect(!data.isEmpty)

        let dst = AppSettings(defaults: freshDefaults(label: "dst"))
        dst.applySyncedSettings(data)

        #expect(dst.activeAIProvider == .anthropic)
        #expect(dst.retentionDays == 14)
        #expect(dst.backgroundInterval == 1800.0)
        #expect(dst.redditEnabled == true)
        #expect(dst.redditUserAgent == "TestAgent/2")
        #expect(dst.youtubeEnabled == true)
        #expect(dst.notificationsEnabled == true)
        #expect(dst.openaiAPIURL == "https://custom.api/v1")
        #expect(dst.openaiModel == "gpt-4o")
        #expect(dst.anthropicModel == "claude-sonnet-4-6")
        #expect(dst.geminiModel == "gemini-2.5-pro")
        #expect(dst.mistralModel == "mistral-large-latest")
        #expect(dst.qwenModel == "qwen3.5-plus")
        #expect(dst.deepseekModel == "deepseek-v4-pro")
        #expect(dst.aiTemperature == 0.7)
        #expect(dst.aiMaxTokens == 4000)
        #expect(dst.aiMaxPromptLength == 1000)
        #expect(dst.aiDefaultDailyLimit == 500)
        #expect(dst.aiDefaultMonthlyLimit == 5000)
        #expect(dst.aiRequestTimeout == 60)
        #expect(dst.aiMaxRetries == 5)
        #expect(dst.aiRetryDelay == 4)
        #expect(dst.aiRequestDelay == 3)
        #expect(dst.articleTextSize == .large)
        #expect(dst.articleFont == .serif)
        #expect(dst.useSystemBrowser == true)
        #expect(dst.articleFullscreenEnabled == true)
    }

    // MARK: Exclusion

    @Test func excludedPrefsAreNotCarriedOver() throws {
        let src = AppSettings(defaults: freshDefaults(label: "excl-src"))
        // Set excluded prefs on source.
        src.hasCompletedOnboarding = true
        src.preferredVoiceIdentifier = "com.apple.voice.test"
        src.includeUntagged = false
        src.iCloudSyncEnabled = true

        let data = src.exportSyncedSettings()

        // Target has opposite excluded values — they must not be overwritten.
        let dst = AppSettings(defaults: freshDefaults(label: "excl-dst"))
        dst.hasCompletedOnboarding = false
        dst.preferredVoiceIdentifier = "com.apple.voice.other"
        dst.includeUntagged = true
        dst.iCloudSyncEnabled = false

        dst.applySyncedSettings(data)

        // Excluded fields remain unchanged on target.
        #expect(dst.hasCompletedOnboarding == false)
        #expect(dst.preferredVoiceIdentifier == "com.apple.voice.other")
        #expect(dst.includeUntagged == true)
        #expect(dst.iCloudSyncEnabled == false)
    }

    @Test func iCloudSyncEnabledIsNeverInPayload() throws {
        let src = AppSettings(defaults: freshDefaults(label: "flag-src"))
        src.iCloudSyncEnabled = true

        let data = src.exportSyncedSettings()
        // Inspect raw JSON: must not contain the key.
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("iCloudSyncEnabled"))
        #expect(!json.contains("iCloud"))
    }

    // MARK: Notification

    @Test func applyingDifferentTextSizePostsNotification() throws {
        let src = AppSettings(defaults: freshDefaults(label: "notif-src"))
        src.articleTextSize = .large
        let data = src.exportSyncedSettings()

        let dst = AppSettings(defaults: freshDefaults(label: "notif-dst"))
        dst.articleTextSize = .small  // different from what will be applied

        nonisolated(unsafe) var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: AppSettings.articleTextSizeDidChange,
            object: nil,
            queue: nil
        ) { _ in posted = true }

        dst.applySyncedSettings(data)
        NotificationCenter.default.removeObserver(token)

        #expect(posted)
    }

    // MARK: Tolerance

    @Test func applyingEmptyPayloadDoesNotCrash() {
        let dst = AppSettings(defaults: freshDefaults(label: "empty"))
        dst.applySyncedSettings(Data())  // should not throw/crash
        // Defaults should be intact.
        #expect(dst.retentionDays == 30)
    }

    @Test func partialPayloadAppliesOnlyPresentFields() throws {
        // Build a payload with only retentionDays set.
        let partial = """
        {"retentionDays": 7}
        """.data(using: .utf8)!

        let dst = AppSettings(defaults: freshDefaults(label: "partial"))
        let originalInterval = dst.backgroundInterval
        dst.applySyncedSettings(partial)

        #expect(dst.retentionDays == 7)
        #expect(dst.backgroundInterval == originalInterval)  // untouched
    }

    // MARK: iCloudSyncEnabled toggle

    @Test func iCloudSyncEnabledDefaultsToFalse() {
        let s = AppSettings(defaults: freshDefaults(label: "toggle"))
        #expect(s.iCloudSyncEnabled == false)
    }

    @Test func iCloudSyncEnabledPersists() {
        let defaults = freshDefaults(label: "persist")
        let s = AppSettings(defaults: defaults)
        s.iCloudSyncEnabled = true
        #expect(AppSettings(defaults: defaults).iCloudSyncEnabled == true)
    }

    // MARK: Timeline position sync

    @Test func timelinePositionSyncsWhenEnabled() throws {
        let target = Date(timeIntervalSince1970: 1_700_000_000)
        let src = AppSettings(defaults: freshDefaults(label: "pos-src"))
        src.syncTimelinePositionEnabled = true
        src.timelinePositionTimestamp = target

        let data = src.exportSyncedSettings()

        let dst = AppSettings(defaults: freshDefaults(label: "pos-dst"))
        dst.syncTimelinePositionEnabled = true
        dst.applySyncedSettings(data)

        #expect(dst.timelinePositionTimestamp == target)
    }

    @Test func timelinePositionExcludedFromPayloadWhenDisabled() throws {
        let src = AppSettings(defaults: freshDefaults(label: "pos-off-src"))
        src.syncTimelinePositionEnabled = false
        src.timelinePositionTimestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let data = src.exportSyncedSettings()
        let synced = try #require(try? JSONDecoder().decode(AppSettings.SyncedSettings.self, from: data))
        #expect(synced.timelinePosition == nil)
    }

    @Test func timelinePositionNotAppliedWhenReceiverOptedOut() throws {
        let src = AppSettings(defaults: freshDefaults(label: "pos-recv-src"))
        src.syncTimelinePositionEnabled = true
        src.timelinePositionTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let data = src.exportSyncedSettings()

        // Receiver has NOT opted in: an incoming position must be ignored.
        let dst = AppSettings(defaults: freshDefaults(label: "pos-recv-dst"))
        dst.syncTimelinePositionEnabled = false
        dst.applySyncedSettings(data)

        #expect(dst.timelinePositionTimestamp == nil)
    }

    @Test func syncTimelinePositionEnabledIsNeverInPayload() throws {
        let src = AppSettings(defaults: freshDefaults(label: "pos-flag"))
        src.syncTimelinePositionEnabled = true

        let data = src.exportSyncedSettings()
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("syncTimelinePositionEnabled"))
    }

    @Test func applyingDifferentTimelinePositionPostsNotification() throws {
        let src = AppSettings(defaults: freshDefaults(label: "pos-notif-src"))
        src.syncTimelinePositionEnabled = true
        src.timelinePositionTimestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let data = src.exportSyncedSettings()

        let dst = AppSettings(defaults: freshDefaults(label: "pos-notif-dst"))
        dst.syncTimelinePositionEnabled = true

        nonisolated(unsafe) var posted = false
        let token = NotificationCenter.default.addObserver(
            forName: AppSettings.timelinePositionDidChange,
            object: nil,
            queue: nil
        ) { _ in posted = true }

        dst.applySyncedSettings(data)
        NotificationCenter.default.removeObserver(token)

        #expect(posted)
    }
}

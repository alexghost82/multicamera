import CameraCore
import SwiftUI
import Combine

@MainActor final class LocalVideoAnalyticsEngine: ObservableObject {
    var settings = VideoAnalyticsSettings.safeDefaults
    let settingsWriteGate = ACTAAnalyticsSettingsWriteGate()
    func updateSettings(_ value: VideoAnalyticsSettings, expectedRevision: UUID? = nil) throws { settings = value }
}

struct AppLanguage {
    func localized(_ text: String) -> String { text }
    func localizedMessage(_ text: String) -> String { text }
}
extension Locale { var appLanguage: AppLanguage { AppLanguage() } }
enum ACTATheme {
    static let danger = Color.red
    static let success = Color.green
    static let actionFill = Color.blue
}

import SwiftUI

private struct OpenUnifiedChatKey: EnvironmentKey {
    static let defaultValue: (String) -> Void = { _ in }
}
extension EnvironmentValues {
    var openUnifiedChat: (String) -> Void {
        get { self[OpenUnifiedChatKey.self] }
        set { self[OpenUnifiedChatKey.self] = newValue }
    }
}

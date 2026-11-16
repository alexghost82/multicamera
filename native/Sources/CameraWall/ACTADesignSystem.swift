import SwiftUI

/// Shared visual tokens for every ACTA screen, inspector and editor.
enum ACTATheme {
    static let background = Color.appBackground
    static let sidebar = Color.panelBackground
    static let surface = Color.panelBackground
    static let surfaceElevated = Color(actaHex: 0x152338)
    static let surfaceHover = Color(actaHex: 0x1B3047)
    static let border = Color(actaHex: 0x2D435A)
    static let controlBorder = Color(actaHex: 0x60758C)
    static let borderActive = Color(actaHex: 0x00CCFF)
    static let selected = Color(actaHex: 0x00CCFF).opacity(0.12)
    static let primary = Color(actaHex: 0xFFDA00)
    static let secondaryAccent = Color(actaHex: 0x00CCFF)
    static let actionFill = Color(actaHex: 0x086A8C)
    static let textPrimary = Color(actaHex: 0xF2F6FA)
    static let textSecondary = Color(actaHex: 0xBDCAD8)
    static let textMuted = Color(actaHex: 0x98AABE)
    static let success = Color.neonGreen
    static let danger = Color.neonRed
    static let dangerFill = Color(actaHex: 0xB8243D)
    static let warning = Color(actaHex: 0xFFDA00)
}

enum ACTAType {
    static let metadata: CGFloat = 12
    static let caption: CGFloat = 14
    static let body: CGFloat = 16
    static let heading: CGFloat = 20
    static let title: CGFloat = 24
    static let metric: CGFloat = 32
}

enum ACTASpacing {
    static let small: CGFloat = 8
    static let regular: CGFloat = 12
    static let content: CGFloat = 16
    static let section: CGFloat = 24
}

struct ACTAAppAppearance: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: ACTAType.body))
            .foregroundStyle(ACTATheme.textPrimary)
            .tint(ACTATheme.secondaryAccent)
            .preferredColorScheme(.dark)
            .background(ACTATheme.background)
    }
}

extension View {
    func actaAppearance() -> some View { modifier(ACTAAppAppearance()) }
    func actaStatusGlow(_ color: Color, enabled: Bool = true) -> some View {
        glow(color: enabled ? color : .clear, radius: 4)
    }
}

extension Color {
    init(actaHex: UInt32) {
        self.init(red: Double((actaHex >> 16) & 0xFF) / 255,
                  green: Double((actaHex >> 8) & 0xFF) / 255,
                  blue: Double(actaHex & 0xFF) / 255)
    }
}

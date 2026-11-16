import SwiftUI
import Charts

extension Color {
    static let appBackground = Color(red: 0.02, green: 0.04, blue: 0.08)
    static let panelBackground = Color(red: 0.05, green: 0.08, blue: 0.12)
    static let neonBlue = Color(red: 0.0, green: 0.8, blue: 1.0)
    static let neonYellow = Color(red: 1.0, green: 0.85, blue: 0.0)
    static let neonGreen = Color(red: 0.0, green: 0.9, blue: 0.3)
    static let neonRed = Color(red: 1.0, green: 0.2, blue: 0.2)
}

// Усиленный модификатор свечения
struct NeonGlow: ViewModifier {
    var color: Color
    var radius: CGFloat
    
    func body(content: Content) -> some View {
        content
            .shadow(color: color, radius: radius / 2, x: 0, y: 0)
            .shadow(color: color.opacity(0.8), radius: radius, x: 0, y: 0)
            .shadow(color: color.opacity(0.4), radius: radius * 2, x: 0, y: 0)
    }
}

extension View {
    func glow(color: Color, radius: CGFloat = 5) -> some View {
        self.modifier(NeonGlow(color: color, radius: radius))
    }
}



struct ActiveMenuButton: View {
    var icon: String
    var title: String
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundColor(.neonYellow).frame(width: 24)
            Text(title).foregroundColor(.white).fontWeight(.semibold)
            Spacer()
        }
        .padding(.vertical, 12).padding(.horizontal, 16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(LinearGradient(gradient: Gradient(colors: [Color.neonBlue.opacity(0.3), Color.clear]), startPoint: .leading, endPoint: .trailing))
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.neonBlue, lineWidth: 1.5).glow(color: .neonBlue, radius: 4))
        .padding(.horizontal, 16)
    }
}

struct InactiveMenuButton: View {
    var icon: String; var title: String
    var body: some View {
        HStack {
            Image(systemName: icon).foregroundColor(.gray).frame(width: 24)
            Text(title).foregroundColor(.gray)
            Spacer()
        }
        .padding(.vertical, 12).padding(.horizontal, 32)
    }
}

struct HeaderIconButton: View {
    var icon: String; var showBadge: Bool = false
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(systemName: icon).foregroundColor(.white).frame(width: 40, height: 40).background(Color.panelBackground).cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
            if showBadge {
                Circle().fill(Color.neonRed).frame(width: 8, height: 8).offset(x: 2, y: -2).glow(color: .neonRed, radius: 2)
            }
        }
    }
}

struct AIModuleCell: View {
    var icon: String; var title: String; var status: String; var isProcessing: Bool
    var statusColor: Color? = nil
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundColor(isProcessing ? .neonYellow : .neonBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundColor(.white).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 4) {
                    Circle().fill(statusColor ?? (isProcessing ? Color.neonYellow : Color.neonGreen)).frame(width: 6, height: 6).glow(color: statusColor ?? (isProcessing ? .neonYellow : .neonGreen), radius: 2)
                    Text(status).font(.caption2).foregroundColor(.gray).lineLimit(1).fixedSize()
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8).background(Color.panelBackground).cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isProcessing ? Color.neonYellow.opacity(0.5) : Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct CircularProgressView: View {
    var value: Double?; var title: String; var color: Color
    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing) {
                Text(title).font(.caption).foregroundColor(.gray).lineLimit(1)
                Text(value.map { "\(Int($0 * 100))%" } ?? "—").font(.title3).bold().foregroundColor(color).lineLimit(1).fixedSize()
            }
            ZStack {
                Circle().stroke(color.opacity(0.15), lineWidth: 4)
                Circle().trim(from: 0, to: CGFloat(value ?? 0)).stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90)).glow(color: color, radius: 4)
            }.frame(width: 34, height: 34)
        }
        .padding(.horizontal, 10).padding(.vertical, 6).background(Color.panelBackground).cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct FilterTag: View {
    var title: String; var isActive: Bool; var hasClose: Bool = false
    var body: some View {
        HStack {
            Text(title).font(.caption).foregroundColor(isActive ? .neonYellow : .white).lineLimit(1).fixedSize()
            if hasClose { Image(systemName: "xmark").font(.caption2).foregroundColor(isActive ? .neonYellow : .gray) }
        }
        .padding(.horizontal, 12).padding(.vertical, 8).background(Color.panelBackground).cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isActive ? Color.neonYellow : Color.white.opacity(0.1), lineWidth: 1))
    }
}

struct EventCategoryCard: View {
    var icon: String; var count: String; var title: String; var isWarning: Bool = false
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.title3).foregroundColor(isWarning ? .neonYellow : .neonBlue)
            VStack(alignment: .leading, spacing: 2) {
                Text(count).font(.title3).bold().foregroundColor(.white).lineLimit(1)
                Text(title).font(.caption).foregroundColor(.gray).lineLimit(1).fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10).background(Color.appBackground).cornerRadius(8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1), lineWidth: 1))
    }
}

/// Layout taken directly from the supplied DashboardView; slots connect it to ACTA's live state.
struct DashboardView<Sidebar: View, Header: View, Metrics: View, Filters: View, Content: View, Analytics: View>: View {
    @ViewBuilder var sidebar: () -> Sidebar
    @ViewBuilder var header: () -> Header
    @ViewBuilder var metrics: () -> Metrics
    @ViewBuilder var filters: () -> Filters
    @ViewBuilder var content: () -> Content
    @ViewBuilder var analytics: () -> Analytics
    var body: some View {
        HStack(spacing: 0) {
            sidebar().frame(width: 260).background(Color.panelBackground)
                .border(Color.white.opacity(0.1), width: 1)
            VStack(spacing: 16) {
                header()
                metrics()
                filters()
                content().frame(maxWidth: .infinity, maxHeight: .infinity)
                analytics()
            }
            .padding(16)
            .background(Color.appBackground)
        }
        .preferredColorScheme(.dark)
    }
}

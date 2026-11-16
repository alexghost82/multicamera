import SwiftUI
import Charts
import Combine
import CameraCore

struct ACTAEventActivitySnapshot {
    let safetyCount: Int
    let aiCount: Int
    let cameraCount: Int
    let buckets: [Int]
    var total: Int { safetyCount + aiCount + cameraCount }

    init(alerts: [VLMAlert], incidents: [SafetyIncident], hardwareEvents: [ISAPIEventRecord], now: Date) {
        let cutoff = now.addingTimeInterval(-86_400)
        func retained(_ rows: [(UUID, Date)]) -> [Date] {
            Dictionary(grouping: rows, by: { $0.0 }).values.compactMap { group in
                group.map { $0.1 }.min()
            }.filter { $0 >= cutoff && $0 <= now }
        }
        let safetyIDs = Set(incidents.map(\.id))
        let safety = retained(incidents.map { ($0.id, $0.createdAt) })
        let ai = retained(alerts.filter { !safetyIDs.contains($0.id) }.map { ($0.id, $0.createdAt) })
        let camera = retained(hardwareEvents.map { ($0.id, $0.occurredAt ?? $0.receivedAt) })
        safetyCount = safety.count
        aiCount = ai.count
        cameraCount = camera.count
        var bins = Array(repeating: 0, count: 24)
        for date in safety + ai + camera {
            bins[min(23, max(0, Int(date.timeIntervalSince(cutoff) / 3600)))] += 1
        }
        buckets = bins
    }
}

/// A visual summary of saved records, with safety alerts deduplicated from the AI feed.
struct ACTAActivitySummaryView: View, Equatable {
    let alerts: [VLMAlert]
    let incidents: [SafetyIncident]
    let hardwareEvents: [ISAPIEventRecord]
    let openEvents: () -> Void
    let openAlert: (VLMAlert) -> Void
    @Environment(\.locale) private var locale
    @State private var now = Date()
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.alerts == rhs.alerts && lhs.incidents == rhs.incidents && lhs.hardwareEvents == rhs.hardwareEvents
    }

    private var language: AppLanguage { locale.appLanguage }
    private var cutoff: Date { now.addingTimeInterval(-86_400) }
    private var snapshot: ACTAEventActivitySnapshot {
        ACTAEventActivitySnapshot(alerts: alerts, incidents: incidents, hardwareEvents: hardwareEvents, now: now)
    }
    private var buckets: [Int] { snapshot.buckets }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                total
                HStack(spacing: 12) {
                    EventCategoryCard(icon: "exclamationmark.triangle", count: "\(snapshot.safetyCount)", title: language.localized("Safety incidents"), isWarning: true)
                    EventCategoryCard(icon: "sparkles", count: "\(snapshot.aiCount)", title: language.localized("AI alerts"))
                    EventCategoryCard(icon: "video", count: "\(snapshot.cameraCount)", title: language.localized("Camera events"))
                }
                Spacer()
                histogram.frame(width: 300, height: 50)
            }
            HStack(spacing: 16) { total; histogram.frame(minWidth: 180, maxWidth: .infinity).frame(height: 50) }
        }
        .padding(16).background(Color.panelBackground).cornerRadius(12)
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.1), lineWidth: 1))
        .onReceive(timer) { now = $0 }
        .onChange(of: alerts.map(\.id) + incidents.map(\.id) + hardwareEvents.map(\.id)) { _, _ in now = Date() }
        .help(language.localized("Stored events from the last 24 hours"))
        .onTapGesture(perform: openEvents)
        .accessibilityAddTraits(.isButton)
    }

    private var total: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(language.localized("EVENTS · 24H")).foregroundColor(.white).font(.subheadline).lineLimit(1).fixedSize()
            Text("\(snapshot.total)").font(.system(size: 34, weight: .bold)).foregroundColor(.neonYellow).glow(color: .neonYellow, radius: 5)
            Text(language.localized("Stored events")).foregroundColor(.gray).font(.caption).lineLimit(1).fixedSize()
        }.frame(minWidth: 150, alignment: .leading)
    }

    private var histogram: some View {
        Chart(Array(buckets.enumerated()), id: \.offset) { index, value in
            BarMark(x: .value(language.localized("Time"), index), y: .value(language.localized("Events"), value))
                .foregroundStyle(ACTATheme.primary)
                .cornerRadius(2)
        }
        .chartXScale(domain: 0...24)
        .chartYScale(domain: 0...max(1, buckets.max() ?? 1))
        .chartXAxis {
            AxisMarks(values: [0, 6, 12, 18, 24]) { value in
                AxisValueLabel {
                    if let hour = value.as(Int.self) {
                        Text(cutoff.addingTimeInterval(Double(hour) * 3600)
                            .formatted(date: .omitted, time: .shortened, locale: locale))
                            .font(.system(size: ACTAType.metadata))
                            .foregroundStyle(ACTATheme.textSecondary)
                    }
                }
            }
        }
        .chartYAxis(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.localized("Stored event counts by hour"))
        .accessibilityValue(buckets.map(String.init).joined(separator: ", "))
    }
}

import SwiftUI
import CameraCore

struct DetectionOverlay: View {
    @Environment(\.locale) private var locale
    var objects: [DetectedObject]
    var imageSize: CGSize

    var body: some View {
        GeometryReader { geometry in
            ForEach(objects) { object in
                let box = DetectionGeometry.displayRect(box: object.box, image: imageSize, viewport: geometry.size)
                Rectangle()
                    .stroke(ACTATheme.success, lineWidth: 2)
                    .frame(width: box.width, height: box.height)
                    .position(x: box.midX, y: box.midY)
                Text("\(locale.appLanguage.localized(object.label)) \(Int(object.confidence * 100))%\(object.trackID.map { " · t\(String($0.uuidString.prefix(6)))" } ?? "")")
                    .font(.system(size: ACTAType.metadata, weight: .semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(ACTATheme.success)
                    .lineLimit(1)
                    .frame(maxWidth: min(180, geometry.size.width), alignment: .leading)
                    .position(x: min(geometry.size.width - min(180, geometry.size.width) / 2,
                                     max(min(180, geometry.size.width) / 2, box.minX + min(180, geometry.size.width) / 2)),
                              y: max(9, box.minY - 9))
            }
        }
        .clipped()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
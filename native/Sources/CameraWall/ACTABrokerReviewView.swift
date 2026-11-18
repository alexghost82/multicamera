import CameraCore
import SwiftUI

/// Render every scalar explicitly when it could be invisible or direction-changing.
enum ACTABrokerReviewRendering {
    static func exact(_ value: String) -> String {
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x22: result += "\\\""
            case 0x5C: result += "\\\\"
            case 0x20...0x7E: result.unicodeScalars.append(scalar)
            default: result += "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            }
        }
        return result + "\""
    }

    static func parameters(_ review: ACTABrokerReview) -> [(String, String)] {
        review.parameters.sorted { $0.key.utf8.lexicographicallyPrecedes($1.key.utf8) }
            .map { (exact($0.key), exact($0.value)) }
    }
}

@MainActor
final class ACTABrokerReviewController: ObservableObject, Identifiable {
    let review: ACTABrokerReview
    nonisolated let id: ObjectIdentifier
    @Published var reviewedAll = false
    @Published private(set) var resolving = false
    private let broker: ACTALocalActionBroker
    private let operatorKey: ACTABrokerOperator
    private let session: ACTABrokerSession
    private let isCurrent: @MainActor () -> Bool

    init(broker: ACTALocalActionBroker, operatorKey: ACTABrokerOperator,
         session: ACTABrokerSession, review: ACTABrokerReview,
         isCurrent: @escaping @MainActor () -> Bool = { true }) {
        self.broker = broker
        self.operatorKey = operatorKey
        self.session = session
        self.review = review
        self.id = ObjectIdentifier(review.handle)
        self.isCurrent = isCurrent
    }

    func resolve(_ approved: Bool) async -> ACTAActionResult? {
        guard isCurrent(), !resolving, !approved || reviewedAll else { return nil }
        resolving = true
        defer { resolving = false }
        return await broker.resolve(operatorKey: operatorKey, session: session,
                                    reviewed: review, approved: approved)
    }
}

/// Host code must keep this view and its capabilities outside model/tool output.
struct ACTABrokerReviewView: View {
    @ObservedObject var controller: ACTABrokerReviewController
    let onResult: @MainActor (ACTAActionResult) -> Void

    var body: some View {
        let review = controller.review
        VStack(alignment: .leading, spacing: 10) {
            Text("Review proposed action").font(.headline)
            Text("Exact review uses escaped Unicode; no characters are omitted.")
                .font(.caption)
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Action").font(.caption.bold())
                    Text(verbatim: ACTABrokerReviewRendering.exact(review.actionID))
                    Text("Thread").font(.caption.bold())
                    Text(verbatim: ACTABrokerReviewRendering.exact(review.threadID))
                    Text("Complete review").font(.caption.bold())
                    Text(verbatim: ACTABrokerReviewRendering.exact(review.title))
                    Text("Action details").font(.caption.bold())
                    ForEach(Array(ACTABrokerReviewRendering.parameters(review).enumerated()), id: \.offset) { _, field in
                        VStack(alignment: .leading) {
                            Text(verbatim: field.0)
                            Text(verbatim: field.1)
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.disabled)
            }
            Toggle("I reviewed the complete request", isOn: $controller.reviewedAll)
                .disabled(controller.resolving)
            HStack {
                Button("Confirm") { resolve(true) }
                    .disabled(!controller.reviewedAll || controller.resolving)
                Button("Reject", role: .destructive) { resolve(false) }
                    .disabled(controller.resolving)
            }
        }
    }

    private func resolve(_ approved: Bool) {
        Task { @MainActor in
            if let result = await controller.resolve(approved) { onResult(result) }
        }
    }
}

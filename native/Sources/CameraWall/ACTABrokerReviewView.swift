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
        await resolve(approved, authorized: { true })
    }

    private func resolve(_ approved: Bool, authorized: @MainActor () -> Bool) async -> ACTAActionResult? {
        guard isCurrent(), !resolving, (!approved || reviewedAll), authorized() else { return nil }
        resolving = true
        defer { resolving = false }
        guard isCurrent(), (!approved || reviewedAll), authorized() else { return nil }
        return await broker.resolve(operatorKey: operatorKey, session: session,
                                    reviewed: review, approved: approved)
    }

    func resolveVoice(_ transcript: LocalVoiceFinalTranscript, challenge: LocalVoiceReviewChallenge,
                      voiceInput: LocalVoiceInput) async -> ACTAActionResult? {
        await resolve(true, authorized: {
            voiceInput.isInputAllowed && voiceInput.finalTranscript == transcript
                && voiceInput.permissionRevision == challenge.permissionRevision
                && challenge.matches(transcript)
        })
    }
}

/// Host code must keep this view and its capabilities outside model/tool output.
struct ACTABrokerReviewView: View {
    @ObservedObject var controller: ACTABrokerReviewController
    @ObservedObject var voiceInput: LocalVoiceInput
    let voiceAllowed: Bool
    let voiceLocaleIdentifier: String
    let onResult: @MainActor (ACTAActionResult, Bool) -> Void
    @State private var voiceChallenge: LocalVoiceReviewChallenge?
    @State private var voiceNotice: String?

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
                    Text("Operation ID").font(.caption.bold())
                    Text(verbatim: review.operationID.uuidString)
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
                .disabled(controller.resolving || ownsVoiceAttempt)
            if let challenge = voiceChallenge {
                Text("Say the displayed phrase and code, then stop recording.")
                    .font(.caption)
                Text(verbatim: "\(challenge.phrase) \(challenge.code)")
                    .font(.system(.body, design: .monospaced))
                Text("Speech is not speaker authentication. Do not play recordings near the microphone.")
                    .font(.caption)
            }
            if let voiceNotice { Text(LocalizedStringKey(voiceNotice)).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Confirm") { resolve(true) }
                    .disabled(!controller.reviewedAll || controller.resolving || ownsVoiceAttempt)
                Button("Reject", role: .destructive) { resolve(false) }
                    .disabled(controller.resolving || ownsVoiceAttempt)
                Button(ownsVoiceAttempt ? "Stop voice confirmation" : "Confirm by voice") {
                    if let challenge = voiceChallenge, voiceInput.isOwned(by: challenge.owner) {
                        voiceInput.finishAndWaitForFinal(owner: challenge.owner)
                    } else {
                        guard voiceAllowed, !LocalVoiceOutput.shared.isAttemptActive else {
                            voiceNotice = "Stop dictation or speech before speaking."
                            return
                        }
                        let challenge = LocalVoiceReviewChallenge(localeIdentifier: voiceLocaleIdentifier,
                                                                  permissionRevision: voiceInput.permissionRevision)
                        voiceChallenge = challenge
                        voiceNotice = nil
                        if voiceInput.start(localeIdentifier: voiceLocaleIdentifier, owner: challenge.owner) == nil {
                            voiceChallenge = nil
                            voiceNotice = "Voice confirmation could not be started."
                        }
                    }
                }
                .disabled(!voiceAllowed || !controller.reviewedAll || controller.resolving ||
                          voiceInput.isFinalizing || (voiceInput.isBusy && !ownsVoiceAttempt))
                if ownsVoiceAttempt, let challenge = voiceChallenge {
                    Button("Cancel voice confirmation") {
                        voiceInput.cancel(owner: challenge.owner)
                        voiceChallenge = nil
                        voiceNotice = "Voice confirmation cancelled."
                    }
                }
            }
        }
        .onChange(of: voiceInput.finalTranscript) { _, transcript in
            guard let transcript, let challenge = voiceChallenge, transcript.owner == challenge.owner else { return }
            guard voiceAllowed, voiceInput.isInputAllowed, controller.reviewedAll, challenge.matches(transcript) else {
                voiceChallenge = nil
                voiceNotice = "Voice confirmation did not match; the action was not approved."
                return
            }
            Task { @MainActor in
                guard voiceChallenge?.owner == challenge.owner else { return }
                let result = await controller.resolveVoice(transcript, challenge: challenge, voiceInput: voiceInput)
                let challengeIsCurrent = voiceChallenge?.owner == challenge.owner
                if challengeIsCurrent { voiceChallenge = nil }
                if let result {
                    onResult(result, true)
                } else if challengeIsCurrent {
                    voiceNotice = "Voice confirmation did not match; the action was not approved."
                }
            }
        }
        .onChange(of: voiceInput.isBusy) { _, busy in
            guard !busy, let challenge = voiceChallenge, !voiceInput.isOwned(by: challenge.owner) else { return }
            if voiceInput.finalTranscript?.owner != challenge.owner {
                voiceChallenge = nil
                voiceNotice = voiceInput.errorMessage ?? "Voice confirmation cancelled."
            }
        }
        .onChange(of: voiceAllowed) { _, allowed in
            if !allowed, let challenge = voiceChallenge {
                voiceInput.cancel(owner: challenge.owner)
                voiceChallenge = nil
            }
        }
        .onDisappear {
            if let challenge = voiceChallenge { voiceInput.cancel(owner: challenge.owner) }
            voiceChallenge = nil
        }
    }

    private var ownsVoiceAttempt: Bool {
        voiceChallenge.map { voiceInput.isOwned(by: $0.owner) } ?? false
    }

    private func resolve(_ approved: Bool) {
        Task { @MainActor in
            if let result = await controller.resolve(approved) { onResult(result, false) }
        }
    }
}

import CameraCore
import SwiftUI

/// Pass the same lifetime-scoped domain used by the broker; nil fails closed.
struct ACTAIdentityFollowUpSection: View {
    let domain: ACTAIdentityFollowUpDomain?

    var body: some View {
        GroupBox {
            if let domain {
                ACTAIdentityFollowUpControls(domain: domain)
                    .id(ObjectIdentifier(domain))
            } else {
                Label("Identity follow-up is unavailable. Restart or contact the operator.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        } label: {
            Label("Identity follow-up", systemImage: "flag")
        }
    }
}

struct ACTAIdentityFollowUpControls: View {
    @ObservedObject private var domain: ACTAIdentityFollowUpDomain
    @StateObject private var state: ACTAIdentityFollowUpOperatorState

    init(domain: ACTAIdentityFollowUpDomain) {
        self.domain = domain
        _state = StateObject(wrappedValue: ACTAIdentityFollowUpOperatorState(domain: domain))
    }

    init(state: ACTAIdentityFollowUpOperatorState) {
        domain = state.domain
        _state = StateObject(wrappedValue: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("A follow-up flag is an operator reminder, not proof of identity or wrongdoing.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if domain.canStart {
                HStack {
                    TextField("Exact identity ID", text: Binding(
                        get: { state.identityID }, set: { state.setIdentityID($0) }))
                        .accessibilityIdentifier("identity-follow-up-id")
                    Button("Check flag") { state.refresh() }
                        .accessibilityIdentifier("identity-follow-up-check")
                }
                if let readout = state.readout {
                    Text("Last checked identity: \(readout.identityID)")
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    flagStatus(readout.flagged)
                    Text("Use Check flag to refresh; another application instance may change it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Label("The last update may have completed. Identity follow-up changes are blocked until you inspect and acknowledge the stored result.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(ACTATheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("identity-follow-up-uncertain")
                Button("Inspect stored result") { state.inspectUncertainOutcome() }
                    .accessibilityIdentifier("identity-follow-up-inspect")
                if let readout = state.recoveryReadout {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Identity to verify: \(readout.identityID)")
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        flagStatus(readout.flagged)
                        Toggle("I checked this identity and its stored follow-up flag.", isOn: Binding(
                            get: { state.acknowledged }, set: { state.setAcknowledged($0) }))
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("identity-follow-up-reviewed")
                        Button("Confirm review and unblock") { state.confirmRecovery() }
                            .disabled(!state.canConfirmRecovery)
                            .accessibilityIdentifier("identity-follow-up-reconcile")
                    }
                }
            }
            messageView
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: domain.changeToken) { _, _ in state.domainChanged() }
    }

    private func flagStatus(_ flagged: Bool) -> some View {
        Group {
            if flagged {
                Label("Follow-up flag: On", systemImage: "flag.fill")
            } else {
                Label("Follow-up flag: Off", systemImage: "flag")
            }
        }.accessibilityIdentifier("identity-follow-up-status")
    }

    @ViewBuilder
    private var messageView: some View {
        switch state.message {
        case .invalidID:
            Text("Enter an exact identity ID using letters, numbers, hyphens, underscores, periods or colons.")
        case .notFound:
            Text("No saved identity matches this ID.")
        case .unavailable:
            Text("The flag could not be read. Changes remain blocked if the previous outcome is uncertain.")
        case .inspectAgain:
            Text("The stored identity or flag changed. Inspect it again before confirming.")
        case .recovered:
            Text("Stored result reviewed. Follow-up changes are available again.")
        case nil:
            EmptyView()
        }
    }
}

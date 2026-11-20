import CameraCore
import Combine
import Foundation

/// Keep one domain for all sessions. The flag is operator workflow metadata;
/// it does not assert a person's identity, a match, or wrongdoing.
@MainActor
final class ACTAIdentityFollowUpDomain: ObservableObject {
    private let store: ACTAIdentityFollowUpSQLiteStore
    private var uncertainIdentityID: String?
    private var awaitingVerification: ACTAIdentityFollowUpSnapshot?
    private var busy = false
    @Published private(set) var changeToken = UUID()

    init(trackingStore: LocalTrackingStore) throws {
        store = try trackingStore.makeACTAIdentityFollowUpStore()
    }

    var canStart: Bool {
        !busy && uncertainIdentityID == nil && awaitingVerification == nil
            && (try? store.hasPendingRecovery()) == false
    }

    private func signalChange() {
        let wasBusy = busy
        busy = true
        changeToken = UUID()
        busy = wasBusy
    }

    func capture(identityID: String) throws -> ACTAIdentityFollowUpSnapshot? {
        guard canStart else { throw Failure.unavailable }
        do { return try store.capture(identityID: identityID) }
        catch { throw Failure.unavailable }
    }

    func commit(expected: ACTAIdentityFollowUpSnapshot, flagged: Bool) throws
        -> ACTAIdentityFollowUpSnapshot? {
        guard canStart else { throw Failure.unavailable }
        busy = true
        defer { busy = false; signalChange() }
        let result: ACTAIdentityFollowUpSnapshot?
        do { result = try store.commit(expected: expected, flagged: flagged) }
        catch {
            uncertainIdentityID = expected.identityID
            throw Failure.unknownOutcome
        }
        guard let result else { return nil }
        awaitingVerification = result
        return result
    }

    func verify(_ snapshot: ACTAIdentityFollowUpSnapshot) -> Bool {
        guard !busy, uncertainIdentityID == nil, awaitingVerification == snapshot else { return false }
        busy = true
        defer { busy = false; signalChange() }
        do {
            guard try store.finish(snapshot) else {
                uncertainIdentityID = snapshot.identityID
                return false
            }
            awaitingVerification = nil
            return true
        } catch {
            uncertainIdentityID = snapshot.identityID
            return false
        }
    }

    fileprivate struct Reconciliation {
        let snapshot: ACTAIdentityFollowUpSnapshot
        let durable: ACTAIdentityFollowUpRecoverySnapshot?
    }

    fileprivate func reconciliationSnapshot() throws -> Reconciliation {
        guard !busy else { throw Failure.unavailable }
        if let pending = try store.recoverySnapshot() {
            return Reconciliation(snapshot: pending.snapshot, durable: pending)
        }
        guard let identityID = uncertainIdentityID,
              let snapshot = try store.capture(identityID: identityID) else { throw Failure.unavailable }
        return Reconciliation(snapshot: snapshot, durable: nil)
    }

    /// The local operator must inspect this exact snapshot before acknowledging it.
    fileprivate func reconcile(reviewed: Reconciliation) throws {
        guard !busy else { throw Failure.unavailable }
        busy = true
        var recovered = false
        defer { busy = false; if recovered { signalChange() } }
        if let durable = reviewed.durable {
            guard try store.reconcile(durable) else { throw Failure.unavailable }
        } else {
            guard uncertainIdentityID == reviewed.snapshot.identityID,
                  try store.capture(identityID: reviewed.snapshot.identityID) == reviewed.snapshot else {
                throw Failure.unavailable
            }
        }
        if uncertainIdentityID == reviewed.snapshot.identityID { uncertainIdentityID = nil }
        if awaitingVerification?.identityID == reviewed.snapshot.identityID { awaitingVerification = nil }
        recovered = true
    }

    enum Failure: Error { case unavailable, unknownOutcome }
}

/// Owned only by the operator view; broker/model code receives no recovery capability.
@MainActor
final class ACTAIdentityFollowUpOperatorState: ObservableObject {
    struct Readout: Equatable {
        let identityID: String
        let flagged: Bool
    }

    enum Message: Equatable {
        case invalidID, notFound, unavailable, inspectAgain, recovered
    }

    let domain: ACTAIdentityFollowUpDomain
    @Published private(set) var identityID = ""
    @Published private(set) var readout: Readout?
    @Published private(set) var recoveryReadout: Readout?
    @Published private(set) var acknowledged = false
    @Published private(set) var message: Message?
    private var recoverySnapshot: ACTAIdentityFollowUpDomain.Reconciliation?
    private var observedChangeToken: UUID
    private var transitioning = false

    init(domain: ACTAIdentityFollowUpDomain) {
        self.domain = domain
        observedChangeToken = domain.changeToken
    }

    var canConfirmRecovery: Bool {
        !transitioning && !domain.canStart && recoverySnapshot != nil && recoveryReadout != nil && acknowledged
    }

    func setIdentityID(_ value: String) {
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        identityID = value
        readout = nil
        message = nil
    }

    func refresh() {
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        refreshLocked()
    }

    private func refreshLocked() {
        observedChangeToken = domain.changeToken
        readout = nil
        guard domain.canStart else { message = .unavailable; return }
        guard ACTAIdentityFollowUpSQLiteStore.validIdentityID(identityID) else {
            message = .invalidID
            return
        }
        do {
            guard let snapshot = try domain.capture(identityID: identityID) else {
                message = .notFound
                return
            }
            readout = Readout(identityID: snapshot.identityID, flagged: snapshot.flagged)
            message = nil
        } catch { message = .unavailable }
    }

    func domainChanged() {
        guard !transitioning else { return }
        guard observedChangeToken != domain.changeToken else { return }
        transitioning = true
        defer { transitioning = false }
        observedChangeToken = domain.changeToken
        resetRecovery()
        if domain.canStart {
            let justRecovered = message == .recovered
            if !identityID.isEmpty { refreshLocked() }
            else { readout = nil }
            if justRecovered, readout != nil { message = .recovered }
        } else {
            readout = nil
            message = .unavailable
        }
    }

    func inspectUncertainOutcome() {
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        observedChangeToken = domain.changeToken
        resetRecovery()
        guard !domain.canStart else { message = .unavailable; return }
        do {
            let snapshot = try domain.reconciliationSnapshot()
            recoverySnapshot = snapshot
            recoveryReadout = Readout(identityID: snapshot.snapshot.identityID, flagged: snapshot.snapshot.flagged)
            message = nil
        } catch { message = .unavailable }
    }

    func setAcknowledged(_ value: Bool) {
        guard !transitioning else { return }
        transitioning = true
        defer { transitioning = false }
        acknowledged = value && recoverySnapshot != nil && recoveryReadout != nil && !domain.canStart
    }

    func confirmRecovery() {
        guard canConfirmRecovery, let snapshot = recoverySnapshot else { return }
        transitioning = true
        defer { transitioning = false }
        do {
            try domain.reconcile(reviewed: snapshot)
            observedChangeToken = domain.changeToken
            resetRecovery()
            identityID = snapshot.snapshot.identityID
            refreshLocked()
            if readout != nil { message = .recovered }
        } catch {
            resetRecovery()
            message = .inspectAgain
        }
    }

    private func resetRecovery() {
        acknowledged = false
        recoveryReadout = nil
        recoverySnapshot = nil
    }
}

struct ACTAPreparedIdentityFollowUpAction: ACTAPreparedConfirmationAction {
    @MainActor final class State {
        var receipt: (parameters: [String: String], threadID: String, snapshot: ACTAIdentityFollowUpSnapshot)?
    }
    @MainActor final class Ticket {
        let owner: State
        var used = false
        init(owner: State) { self.owner = owner }
    }
    struct ConfirmationSnapshot: Sendable {
        fileprivate let parameters: [String: String]
        fileprivate let threadID: String
        fileprivate let before: ACTAIdentityFollowUpSnapshot
        fileprivate let ticket: Ticket
    }

    let id = "identity.set_follow_up"
    let title = "Set identity follow-up flag"
    let description = "Set an operator follow-up flag; it is not an identity verification."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "identity_id", type: "string", description: "Exact identity ID", isRequired: true),
        ACTAActionParameterSchema(name: "flagged", type: "boolean", description: "Desired follow-up flag", isRequired: true)
    ]
    private let domain: ACTAIdentityFollowUpDomain
    private let state: State

    @MainActor init(domain: ACTAIdentityFollowUpDomain) {
        self.domain = domain
        state = State()
    }

    private func parse(_ parameters: [String: String]) throws -> (String, Bool) {
        guard Set(parameters.keys) == ["identity_id", "flagged"],
              let id = parameters["identity_id"], ACTAIdentityFollowUpSQLiteStore.validIdentityID(id),
              let flag = parameters["flagged"], flag == "true" || flag == "false" else {
            throw Failure.invalid
        }
        return (id, flag == "true")
    }

    func validate(parameters: [String: String]) throws { _ = try parse(parameters) }
    func requiresConfirmation(parameters: [String: String]) -> Bool { true }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let (id, flagged) = try parse(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let before = try? domain.capture(identityID: id) else { throw Failure.unavailable }
            return ACTAPreparedConfirmation(
                snapshot: ConfirmationSnapshot(parameters: parameters, threadID: context.threadID,
                                               before: before, ticket: Ticket(owner: state)),
                reviewSummary: "Identity \(id): follow-up \(before.flagged) → \(flagged). This flag does not verify identity. Readback does not establish crash durability.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        try await MainActor.run {
            try Task.checkCancellation()
            guard snapshot.ticket.owner === state, !snapshot.ticket.used else {
                return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review is invalid or already used.")
            }
            snapshot.ticket.used = true
            guard context.isConfirmed, parameters == snapshot.parameters, context.threadID == snapshot.threadID else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request, thread or approval changed.")
            }
            let (_, flagged) = try parse(parameters)
            guard state.receipt == nil else { return .failed(actionID: id, error: "ACTION_BUSY: Awaiting verification.") }
            let result: ACTAIdentityFollowUpSnapshot?
            do { result = try domain.commit(expected: snapshot.before, flagged: flagged) }
            catch { return .failed(actionID: id, error: "COMMIT_FAILED: Outcome may be unknown.") }
            guard let result else { return .failed(actionID: id, error: "STALE_REVIEW: Identity changed.") }
            state.receipt = (parameters, context.threadID, result)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Follow-up flag updated and read back; crash durability is not verified.",
                outputJSON: "{\"flagged\":\(flagged)}")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            let receipt = state.receipt
            state.receipt = nil
            guard context.isConfirmed, let receipt, receipt.parameters == parameters,
                  receipt.threadID == context.threadID else { return false }
            return domain.verify(receipt.snapshot)
        }
    }

    private enum Failure: LocalizedError {
        case invalid, unavailable
        var errorDescription: String? {
            switch self {
            case .invalid: return "INVALID_ARGUMENT: Provide an exact identity ID and boolean flag."
            case .unavailable: return "UNAVAILABLE: Identity follow-up is unavailable."
            }
        }
    }
}

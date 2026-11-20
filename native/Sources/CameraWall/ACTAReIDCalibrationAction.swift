import CameraCore
import Combine
import Foundation

private enum ReIDCalibrationPrecision {
    static func sliderValue(_ value: Double) -> Double? {
        guard value.isFinite, (0.90...1.0).contains(value) else { return nil }
        let tick = (value * 200).rounded()
        let snapped = tick / 200
        // Allow only floating-point roundoff, not a meaningful fraction of a slider step.
        guard abs(value - snapped) <= 8 * max(value.ulp, snapped.ulp) else { return nil }
        return snapped
    }
}

@propertyWrapper
struct CalibrationPrecisionValue {
    private let subject: CurrentValueSubject<Double, Never>
    init(wrappedValue: Double) { subject = CurrentValueSubject(wrappedValue) }
    var wrappedValue: Double {
        get { subject.value }
        nonmutating set { subject.send(newValue) }
    }
    var projectedValue: AnyPublisher<Double, Never> { subject.eraseToAnyPublisher() }
}

@MainActor
final class ACTAReIDCalibrationViewState: ObservableObject {
    // SwiftUI is notified before the write, but value subscribers see the
    // committed value. @Published's will-set emission would permit a subscriber
    // to detach the reviewed view before its setter nevertheless writes.
    nonisolated(unsafe) let objectWillChange = ObservableObjectPublisher()
    @CalibrationPrecisionValue private(set) var targetPrecision = ReIDThresholdCalibrator.defaultTargetPrecision
    private(set) var revision = UUID()
    private var updating = false
    private var reentered = false

    func setTargetPrecision(_ value: Double) -> Bool {
        setTargetPrecision(value, while: { true })
    }

    fileprivate func setTargetPrecision(_ value: Double, while isCurrent: @MainActor () -> Bool) -> Bool {
        guard !updating else { reentered = true; return false }
        guard let value = ReIDCalibrationPrecision.sliderValue(value) else { return false }
        updating = true
        reentered = false
        defer { updating = false }
        objectWillChange.send()
        guard !reentered, isCurrent() else { return false }
        revision = UUID()
        targetPrecision = value
        return !reentered
    }
}

@MainActor
final class ACTAReIDCalibrationViewBridge {
    static let shared = ACTAReIDCalibrationViewBridge()

    private struct Entry {
        weak var state: ACTAReIDCalibrationViewState?
    }
    private var entries: [Entry] = []
    private(set) var lifecycleRevision = UUID()
    private weak var writtenState: ACTAReIDCalibrationViewState?
    private var writtenRevision: UUID?
    private var writtenValue: Double?

    func attach(_ state: ACTAReIDCalibrationViewState) {
        lifecycleRevision = UUID()
        clearReceipt()
        entries.removeAll { $0.state == nil || $0.state === state }
        entries.append(Entry(state: state))
    }

    func detach(_ state: ACTAReIDCalibrationViewState) {
        lifecycleRevision = UUID()
        clearReceipt()
        entries.removeAll { $0.state == nil || $0.state === state }
    }

    fileprivate var activeState: ACTAReIDCalibrationViewState? {
        let states = entries.compactMap(\.state)
        return states.count == 1 ? states.first : nil
    }

    func setTargetPrecision(_ value: Double) -> Bool {
        clearReceipt()
        guard let value = ReIDCalibrationPrecision.sliderValue(value),
              let state = activeState, state.setTargetPrecision(value) else { return false }
        writtenState = state
        writtenRevision = state.revision
        writtenValue = value
        return verifies(value)
    }

    func verifies(_ value: Double) -> Bool {
        guard let state = activeState, state === writtenState else { return false }
        return writtenRevision == state.revision && writtenValue == value && state.targetPrecision == value
    }

    private func clearReceipt() {
        writtenState = nil
        writtenRevision = nil
        writtenValue = nil
    }
}

/// Broker-only action; the legacy shared-registry action retains its direct semantics.
struct ACTAReviewedReIDCalibrationAction: ACTAPreparedConfirmationAction {
    @MainActor final class Ticket {
        weak var state: ACTAReIDCalibrationViewState?
        weak var owner: Receipt?
        var used = false
        init(state: ACTAReIDCalibrationViewState, owner: Receipt) {
            self.state = state
            self.owner = owner
        }
    }
    @MainActor final class Receipt {
        var value: (ticket: Ticket, lifecycle: UUID, revision: UUID,
                    parameters: [String: String], threadID: String)?
    }
    struct ConfirmationSnapshot: Sendable {
        fileprivate let lifecycle: UUID
        fileprivate let revision: UUID
        fileprivate let before: Double
        fileprivate let parameters: [String: String]
        fileprivate let threadID: String
        fileprivate let ticket: Ticket
    }

    let id = "settings.update_reid_calibration"
    let title = "Set ReID calibration target precision"
    let description = "Review the target precision in the unique attached calibration view. A changed target may trigger asynchronous validation metric recalculation; completion and rendering are not verified. No threshold is applied or saved."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "target_precision", type: "number",
                                  description: "Target precision from 0.90 to 1.0 inclusive, in 0.005 steps", isRequired: true)
    ]
    private let bridge: ACTAReIDCalibrationViewBridge
    private let receipt: Receipt

    @MainActor init(bridge: ACTAReIDCalibrationViewBridge) {
        self.bridge = bridge
        self.receipt = Receipt()
    }

    private func target(_ parameters: [String: String]) throws -> Double {
        guard Set(parameters.keys) == ["target_precision"],
              let value = parameters["target_precision"].flatMap(Double.init),
              let normalized = ReIDCalibrationPrecision.sliderValue(value) else {
            throw ReIDCalibrationActionError.invalidSliderArgument
        }
        return normalized
    }

    func validate(parameters: [String: String]) throws { _ = try target(parameters) }

    func prepareConfirmation(parameters: [String: String], context: ACTAActionContext) async throws
        -> ACTAPreparedConfirmation<ConfirmationSnapshot> {
        let value = try target(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState else { throw ReIDCalibrationActionError.unavailable }
            let snapshot = ConfirmationSnapshot(lifecycle: bridge.lifecycleRevision,
                                                revision: state.revision, before: state.targetPrecision,
                                                parameters: parameters, threadID: context.threadID,
                                                ticket: Ticket(state: state, owner: receipt))
            return ACTAPreparedConfirmation(snapshot: snapshot,
                reviewSummary: "Calibration view target precision: \(snapshot.before) -> \(value). A changed target may trigger asynchronous validation metric recalculation; completion, metrics and rendering are not verified. No threshold is saved or applied.")
        }
    }

    func executeConfirmed(parameters: [String: String], context: ACTAActionContext,
                          snapshot: ConfirmationSnapshot) async throws -> ACTAActionResult {
        let value = try target(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard snapshot.ticket.owner === receipt, !snapshot.ticket.used else {
                return .failed(actionID: id, error: "CONFIRMATION_CONSUMED: Review already used.")
            }
            snapshot.ticket.used = true
            guard context.isConfirmed else {
                return .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Operator approval is required.")
            }
            guard parameters == snapshot.parameters, context.threadID == snapshot.threadID else {
                return .failed(actionID: id, error: "CONFIRMATION_MISMATCH: Request changed.")
            }
            guard receipt.value == nil else {
                return .failed(actionID: id, error: "ACTION_BUSY: A previous update awaits verification.")
            }
            guard let state = snapshot.ticket.state else {
                return .failed(actionID: id, error: "STALE_REVIEW: Calibration view changed.")
            }
            @MainActor func current() -> Bool {
                bridge.activeState === state && bridge.lifecycleRevision == snapshot.lifecycle
            }
            guard current(), state.revision == snapshot.revision,
                  state.targetPrecision == snapshot.before else {
                return .failed(actionID: id, error: "STALE_REVIEW: Calibration view changed.")
            }
            let changed = state.setTargetPrecision(value, while: {
                !Task.isCancelled && current() && state.revision == snapshot.revision
            })
            // The final publication runs after the state changes. A subscriber may
            // detach or attempt a nested write then; never claim that outcome verified.
            guard changed, current(), state.targetPrecision == value else {
                return .failed(actionID: id, error: "READBACK_FAILED: Calibration view may have changed.")
            }
            receipt.value = (snapshot.ticket, snapshot.lifecycle, state.revision, parameters, context.threadID)
            return ACTAActionResult(actionID: id, success: true,
                summary: "Calibration view state updated. A changed target may trigger asynchronous validation metric recalculation; completion, metrics and rendering were not verified. No threshold was saved or applied.")
        }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        .failed(actionID: id, error: "CONFIRMATION_REQUIRED: Prepare and approve a review.")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        await MainActor.run {
            let written = receipt.value
            receipt.value = nil
            guard let written, let state = written.ticket.state,
                  written.parameters == parameters, written.threadID == context.threadID,
                  bridge.activeState === state, bridge.lifecycleRevision == written.lifecycle,
                  state.revision == written.revision,
                  let target = try? target(parameters) else { return false }
            return state.targetPrecision == target
        }
    }
}

struct ACTAUpdateReIDCalibrationAction: ACTAActionProtocol {
    let id = "settings.update_reid_calibration"
    let title = "Set ReID calibration target precision"
    let description = "Set the transient target precision in the unique attached ReID calibration view. Does not save or apply a threshold; verification checks view state, not metrics or rendering."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "target_precision", type: "number",
                                  description: "Target precision from 0.90 to 1.0 inclusive, in 0.005 steps", isRequired: true)
    ]
    let bridge: ACTAReIDCalibrationViewBridge

    private func target(_ parameters: [String: String]) throws -> Double {
        guard Set(parameters.keys) == ["target_precision"],
              let value = parameters["target_precision"].flatMap(Double.init),
              let normalized = ReIDCalibrationPrecision.sliderValue(value) else {
            throw ReIDCalibrationActionError.invalidSliderArgument
        }
        return normalized
    }

    func validate(parameters: [String: String]) throws { _ = try target(parameters) }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let value = try target(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard bridge.setTargetPrecision(value) else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique attached ReID calibration view.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Updated target precision in the calibration view; metrics and rendering were not verified, and no threshold was saved or applied.")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let value = try target(parameters)
        return await MainActor.run { bridge.verifies(value) }
    }
}

enum ReIDCalibrationActionError: LocalizedError {
    case invalidArgument
    case invalidSliderArgument
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidArgument: return "INVALID_ARGUMENT: target_precision must be a finite number in 0.90...1.0."
        case .invalidSliderArgument: return "INVALID_ARGUMENT: target_precision must be in 0.90...1.0 in 0.005 steps."
        case .unavailable: return "UNAVAILABLE: ReID validation data is unavailable."
        }
    }
}

@MainActor
protocol ACTAReIDCalibrationProvider: Sendable {
    func calibrate(targetPrecision: Double) async throws -> ReIDCalibrationResult
}

@MainActor
final class ACTAWallReIDCalibrationProvider: ACTAReIDCalibrationProvider {
    private weak var model: WallModel?

    init(model: WallModel) { self.model = model }

    func calibrate(targetPrecision: Double) async throws -> ReIDCalibrationResult {
        guard let model else { throw ReIDCalibrationActionError.unavailable }
        return try await model.calculateReIDCalibration(targetPrecision: targetPrecision)
    }
}

struct ACTAReIDCalibrationAction: ACTAActionProtocol {
    let provider: any ACTAReIDCalibrationProvider
    let id = "reid.calibrate"
    let title = "Calculate ReID recommendation"
    let description = "Calculate aggregate ReID validation metrics from locally labeled pairs. Does not apply or save a threshold."
    let classification = ACTAActionClassification.inspect
    let parameters = [
        ACTAActionParameterSchema(name: "target_precision", type: "number",
                                  description: "Target precision between 0.90 and 1.0 inclusive", isRequired: true)
    ]

    private func target(_ parameters: [String: String]) throws -> Double {
        guard Set(parameters.keys) == ["target_precision"],
              let raw = parameters["target_precision"], let value = Double(raw),
              value.isFinite, (0.90...1.0).contains(value) else {
            throw ReIDCalibrationActionError.invalidArgument
        }
        return value
    }

    func validate(parameters: [String: String]) throws { _ = try target(parameters) }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let value = try target(parameters)
        try Task.checkCancellation()
        let result: ReIDCalibrationResult
        do {
            result = try await provider.calibrate(targetPrecision: value)
        } catch is CancellationError {
            throw CancellationError()
        } catch ReIDCalibrationActionError.unavailable {
            return .failed(actionID: id, error: "UNAVAILABLE: ReID validation data is unavailable.")
        } catch {
            return .failed(actionID: id, error: "SOURCE_ERROR: ReID calibration failed.")
        }
        try Task.checkCancellation()
        let output = Aggregate(result)
        let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
        return ACTAActionResult(actionID: id, success: true,
                                summary: "Calculated ReID validation metrics; no settings were changed.",
                                outputJSON: json)
    }

    private struct Aggregate: Encodable {
        let positive_pairs: Int
        let negative_pairs: Int
        let target_precision: Double
        let ready: Bool
        let recommended_distance: Double?
        let precision: Double?
        let recall: Double?
        let false_positives: Int?
        let true_positives: Int?

        init(_ result: ReIDCalibrationResult) {
            positive_pairs = result.positivePairs
            negative_pairs = result.negativePairs
            target_precision = result.targetPrecision
            ready = result.isReady
            recommended_distance = result.recommendedDistance
            precision = result.precision
            recall = result.recall
            false_positives = result.falsePositives
            true_positives = result.truePositives
        }
    }
}

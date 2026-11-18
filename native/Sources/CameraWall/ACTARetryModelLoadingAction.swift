import CameraCore
import Foundation

struct ACTAModelRetryConfiguration: Equatable {
    let path: String
    let enabled: Set<LocalModelService>
    let registryGeneration: UUID
}

private final class ModelRetryCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
    func isCancelled() -> Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
}

@MainActor
final class ACTAModelRetryService {
    private weak var runtime: LocalModelRuntime?
    private let configuration: @MainActor () -> ACTAModelRetryConfiguration?
    private let notify: @MainActor () -> Void
    private var inFlight = false
    private var receipt: (attempt: LocalModelRuntime.RetryReceipt, configuration: ACTAModelRetryConfiguration)?

    init(runtime: LocalModelRuntime,
         configuration: @escaping @MainActor () -> ACTAModelRetryConfiguration?,
         notify: @escaping @MainActor () -> Void = {}) {
        self.runtime = runtime
        self.configuration = configuration
        self.notify = notify
    }

    convenience init(model: WallModel) {
        self.init(runtime: model.modelRuntime, configuration: { [weak model] in
            guard let model else { return nil }
            let snapshot = ModelSelectionRegistry.snapshot()
            guard snapshot.preferences == model.modelPreferences else { return nil }
            let selected = snapshot.preferences.paths[.qwen].flatMap {
                $0.isEmpty ? nil : URL(fileURLWithPath: $0).path
            }
            return ACTAModelRetryConfiguration(path: selected ?? model.vlmPreferences.model,
                enabled: snapshot.preferences.enabled, registryGeneration: snapshot.generation)
        }, notify: { [weak model] in
            model?.notice = "Retrying failed local model preparation; this may use significant resources."
        })
    }

    func retry(actionID: String) async throws -> ACTAActionResult {
        guard !inFlight, receipt == nil else {
            return .failed(actionID: actionID, error: "ACTION_BUSY: A model retry is executing or awaiting verification.")
        }
        guard !Task.isCancelled else {
            return .failed(actionID: actionID, error: "CANCELLED: Model retry was not started.")
        }
        let cancellation = ModelRetryCancellation()
        guard let runtime, let configuration = configuration(),
              let attempt = runtime.beginCheckedRetry(modelPath: configuration.path, enabled: configuration.enabled,
                  shouldContinue: { !cancellation.isCancelled() && self.configuration() == configuration }) else {
            return .failed(actionID: actionID, error: "NOT_RETRYABLE: No failed models can be safely retried; preparation may be active or settings and runtime may differ.")
        }
        inFlight = true
        notify()
        await withTaskCancellationHandler {
            await runtime.waitForRetry(attempt)
        } onCancel: {
            cancellation.cancel()
        }
        guard !Task.isCancelled, let current = self.configuration(), current == configuration,
              runtime.isRetryVerified(attempt, modelPath: current.path, enabled: current.enabled) else {
            inFlight = false
            return .failed(actionID: actionID, error: "RETRY_NOT_VERIFIED: Preparation may have changed model state, but completion was cancelled, failed, or superseded.")
        }
        inFlight = false
        let services = attempt.retried.map(\.rawValue).sorted()
        let output = try JSONEncoder().encode(["retried": services])
        receipt = (attempt, configuration)
        return ACTAActionResult(actionID: actionID, success: true,
            summary: "Failed models were prepared and runtime readiness verified; actual inference was not tested.",
            outputJSON: String(decoding: output, as: UTF8.self))
    }

    func verify() -> Bool {
        guard !inFlight else { return false }
        defer { receipt = nil }
        guard !Task.isCancelled, let runtime, let receipt, let current = configuration(),
              current == receipt.configuration else { return false }
        return runtime.isRetryVerified(receipt.attempt, modelPath: current.path, enabled: current.enabled)
    }
}

struct ACTARetryModelLoadingAction: ACTAActionProtocol {
    let id = "settings.retry_model_loading"
    let title = "Retry failed local model loading"
    let description = "Retry only failed enabled local models when all other runtime states and settings match. Preparation can use significant resources; readiness does not prove inference works."
    let classification = ACTAActionClassification.serviceAffecting
    let parameters: [ACTAActionParameterSchema] = []
    private let service: ACTAModelRetryService

    @MainActor init(model: WallModel) { service = ACTAModelRetryService(model: model) }
    @MainActor init(service: ACTAModelRetryService) { self.service = service }

    func validate(parameters: [String: String]) throws {
        guard parameters.isEmpty else { throw ConfigurationError.invalid("This action takes no parameters.") }
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        try validate(parameters: parameters)
        return try await service.retry(actionID: id)
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        try validate(parameters: parameters)
        return await service.verify()
    }
}

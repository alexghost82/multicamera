import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor RetryLoader {
    var calls: [LocalModelService] = []
    var failures: Set<LocalModelService> = [.segmentation]
    var block = false
    private var blocked: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func load(_ service: LocalModelService) async throws {
        calls.append(service)
        if service == .segmentation && block {
            await withCheckedContinuation { continuation in
                blocked = continuation
                observer?.resume()
                observer = nil
            }
        }
        if failures.contains(service) { throw LocalVLMError.invalidResponse }
    }

    func configure(fail: Bool, block: Bool = false) {
        failures = fail ? [.segmentation] : []
        self.block = block
    }
    func configure(failures: Set<LocalModelService>) { self.failures = failures }
    func waitUntilBlocked() async {
        if blocked != nil { return }
        await withCheckedContinuation { observer = $0 }
    }
    func release() { blocked?.resume(); blocked = nil }
}

@MainActor
final class ACTARetryModelLoadingActionTests: XCTestCase {
    private let path = "/synthetic/model"
    private let generation = UUID()

    private func configuration(_ path: String, _ enabled: Set<LocalModelService>) -> ACTAModelRetryConfiguration {
        ACTAModelRetryConfiguration(path: path, enabled: enabled, registryGeneration: generation)
    }

    func testRetryUsesRuntimeAndOnlyRetriesFailures() async throws {
        let loader = RetryLoader()
        let runtime = LocalModelRuntime { service, _ in try await loader.load(service) }
        let enabled: Set<LocalModelService> = [.yolo, .segmentation]
        await runtime.start(modelPath: path, enabled: enabled).value
        await loader.configure(fail: false)
        var notices = 0
        let service = ACTAModelRetryService(runtime: runtime, configuration: { self.configuration(self.path, enabled) }, notify: { notices += 1 })
        let action = ACTARetryModelLoadingAction(service: service)
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__settings__retry_model_loading" })
        let result = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertTrue(result.success, result.summary)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(result.outputJSON, "{\"retried\":[\"segmentation\"]}")
        XCTAssertEqual(notices, 1)
        let calls = await loader.calls
        XCTAssertEqual(calls, [.yolo, .segmentation, .segmentation])
        XCTAssertEqual(runtime.states[.segmentation], .ready)
        let again = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(again.success)
        let callsAfter = await loader.calls
        XCTAssertEqual(callsAfter, calls)
    }

    func testRejectsWaitingSettingsChangesAndInvalidArgumentsWithoutLoading() async throws {
        let loader = RetryLoader()
        let runtime = LocalModelRuntime { service, _ in try await loader.load(service) }
        let enabled: Set<LocalModelService> = [.segmentation]
        var currentPath = path
        var currentEnabled = enabled
        let action = ACTARetryModelLoadingAction(service: ACTAModelRetryService(runtime: runtime,
            configuration: { self.configuration(currentPath, currentEnabled) }))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let waiting = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(waiting.success)
        await runtime.start(modelPath: path, enabled: enabled).value
        currentPath = "/synthetic/other"
        let changedPath = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(changedPath.success)
        currentPath = path
        currentEnabled.insert(.yolo)
        let changedEnabled = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(changedEnabled.success)
        currentEnabled = enabled
        let invalid = try await registry.execute(actionID: action.id, parameters: ["extra": "1"])
        XCTAssertFalse(invalid.success)
        let calls = await loader.calls
        XCTAssertEqual(calls, [.segmentation])
    }

    func testFailureAndSupersessionNeverReportSuccess() async throws {
        let loader = RetryLoader()
        let runtime = LocalModelRuntime { service, _ in try await loader.load(service) }
        let enabled: Set<LocalModelService> = [.segmentation]
        await runtime.start(modelPath: path, enabled: enabled).value
        let action = ACTARetryModelLoadingAction(service: ACTAModelRetryService(runtime: runtime,
            configuration: { self.configuration(self.path, enabled) }))
        let registry = ACTAActionRegistry()
        await registry.register(action)
        let failure = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(failure.success)
        XCTAssertFalse(failure.verified)
        await loader.configure(fail: false, block: true)
        let task = Task { try await registry.execute(actionID: action.id, parameters: [:]) }
        await loader.waitUntilBlocked()
        let busy = try await registry.execute(actionID: action.id, parameters: [:])
        XCTAssertFalse(busy.success)
        runtime.cancel()
        await loader.release()
        let superseded = try await task.value
        XCTAssertFalse(superseded.success)
        XCTAssertFalse(superseded.verified)
        XCTAssertNotEqual(runtime.states[.segmentation], .ready)
    }

    func testVerificationRejectsChangedConfigurationAndCancelledCaller() async throws {
        let loader = RetryLoader()
        let runtime = LocalModelRuntime { service, _ in try await loader.load(service) }
        let enabled: Set<LocalModelService> = [.segmentation]
        await runtime.start(modelPath: path, enabled: enabled).value
        await loader.configure(fail: false)
        var currentPath = path
        let action = ACTARetryModelLoadingAction(service: ACTAModelRetryService(runtime: runtime,
            configuration: { self.configuration(currentPath, enabled) }))
        let result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.success)
        currentPath = "/synthetic/other"
        let verified = try await action.verify(parameters: [:], context: ACTAActionContext())
        XCTAssertFalse(verified)

        currentPath = path
        runtime.invalidate()
        await loader.configure(fail: true)
        await runtime.start(modelPath: path, enabled: enabled).value
        await loader.configure(fail: false, block: true)
        let task = Task { try await action.execute(parameters: [:], context: ACTAActionContext()) }
        await loader.waitUntilBlocked()
        task.cancel()
        await loader.release()
        let cancelled = try await task.value
        XCTAssertFalse(cancelled.success)
        XCTAssertFalse(cancelled.verified)
    }

    func testChangedRegistryGenerationInvalidatesReceipt() async throws {
        let loader = RetryLoader()
        let runtime = LocalModelRuntime { service, _ in try await loader.load(service) }
        let enabled: Set<LocalModelService> = [.segmentation]
        await runtime.start(modelPath: path, enabled: enabled).value
        await loader.configure(fail: false)
        var generation = UUID()
        let action = ACTARetryModelLoadingAction(service: ACTAModelRetryService(runtime: runtime,
            configuration: { ACTAModelRetryConfiguration(path: self.path, enabled: enabled, registryGeneration: generation) }))
        let result = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertTrue(result.success)
        generation = UUID()
        let verified = try await action.verify(parameters: [:], context: ACTAActionContext())
        XCTAssertFalse(verified)
    }

    func testRegistryGenerationChangesEvenWhenPreferencesAreRestored() {
        let previous = ModelSelectionRegistry.snapshot().preferences
        defer { ModelSelectionRegistry.update(previous) }
        let first = ModelSelectionRegistry.snapshot()
        ModelSelectionRegistry.update(previous)
        let second = ModelSelectionRegistry.snapshot()
        XCTAssertEqual(first.preferences, second.preferences)
        XCTAssertNotEqual(first.generation, second.generation)
    }

    func testConfigurationChangeDuringRetryFailsEvenIfLoaderSucceeds() async throws {
        let loader = RetryLoader()
        let runtime = LocalModelRuntime { service, _ in try await loader.load(service) }
        let enabled: Set<LocalModelService> = [.segmentation, .personReID]
        await loader.configure(failures: enabled)
        await runtime.start(modelPath: path, enabled: enabled).value
        await loader.configure(fail: false, block: true)
        var generation = UUID()
        let action = ACTARetryModelLoadingAction(service: ACTAModelRetryService(runtime: runtime,
            configuration: { ACTAModelRetryConfiguration(path: self.path, enabled: enabled, registryGeneration: generation) }))
        let task = Task { try await action.execute(parameters: [:], context: ACTAActionContext()) }
        await loader.waitUntilBlocked()
        let overlapping = try await action.execute(parameters: [:], context: ACTAActionContext())
        XCTAssertFalse(overlapping.success)
        generation = UUID()
        await loader.release()
        let result = try await task.value
        XCTAssertFalse(result.success)
        XCTAssertEqual(runtime.states[.segmentation], .ready)
        let calls = await loader.calls
        XCTAssertEqual(calls, [.segmentation, .personReID, .segmentation])
    }

    func testCancellationPreventsStartingRemainingFailedModels() async throws {
        let loader = RetryLoader()
        let runtime = LocalModelRuntime { service, _ in try await loader.load(service) }
        let enabled: Set<LocalModelService> = [.segmentation, .personReID]
        await loader.configure(failures: enabled)
        await runtime.start(modelPath: path, enabled: enabled).value
        await loader.configure(fail: false, block: true)
        let action = ACTARetryModelLoadingAction(service: ACTAModelRetryService(runtime: runtime,
            configuration: { self.configuration(self.path, enabled) }))
        let task = Task { try await action.execute(parameters: [:], context: ACTAActionContext()) }
        await loader.waitUntilBlocked()
        task.cancel()
        await loader.release()
        let result = try await task.value
        XCTAssertFalse(result.success)
        let calls = await loader.calls
        XCTAssertEqual(calls, [.segmentation, .personReID, .segmentation])
    }
}

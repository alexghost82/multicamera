import CameraCore
import Combine
import XCTest
@testable import CameraWall

@MainActor
private final class ReentrantLanguageStorage: LanguageSettingsStorage {
    var value: String?
    var beforeWrite: (() -> Void)?

    func string(forKey key: String) -> String? { value }
    func set(_ value: String, forKey key: String) {
        let callback = beforeWrite
        beforeWrite = nil
        callback?()
        self.value = value
    }
}

@MainActor
final class ACTAReviewedLanguageActionTests: XCTestCase {
    func testGUIChangePublishesOldValueBeforeWriting() {
        let settings = LanguageSettings(storage: InMemoryLanguageStorage())
        var observed: [AppLanguage] = []
        let observer = settings.objectWillChange.sink { observed.append(settings.language) }
        settings.toggle()
        withExtendedLifetime(observer) {}
        XCTAssertEqual(observed, [.english])
        XCTAssertEqual(settings.language, .russian)
        XCTAssertEqual(settings.storedLanguage, "ru")
    }

    func testReviewedModelRequestUpdatesLanguageAndRejectsReplay() async throws {
        let storage = InMemoryLanguageStorage()
        let settings = LanguageSettings(storage: storage)
        let action = ACTAReviewedLanguageAction(settings: settings)
        let made = await ACTALocalActionBroker.make(
            actions: [action], allowedActionIDs: [action.id], audit: { _ in })
        let host = try XCTUnwrap(made)
        let opened = await host.broker.openSession(operatorKey: host.operatorKey,
            input: .chat, threadID: "test", actionIDs: [action.id])
        let session = try XCTUnwrap(opened)
        let coordinator = ACTAAnalyticsCoordinator(aiClient: ACTAAIClient(
            config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }, keyProvider: { _ in XCTFail("Unexpected Keychain access"); return nil }))
        let name = "acta__settings__update_system"
        let request = await coordinator.executeModelGeneratedAgentTool(
            ACTAAgentFunctionCall(callID: "language", name: name, argumentsJSON: #"{"language":"ru"}"#),
            threadID: "test", requestToolNames: [name], broker: host.broker, brokerSession: session)
        XCTAssertTrue(request.outputJSON.contains("requires_operator_confirmation"))
        XCTAssertEqual(settings.language, .english)
        let reviews = await host.broker.reviews(operatorKey: host.operatorKey, session: session)
        let review = try XCTUnwrap(reviews.first)
        let result = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertTrue(result.success)
        XCTAssertTrue(result.verified)
        XCTAssertEqual(settings.language, .russian)
        XCTAssertEqual(settings.storedLanguage, "ru")
        let replay = await host.broker.resolve(operatorKey: host.operatorKey, session: session,
                                               reviewed: review, approved: true)
        XCTAssertFalse(replay.success)
        await host.broker.closeSession(session, operatorKey: host.operatorKey)
    }

    func testReviewRejectsGUIABAAndReentrantGUIWrite() async throws {
        let settings = LanguageSettings(storage: InMemoryLanguageStorage())
        let action = ACTAReviewedLanguageAction(settings: settings)
        let context = ACTAActionContext(threadID: "test")
        let parameters = ["language": "ru"]
        var prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        settings.setLanguage(.russian)
        settings.setLanguage(.english)
        var result = try await action.executeConfirmed(parameters: parameters, context: context,
                                                       snapshot: prepared.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertEqual(settings.language, .english)
        prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        var entered = false
        let observer = settings.objectWillChange.sink {
            guard !entered else { return }
            entered = true
            settings.setLanguage(.english)
        }
        result = try await action.executeConfirmed(parameters: parameters, context: context,
                                                   snapshot: prepared.snapshot)
        withExtendedLifetime(observer) {}
        XCTAssertFalse(result.success)
        XCTAssertEqual(settings.language, .english)
    }

    func testExternalStorageChangeAndFailedWriteDoNotReportSuccess() async throws {
        let storage = InMemoryLanguageStorage()
        let settings = LanguageSettings(storage: storage)
        let action = ACTAReviewedLanguageAction(settings: settings)
        let context = ACTAActionContext(threadID: "test")
        let parameters = ["language": "ru"]
        var prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        storage.values["ACTA.interfaceLanguage"] = "ru"
        var result = try await action.executeConfirmed(parameters: parameters, context: context,
                                                       snapshot: prepared.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertEqual(settings.language, .english)
        storage.values.removeValue(forKey: "ACTA.interfaceLanguage")
        storage.acceptsWrites = false
        prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        result = try await action.executeConfirmed(parameters: parameters, context: context,
                                                   snapshot: prepared.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertNil(settings.storedLanguage)
    }

    func testReentrantStorageWritePreservesLaterGUIChange() async throws {
        let storage = ReentrantLanguageStorage()
        let settings = LanguageSettings(storage: storage)
        let action = ACTAReviewedLanguageAction(settings: settings)
        let context = ACTAActionContext(threadID: "test")
        let parameters = ["language": "ru"]
        let prepared = try await action.prepareConfirmation(parameters: parameters, context: context)
        storage.beforeWrite = { settings.setLanguage(.english) }
        let result = try await action.executeConfirmed(parameters: parameters, context: context,
                                                       snapshot: prepared.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertEqual(settings.language, .english)
        XCTAssertEqual(storage.value, "en")
    }
}

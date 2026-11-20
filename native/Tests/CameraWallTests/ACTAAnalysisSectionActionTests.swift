import CameraCore
import Combine
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAAnalysisSectionActionTests: XCTestCase {
    func testGUISectionPublicationRetainsWillSet() {
        let state = ACTACanvasFilterState()
        var observed: [String] = []
        let changes = state.objectWillChange.sink { observed.append("will:\(state.analysisSection.rawValue)") }
        state.analysisSection = .alerts
        XCTAssertEqual(observed, ["will:\(VLMPanelSection.ask.rawValue)"])
        XCTAssertEqual(state.analysisSection, .alerts)
        withExtendedLifetime(changes) {}
    }

    func testReviewedChangeRejectsDictationStartedAfterReview() async throws {
        let bridge = ACTACanvasFilterBridge(voiceInputAllowed: true)
        var permission: CheckedContinuation<Bool, Never>?
        let voice = LocalVoiceInput(speechPermission: { await withCheckedContinuation { permission = $0 } },
                                    microphonePermission: { false },
                                    makeCapture: { _, _ in XCTFail("Unexpected capture"); throw CancellationError() })
        let state = ACTACanvasFilterState(analysisVoiceInput: voice)
        bridge.attach(state)
        let action = ACTAAnalysisSetSectionAction(bridge: bridge)
        let context = ACTAActionContext(isConfirmed: true)
        let parameters = ["section": "schedule"]
        let review = try await action.prepareConfirmation(parameters: parameters, context: context)
        let pending = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: review.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertEqual(state.analysisSection, .ask)
        XCTAssertTrue(state.analysisScheduleRefreshOnAppear)
        voice.stop()
        permission?.resume(returning: false)
        await pending.value
    }

    func testTypedActionSharesWindowStateWithoutChangingOtherState() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        let cameraID = UUID()
        state.searchText = "lobby"
        state.locationFilter = "Lobby"
        state.cameraScope = .offline
        state.favoritesOnly = true
        state.alertsOnly = true
        state.selectedCameraIDs = [cameraID]
        state.arrangeCameras = true
        state.presentation = .list
        bridge.attach(state)
        let registry = ACTAActionRegistry()
        let action = ACTAAnalysisSetSectionAction(bridge: bridge)
        await registry.register(action)
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        XCTAssertTrue(tools.contains { $0.name == "acta__analysis__set_section" })
        let field = try XCTUnwrap(action.parameters.first)
        XCTAssertEqual(action.parameters.count, 1)
        XCTAssertEqual(field.name, "section")
        XCTAssertEqual(field.type, "string")
        XCTAssertEqual(field.allowedValues, ["chat", "schedule", "alerts"])
        XCTAssertTrue(field.isRequired)

        for (input, expected) in [("schedule", VLMPanelSection.schedule), ("alerts", .alerts), ("chat", .ask), ("chat", .ask)] {
            let result = try await registry.executeJSON(actionID: "analysis.set_section", argumentsJSON: #"{"section":"\#(input)"}"#)
            XCTAssertTrue(result.success && result.verified, result.summary)
            XCTAssertEqual(state.analysisSection, expected)
            XCTAssertEqual(state.searchText, "lobby")
            XCTAssertEqual(state.locationFilter, "Lobby")
            XCTAssertEqual(state.cameraScope, .offline)
            XCTAssertTrue(state.favoritesOnly)
            XCTAssertTrue(state.alertsOnly)
            XCTAssertEqual(state.selectedCameraIDs, [cameraID])
            XCTAssertTrue(state.arrangeCameras)
            XCTAssertEqual(state.presentation, .list)
        }
        state.selectAnalysisSectionFromGUI(.alerts)
        XCTAssertEqual(state.analysisSection, .alerts)
    }

    func testInvalidArgumentsAndWindowAvailability() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState(), other = ACTACanvasFilterState()
        let registry = ACTAActionRegistry()
        await registry.register(ACTAAnalysisSetSectionAction(bridge: bridge))
        let missing = try await registry.executeJSON(actionID: "analysis.set_section", argumentsJSON: #"{"section":"alerts"}"#)
        XCTAssertFalse(missing.success)
        bridge.attach(state)
        for json in ["{}", #"{"section":"Chat"}"#, #"{"section":"ask"}"#, #"{"section":true}"#,
                     #"{"section":1}"#, #"{"section":null}"#, #"{"section":["chat"]}"#,
                     #"{"section":"alerts","other":true}"#] {
            let result = try await registry.executeJSON(actionID: "analysis.set_section", argumentsJSON: json)
            XCTAssertFalse(result.success, json)
            XCTAssertFalse(result.verified, json)
            XCTAssertEqual(state.analysisSection, .ask, json)
        }
        bridge.attach(other)
        let ambiguous = try await registry.executeJSON(actionID: "analysis.set_section", argumentsJSON: #"{"section":"alerts"}"#)
        XCTAssertFalse(ambiguous.success)
        XCTAssertEqual(state.analysisSection, .ask)
        XCTAssertEqual(other.analysisSection, .ask)
    }

    func testVerificationRejectsEditsReplacementAndDifferentRequest() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState(), other = ACTACanvasFilterState()
        let action = ACTAAnalysisSetSectionAction(bridge: bridge)
        let context = ACTAActionContext()
        bridge.attach(state)
        let result = try await action.execute(parameters: ["section": "alerts"], context: context)
        XCTAssertTrue(result.success)
        let verified = try await action.verify(parameters: ["section": "alerts"], context: context)
        XCTAssertTrue(verified)
        state.selectAnalysisSectionFromGUI(.schedule)
        let edited = try await action.verify(parameters: ["section": "alerts"], context: context)
        let different = try await action.verify(parameters: ["section": "schedule"], context: context)
        XCTAssertFalse(edited)
        XCTAssertFalse(different)
        bridge.attach(other)
        let ambiguous = try await action.verify(parameters: ["section": "alerts"], context: context)
        XCTAssertFalse(ambiguous)
        bridge.detach(state)
        other.analysisSection = .alerts
        let replaced = try await action.verify(parameters: ["section": "alerts"], context: context)
        XCTAssertFalse(replaced)
        bridge.detach(other)
        bridge.attach(state)
        state.analysisSection = .alerts
        let reattached = try await action.verify(parameters: ["section": "alerts"], context: context)
        XCTAssertFalse(reattached)
    }

    func testDictationGuardAndScheduleRefreshPolicy() async throws {
        let bridge = ACTACanvasFilterBridge(voiceInputAllowed: true)
        var permission: CheckedContinuation<Bool, Never>?
        let voice = LocalVoiceInput(speechPermission: { await withCheckedContinuation { permission = $0 } }, microphonePermission: { false },
                                    makeCapture: { _, _ in XCTFail("Unexpected capture"); throw CancellationError() })
        let state = ACTACanvasFilterState(analysisVoiceInput: voice)
        bridge.attach(state)
        let action = ACTAAnalysisSetSectionAction(bridge: bridge)
        let context = ACTAActionContext()
        let pending = try XCTUnwrap(voice.start(localeIdentifier: "en"))
        let blocked = try await action.execute(parameters: ["section": "schedule"], context: context)
        XCTAssertFalse(blocked.success)
        XCTAssertEqual(state.analysisSection, .ask)
        XCTAssertTrue(state.analysisScheduleRefreshOnAppear)
        let same = try await action.execute(parameters: ["section": "chat"], context: context)
        XCTAssertTrue(same.success)
        voice.stop()
        permission?.resume(returning: true)
        await pending.value
        let changed = try await action.execute(parameters: ["section": "schedule"], context: context)
        XCTAssertTrue(changed.success)
        XCTAssertFalse(state.analysisScheduleRefreshOnAppear)
        state.selectAnalysisSectionFromGUI(.alerts)
        state.selectAnalysisSectionFromGUI(.schedule)
        XCTAssertTrue(state.analysisScheduleRefreshOnAppear)
    }

    func testCancelledExecutionDoesNotChangeWindowState() async throws {
        let bridge = ACTACanvasFilterBridge()
        let state = ACTACanvasFilterState()
        bridge.attach(state)
        let action = ACTAAnalysisSetSectionAction(bridge: bridge)
        let task = Task { try await action.execute(parameters: ["section": "schedule"], context: ACTAActionContext()) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled action must not execute")
        } catch is CancellationError {
        }
        XCTAssertEqual(state.analysisSection, .ask)
        XCTAssertTrue(state.analysisScheduleRefreshOnAppear)
    }

    func testReentrantGUIEditRejectsReviewedChangeWithoutPartialScheduleWrite() async throws {
        let bridge = ACTACanvasFilterBridge(), state = ACTACanvasFilterState()
        bridge.attach(state)
        let action = ACTAAnalysisSetSectionAction(bridge: bridge), context = ACTAActionContext(isConfirmed: true)
        let parameters = ["section": "schedule"]
        let review = try await action.prepareConfirmation(parameters: parameters, context: context)
        var handled = false
        let changes = state.objectWillChange.sink {
            guard !handled else { return }
            handled = true
            state.selectAnalysisSectionFromGUI(.alerts)
        }
        let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: review.snapshot)
        XCTAssertFalse(result.success)
        XCTAssertEqual(state.analysisSection, .alerts)
        XCTAssertTrue(state.analysisScheduleRefreshOnAppear)
        let verified = try await action.verify(parameters: parameters, context: context)
        XCTAssertFalse(verified)
        withExtendedLifetime(changes) {}
    }

    func testConfirmedScheduleChangeVerifiesBothWindowFields() async throws {
        let bridge = ACTACanvasFilterBridge(), state = ACTACanvasFilterState()
        bridge.attach(state)
        let action = ACTAAnalysisSetSectionAction(bridge: bridge), context = ACTAActionContext(isConfirmed: true)
        let parameters = ["section": "schedule"]
        let review = try await action.prepareConfirmation(parameters: parameters, context: context)
        let result = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: review.snapshot)
        XCTAssertTrue(result.success)
        XCTAssertEqual(state.analysisSection, .schedule)
        XCTAssertFalse(state.analysisScheduleRefreshOnAppear)
        let verified = try await action.verify(parameters: parameters, context: context)
        XCTAssertTrue(verified)
        state.analysisScheduleRefreshOnAppear = true
        let changed = try await action.verify(parameters: parameters, context: context)
        XCTAssertFalse(changed)
    }

    func testReentrantDetachAndVoiceAttemptABARejectReviewedChange() async throws {
        let voice = LocalVoiceInput(speechPermission: { false }, microphonePermission: { false },
                                    makeCapture: { _, _ in XCTFail("Unexpected capture"); throw CancellationError() })
        let bridge = ACTACanvasFilterBridge(voiceInputAllowed: true), state = ACTACanvasFilterState(analysisVoiceInput: voice)
        bridge.attach(state)
        let action = ACTAAnalysisSetSectionAction(bridge: bridge), context = ACTAActionContext(isConfirmed: true)
        let parameters = ["section": "schedule"]

        let first = try await action.prepareConfirmation(parameters: parameters, context: context)
        var detached = false
        let changes = state.objectWillChange.sink {
            guard !detached else { return }
            detached = true
            bridge.detach(state)
            bridge.attach(state)
        }
        let detachedResult = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: first.snapshot)
        XCTAssertFalse(detachedResult.success)
        XCTAssertEqual(state.analysisSection, .ask)
        XCTAssertTrue(state.analysisScheduleRefreshOnAppear)
        changes.cancel()

        let second = try await action.prepareConfirmation(parameters: parameters, context: context)
        var task: Task<Void, Never>?
        var started = false
        let voiceChange = state.objectWillChange.sink {
            guard !started else { return }
            started = true
            task = voice.start(localeIdentifier: "en")
            voice.stop()
        }
        let voiceResult = try await action.executeConfirmed(parameters: parameters, context: context, snapshot: second.snapshot)
        XCTAssertFalse(voiceResult.success)
        XCTAssertEqual(state.analysisSection, .ask)
        XCTAssertTrue(state.analysisScheduleRefreshOnAppear)
        await task?.value
        withExtendedLifetime(voiceChange) {}
    }

    func testVerificationRejectsSectionABAAfterSuccessfulCommit() async throws {
        let bridge = ACTACanvasFilterBridge(), state = ACTACanvasFilterState()
        bridge.attach(state)
        let action = ACTAAnalysisSetSectionAction(bridge: bridge), context = ACTAActionContext()
        let result = try await action.execute(parameters: ["section": "alerts"], context: context)
        XCTAssertTrue(result.success)
        state.selectAnalysisSectionFromGUI(.schedule)
        state.selectAnalysisSectionFromGUI(.alerts)
        let verified = try await action.verify(parameters: ["section": "alerts"], context: context)
        XCTAssertFalse(verified)
    }
}

import CameraCore
import Foundation
import XCTest
@testable import CameraWall

@MainActor
final class ACTAAnalysisSectionActionTests: XCTestCase {
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
        let bridge = ACTACanvasFilterBridge()
        let voice = LocalVoiceInput(speechPermission: { false }, microphonePermission: { false },
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
}

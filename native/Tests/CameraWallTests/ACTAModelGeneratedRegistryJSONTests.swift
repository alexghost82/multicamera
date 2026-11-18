import CameraCore
import Foundation
import XCTest
@testable import CameraWall

private actor ModelJSONMutationProbe {
    private(set) var count = 0
    func record() { count += 1 }
}

private struct ModelJSONProtectedAction: ACTAActionProtocol {
    var id = "settings.update_permissions"
    let title = "Protected test action"
    let description = "Test action"
    let classification = ACTAActionClassification.securitySensitive
    let parameters = [ACTAActionParameterSchema(name: "value", type: "integer",
                                                 description: "Integer", isRequired: true)]
    let probe: ModelJSONMutationProbe

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        await probe.record()
        return ACTAActionResult(actionID: id, success: true, summary: "executed")
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

final class ACTAModelGeneratedRegistryJSONTests: XCTestCase {
    func testRequestCatalogueEnforcedForModelAndDirectCalls() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".acta-catalogue-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(
            aiClient: ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }), trackingStore: store)
        let registry = ACTAActionRegistry()
        let allowedProbe = ModelJSONMutationProbe()
        let deniedProbe = ModelJSONMutationProbe()
        await registry.register(ModelJSONProtectedAction(probe: allowedProbe))
        await registry.register(ModelJSONProtectedAction(id: "test.unlisted", probe: deniedProbe))
        let tools = try await ACTAAnalyticsCoordinator.registryTools(registry: registry)
        let advertised = Set(tools.map(\.name))
        XCTAssertTrue(advertised.contains("acta__settings__update_permissions"))
        XCTAssertFalse(advertised.contains("acta__test__unlisted"))

        for name in ["acta__test__unlisted", "settings.update_permissions", "acta__settings.update_permissions"] {
            let call = ACTAAgentFunctionCall(callID: name, name: name, argumentsJSON: #"{"value":1}"#)
            // Even a forged request catalogue cannot make an unadvertised spelling valid.
            let result = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
                requestToolNames: advertised.union([name]), registry: registry)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.outputJSON.utf8)) as? [String: Any])
            XCTAssertTrue((json["error"] as? String)?.hasPrefix("TOOL_NOT_ADVERTISED:") == true, name)
        }
        let allowed = ACTAAgentFunctionCall(callID: "allowed", name: "acta__settings__update_permissions",
                                             argumentsJSON: #"{"value":1}"#)
        let absent = await coordinator.executeModelGeneratedAgentTool(allowed, threadID: "test",
            requestToolNames: [], registry: registry)
        XCTAssertTrue(absent.outputJSON.contains("TOOL_NOT_ADVERTISED:"))
        let legacy = ACTAAgentFunctionCall(callID: "legacy", name: "live_look", argumentsJSON: "{}")
        let absentLegacy = await coordinator.executeModelGeneratedAgentTool(legacy, threadID: "test",
            requestToolNames: advertised, registry: registry)
        XCTAssertTrue(absentLegacy.outputJSON.contains("TOOL_NOT_ADVERTISED:"))
        let directDenied = await coordinator.executeAgentTool(toolName: "test.unlisted",
            arguments: ["value": "1"], threadID: "test", registry: registry)
        XCTAssertTrue(directDenied.outputJSON.contains("TOOL_NOT_ADVERTISED:"))
        let deniedCount = await deniedProbe.count
        XCTAssertEqual(deniedCount, 0)
        let rejected = try store.executeReadOnlyACTASQL(
            "SELECT COUNT(*) AS n FROM ghost_chat_tool_calls WHERE error LIKE 'TOOL_NOT_ADVERTISED:%' AND ok = 0 AND args_json = '{}'"
        )
        XCTAssertEqual(rejected.first?["n"], "6")

        let modelResult = await coordinator.executeModelGeneratedAgentTool(allowed, threadID: "test",
            requestToolNames: advertised, registry: registry)
        let modelJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(modelResult.outputJSON.utf8)) as? [String: Any])
        XCTAssertEqual(modelJSON["requires_operator_confirmation"] as? Bool, true)
        let directAllowed = await coordinator.executeAgentTool(toolName: "settings.update_permissions",
            arguments: ["value": "1"], threadID: "test", registry: registry)
        XCTAssertTrue(directAllowed.outputJSON.contains("confirmation_required"))
        let beforeApproval = await allowedProbe.count
        XCTAssertEqual(beforeApproval, 0)
        let proposal = try XCTUnwrap(store.listACTAChatActions(threadID: "test").first)
        let approved = try await registry.confirmAndExecute(token: proposal.actionID, confirmed: true,
            expectedActionID: proposal.actionType, expectedParameters: proposal.parameters, expectedThreadID: "test")
        XCTAssertTrue(approved.success)
        let afterApproval = await allowedProbe.count
        XCTAssertEqual(afterApproval, 1)
    }

    func testCoordinatorAndLegacyReviewCannotUseAuthorizedRegistryWithoutBroker() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(".acta-broker-tests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        let coordinator = ACTAAnalyticsCoordinator(
            aiClient: ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
                XCTFail("Unexpected network request")
                throw URLError(.notConnectedToInternet)
            }), trackingStore: store)
        let (registry, authority) = ACTAActionRegistry.makeAuthorized()
        let probe = ModelJSONMutationProbe()
        let registered = await registry.register(ModelJSONProtectedAction(probe: probe), authority: authority)
        XCTAssertTrue(registered)
        let issuedRequester = await registry.issuePrincipal(authority: authority,
            actionIDs: ["settings.update_permissions"], canRequest: true, canReview: false)
        let issuedReviewer = await registry.issuePrincipal(authority: authority,
            actionIDs: ["settings.update_permissions"], canRequest: false, canReview: true)
        let requester = try XCTUnwrap(issuedRequester)
        let reviewer = try XCTUnwrap(issuedReviewer)

        let call = ACTAAgentFunctionCall(callID: "untrusted", name: "acta__settings__update_permissions",
                                         argumentsJSON: #"{"value":1}"#)
        let output = await coordinator.executeModelGeneratedAgentTool(call, threadID: "thread",
            requestToolNames: [call.name], registry: registry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.outputJSON.utf8)) as? [String: Any])
        XCTAssertTrue((json["error"] as? String)?.hasPrefix("TOOL_NOT_ADVERTISED:") == true)
        XCTAssertNil(json["confirmation_token"])
        XCTAssertTrue(try store.listACTAChatActions(threadID: "thread").isEmpty)

        let pending = try await registry.execute(actionID: "settings.update_permissions", parameters: ["value": "1"],
            context: ACTAActionContext(threadID: "thread"), principal: requester)
        let token = try XCTUnwrap(pending.confirmationToken)
        let legacyReview = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: "settings.update_permissions", expectedParameters: ["value": "1"],
            expectedThreadID: "thread", expectedReviewTitle: pending.summary)
        XCTAssertTrue(legacyReview.error?.hasPrefix("AUTHORIZATION_DENIED:") == true)
        let beforeApproval = await probe.count
        XCTAssertEqual(beforeApproval, 0)
        let approved = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: "settings.update_permissions", expectedParameters: ["value": "1"],
            expectedThreadID: "thread", expectedReviewTitle: pending.summary, principal: reviewer)
        XCTAssertTrue(approved.success)
        let afterApproval = await probe.count
        XCTAssertEqual(afterApproval, 1)
    }

    func testInvalidCallsAreAuditedWithoutArgumentsAndNeverMutate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try LocalTrackingStore(url: root.appendingPathComponent("tracking.sqlite"))
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client, trackingStore: store)
        let registry = ACTAActionRegistry()
        let probe = ModelJSONMutationProbe()
        await registry.register(ModelJSONProtectedAction(probe: probe))
        let thread = UUID().uuidString

        for raw in ["", #"{"value":true}"#, #"{"value":null}"#, #"{"value":1.0000000000000001}"#,
                    #"{"value":1,"unexpected":1}"#, #"{"value": "#] {
            let call = ACTAAgentFunctionCall(callID: UUID().uuidString, name: "acta__settings__update_permissions",
                                             argumentsJSON: raw)
            let output = await coordinator.executeModelGeneratedAgentTool(call, threadID: thread,
                requestToolNames: [call.name], registry: registry)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.outputJSON.utf8)) as? [String: Any])
            XCTAssertTrue((json["error"] as? String)?.hasPrefix("INVALID_ARGUMENT:") == true, raw)
            XCTAssertNil(json["confirmation_token"])
            XCTAssertEqual(output.resultRows, 0)
        }
        let local = ACTAAIClient.parseLocalAgentReply(
            #"{"tool_calls":[{"name":"acta__settings__update_permissions","arguments":{"value":1.0000000000000001}}]}"#
        ).calls
        let localCall = try XCTUnwrap(local.first)
        let localOutput = await coordinator.executeModelGeneratedAgentTool(localCall, threadID: thread,
            requestToolNames: [localCall.name], registry: registry)
        let localJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(localOutput.outputJSON.utf8)) as? [String: Any])
        XCTAssertTrue((localJSON["error"] as? String)?.hasPrefix("INVALID_ARGUMENT:") == true)
        XCTAssertTrue(try store.listACTAChatActions(threadID: thread).isEmpty)
        let audit = try store.executeReadOnlyACTASQL("SELECT COUNT(*) AS n FROM ghost_chat_tool_calls")
        XCTAssertEqual(audit.first?["n"], "7")
        let leakedArguments = try store.executeReadOnlyACTASQL(
            "SELECT COUNT(*) AS n FROM ghost_chat_tool_calls WHERE args_json != '{}'"
        )
        XCTAssertEqual(leakedArguments.first?["n"], "0")
        let executions = await probe.count
        XCTAssertEqual(executions, 0)

        let valid = ACTAAgentFunctionCall(callID: "valid", name: "acta__settings__update_permissions",
                                          argumentsJSON: #"{"value":1.0}"#)
        let output = await coordinator.executeModelGeneratedAgentTool(valid, threadID: thread,
            requestToolNames: [valid.name], registry: registry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.outputJSON.utf8)) as? [String: Any])
        let token = try XCTUnwrap(json["confirmation_token"] as? String)
        let action = try XCTUnwrap(store.listACTAChatActions(threadID: thread).first)
        XCTAssertEqual(action.parameters["value"], "1")
        let approved = try await registry.confirmAndExecute(token: token, confirmed: true,
            expectedActionID: action.actionType, expectedParameters: action.parameters, expectedThreadID: thread)
        XCTAssertTrue(approved.success)
        let finalExecutions = await probe.count
        XCTAssertEqual(finalExecutions, 1)
    }

    func testEmptyAndInvalidRawArgumentsSurviveParsingWithoutChangingLegacyArguments() throws {
        let empty = ACTAAgentFunctionCall(callID: "empty", name: "acta__test__model_json", argumentsJSON: "")
        XCTAssertEqual(empty.argumentsJSON, "{}")
        XCTAssertEqual(empty.rawArgumentsJSON, "")
        XCTAssertTrue(empty.arguments.isEmpty)

        let root: [String: Any] = ["output": [
            ["type": "function_call", "name": "acta__test__model_json", "call_id": "one", "arguments": ""],
            ["type": "function_call", "name": "acta__test__model_json", "call_id": "two"]
        ]]
        let calls = ACTAAIClient.parseResponsesOutput(root).calls
        XCTAssertEqual(calls.count, 2)
        XCTAssertTrue(calls.allSatisfy { $0.argumentsJSON == "{}" && $0.rawArgumentsJSON.isEmpty })

        let local = ACTAAIClient.parseLocalAgentReply(#"{"tool_calls":[{"name":"acta__test__model_json","arguments":null}]}"#).calls
        XCTAssertEqual(local.first?.argumentsJSON, "{}")
        XCTAssertEqual(local.first?.rawArgumentsJSON, "null")

        let precise = ACTAAIClient.parseLocalAgentReply(
            #"{"tool_calls":[{"name":"acta__test__model_json","arguments":{"value":1.0000000000000001}},{"name":"acta__test__model_json","arguments":""}]}"#
        ).calls
        XCTAssertEqual(precise.first?.rawArgumentsJSON, #"{"value":1.0000000000000001}"#)
        XCTAssertEqual(precise.last?.rawArgumentsJSON, "")
        let missing = ACTAAIClient.parseLocalAgentReply(
            #"{"tool_calls":[{"name":"acta__test__model_json"}]}"#
        ).calls
        XCTAssertEqual(missing.first?.argumentsJSON, "{}")
        XCTAssertEqual(missing.first?.rawArgumentsJSON, "")
    }

    func testRejectedCallReportsUnavailableAuditStore() async throws {
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client)
        let registry = ACTAActionRegistry()
        await registry.register(ModelJSONProtectedAction(probe: ModelJSONMutationProbe()))
        let call = ACTAAgentFunctionCall(callID: "invalid", name: "acta__settings__update_permissions",
                                         argumentsJSON: #"{"value":true}"#)
        let output = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [call.name], registry: registry)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(output.outputJSON.utf8)) as? [String: Any])
        XCTAssertTrue((json["error"] as? String)?.hasPrefix("AUDIT_FAILED:") == true)
        XCTAssertNil(json["confirmation_token"])
    }

    func testLegacyToolStillUsesFlattenedArguments() async throws {
        let client = ACTAAIClient(config: ACTAAIConfiguration(mode: .dryRun), transport: { _ in
            throw URLError(.notConnectedToInternet)
        })
        let coordinator = ACTAAnalyticsCoordinator(aiClient: client)
        let now = Date(timeIntervalSince1970: 1_000)
        let call = ACTAAgentFunctionCall(callID: "legacy", name: "live_look", argumentsJSON: "")
        let fromModel = await coordinator.executeModelGeneratedAgentTool(call, threadID: "test",
            requestToolNames: [call.name], now: now)
        let direct = await coordinator.executeAgentTool(toolName: "live_look", arguments: [:], threadID: "test", now: now)
        let modelJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(fromModel.outputJSON.utf8)) as? NSDictionary)
        let directJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(direct.outputJSON.utf8)) as? NSDictionary)
        XCTAssertEqual(modelJSON, directJSON)
    }
}

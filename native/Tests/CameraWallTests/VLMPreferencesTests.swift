    func testAlertConfidenceIsOptionalForAlertsButRequiredForLookbackClips() throws {
        let legacy = #"{"answer":"Visible red coat.","matched_alerts":[{"condition":"Red coat","evidence":"Red coat visible"}]}"#
        let oldReply = try XCTUnwrap(VLMResponseValidator.decode(legacy, expectedLanguage: "Red coat"))
        XCTAssertFalse(oldReply.matchedAlerts[0].qualifiesForLookbackClip)
        let qualified = #"{"answer":"Visible red coat.","matched_alerts":[{"condition":"Red coat","evidence":"Red coat visible","confidence":0.55}]}"#
        XCTAssertTrue(try XCTUnwrap(VLMResponseValidator.decode(qualified, expectedLanguage: "Red coat")).matchedAlerts[0].qualifiesForLookbackClip)
        for value in ["-0.1", "1.1", "\"high\""] {
            let response = """
            {"answer":"Visible red coat.","matched_alerts":[{"condition":"Red coat","evidence":"Visible","confidence":\(value)}]}
            """
            XCTAssertNil(VLMResponseValidator.decode(response, expectedLanguage: "Red coat"))
        }
    }

import Foundation
import XCTest
@testable import CameraWall

final class VLMPreferencesTests: XCTestCase {
    func testManualQuestionQueueNeverOverwritesAnAcceptedQuestion() throws {
        var queue = VLMManualQuestionQueue()
        let cameraID = UUID()
        XCTAssertFalse(queue.enqueue(question: " ", cameraIDs: [cameraID]))
        XCTAssertFalse(queue.enqueue(question: "Question", cameraIDs: []))
        XCTAssertFalse(queue.enqueue(question: String(repeating: "a", count: 2001), cameraIDs: [cameraID]))
        XCTAssertTrue(queue.enqueue(question: "  First question  ", cameraIDs: [cameraID]))
        XCTAssertFalse(queue.enqueue(question: "Second question", cameraIDs: [cameraID]))
        XCTAssertEqual(queue.take(), VLMManualQuestionQueue.Request(question: "First question", cameraIDs: [cameraID]))
        XCTAssertNil(queue.take())
        XCTAssertTrue(queue.enqueue(question: "Second question", cameraIDs: [cameraID]))
    }

    func testAutomaticScanAnswersNeverEnterGeneralChat() {
        var messages: [VLMChatMessage] = []
        VLMChatDelivery.appendAnswer("Automatic scene summary", cameraNames: ["Synthetic camera"], scheduled: true, to: &messages)
        XCTAssertTrue(messages.isEmpty)
        VLMChatDelivery.appendAnswer("Manual answer", cameraNames: ["Synthetic camera"], scheduled: false, to: &messages)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?.text, "Manual answer")
    }

    func testShortRussianAnswerAndSentenceAreNotRejectedAsBulgarian() throws {
        for question in ["Оцени обстановку", "Что происходит на этой камере?"] {
            for answer in ["Обстановка спокойна.", "На изображении виден пустой коридор. Обстановка спокойна."] {
                XCTAssertNoThrow(try VLMResponseValidator.parse(responseJSON(answer), expectedLanguage: question))
            }
            for bulgarian in ["Няма хора.", "Всичко е спокойно.", "В кадъра няма хора.", "Обстановката изглежда спокойна и нормална."] {
                XCTAssertThrowsError(try VLMResponseValidator.parse(responseJSON(bulgarian), expectedLanguage: question), bulgarian)
            }
        }
    }

    func testBundleLanguageSelfCheckPassesAndReportsThreeLanguages() throws {
        let data = try VLMResponseLanguage.selfCheck()
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let checks = try XCTUnwrap(report["checks"] as? [[String: String]])
        XCTAssertEqual(checks.compactMap { $0["language"] }, ["ru", "he", "en"])
        XCTAssertTrue(checks.allSatisfy { $0["result"] == "passed" })
    }

    func testFailureReasonsAreSpecificAndUseTheQuestionLanguage() throws {
        for question in ["Оцени обстановку", "מה רואים בתמונה?", "What is visible?"] {
            let errors: [LocalVLMError] = [.unexpectedResponseLanguage, .invalidResponseCharacters, .emptyResponse, .invalidStructuredResponse]
            let messages = errors.map { VLMResponseLanguage.failureMessage(for: question, error: $0) }
            XCTAssertEqual(Set(messages).count, errors.count)
            for message in messages { try VLMResponseLanguage.validate(message, expectedLanguage: question) }
        }
    }

    func testReportedShortRussianQuestionUsesRussianAcrossTheRequest() async throws {
        let question = "Оцени обстановку"
        XCTAssertEqual(try VLMResponseLanguage.requiredCode(for: question), "ru")
        XCTAssertEqual(VLMResponseLanguage.label(for: question), "Russian (ru)")
        XCTAssertTrue(VLMResponseLanguage.instruction(for: question).contains("только на русском языке"))
        XCTAssertTrue(VLMResponseLanguage.failureMessage(for: question).hasPrefix("Не удалось"))
        var calls = 0
        let reply = try await VLMResponseValidator.generateReply(expectedLanguage: question) { _ in
            calls += 1
            return try self.responseJSON("На изображении виден пустой коридор. Людей в кадре нет.")
        }
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(reply.answer, "На изображении виден пустой коридор. Людей в кадре нет.")
        let bulgarian = "Обстановката изглежда спокойна и нормална. Не се виждат хора в кадъра."
        XCTAssertThrowsError(try VLMResponseValidator.parse(responseJSON(bulgarian), expectedLanguage: question))
    }

    @MainActor
    func testReportedShortQuestionPromptDoesNotRequestBulgarian() {
        let prompt = WallModel.vlmPrompt(question: "Оцени обстановку", rules: [])
        XCTAssertTrue(prompt.contains("REQUIRED RESPONSE LANGUAGE: Russian (ru)"))
        XCTAssertFalse(prompt.contains("Bulgarian"))
    }

    func testInvalidGenerationRetriesOnceWithExplicitCorrection() async throws {
        var calls = 0
        let reply = try await VLMResponseValidator.generateReply(expectedLanguage: "Что происходит на этой камере?") { correction in
            calls += 1
            if calls == 1 {
                XCTAssertTrue(correction.isEmpty)
                return try self.responseJSON("The image shows an empty hallway.")
            }
            XCTAssertTrue(correction.contains("только на русском языке"))
            return try self.responseJSON("На изображении виден пустой коридор.")
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(reply.answer, "На изображении виден пустой коридор.")
    }

    func testPersistentInvalidGenerationIsNeverReturnedAndRetriesAreBounded() async {
        var calls = 0
        do {
            _ = try await VLMResponseValidator.generateReply(expectedLanguage: "מה רואים בתמונה?") { _ in
                calls += 1
                return try self.responseJSON("The image shows an empty hallway.")
            }
            XCTFail("Invalid model text must not be returned")
        } catch {
            XCTAssertEqual(calls, 2)
        }
    }

    func testCancellationAndMissingModelAreNotRetried() async {
        for missingModel in [false, true] {
            var calls = 0
            do {
                _ = try await VLMResponseValidator.generateReply(expectedLanguage: "What is visible?") { _ in
                    calls += 1
                    if missingModel { throw LocalVLMError.modelNotFound("synthetic-model") }
                    throw CancellationError()
                }
                XCTFail("Expected generation failure")
            } catch {
                XCTAssertEqual(calls, 1)
            }
        }
    }

    func testStrictAnswersAcceptRussianHebrewAndEnglish() throws {
        for (question, answer) in [
            ("Что происходит на этой камере?", "На изображении виден пустой коридор. Людей в кадре нет."),
            ("מה רואים בתמונה?", "בתמונה נראה מסדרון ריק. אין אנשים בתמונה."),
            ("What is happening in this camera?", "The image shows an empty hallway. No people are visible.")
        ] {
            XCTAssertNoThrow(try VLMResponseValidator.parse(responseJSON(answer), expectedLanguage: question))
        }
    }

    func testHebrewDiacriticsAndNormalPunctuationAreAllowed() throws {
        let answer = "בַּתְּמוּנָה נִרְאֶה מִסְדְּרוֹן רֵיק."
        XCTAssertNoThrow(try VLMResponseValidator.parse(responseJSON(answer), expectedLanguage: "מה רואים בתמונה?"))
    }

    func testRefusalMessagesUseTheQuestionLanguageAndContainNoModelText() throws {
        for question in ["Что происходит на этой камере?", "מה רואים בתמונה?", "What is visible?"] {
            let failure = VLMResponseLanguage.failureMessage(for: question)
            XCTAssertNoThrow(try VLMResponseLanguage.validate(failure, expectedLanguage: question))
        }
    }

    func testMixedLanguagesAndUnrelatedSymbolsAreRejected() throws {
        for answer in [
            "На изображении виден пустой коридор. The hallway is empty.",
            "На изображении виден пустой коридор. В кадъра няма хора.",
            "На изображении виден пустой коридор. שלום",
            "На изображении виден пустой коридор. \u{FFFD}",
            "На изображении виден пустой коридор. \u{1F600}",
            "На изображении виден <think>пустой коридор</think>.",
            "На изображении виден пустой\u{202E} коридор.",
            "На изображении виден пустой\u{200B} коридор."
        ] {
            XCTAssertThrowsError(try VLMResponseValidator.parse(responseJSON(answer), expectedLanguage: "Что происходит на этой камере?"), answer)
        }
        XCTAssertThrowsError(try VLMResponseValidator.parse(responseJSON("בתמונה נראה מסדרון ריק. No people are visible."), expectedLanguage: "מה רואים בתמונה?"))
        XCTAssertThrowsError(try VLMResponseValidator.parse(responseJSON("The image shows an empty hallway. אין אנשים בתמונה."), expectedLanguage: "What is visible?"))
    }

    func testUnknownQuestionLanguageCannotDisableValidation() throws {
        XCTAssertThrowsError(try VLMResponseValidator.parse(responseJSON("The image shows an empty hallway."), expectedLanguage: "12345 ???"))
    }

    func testAlertEvidenceMustUseTheRequiredLanguage() throws {
        let response = try JSONSerialization.data(withJSONObject: [
            "answer": "На изображении виден человек у двери.",
            "matched_alerts": [["condition": "Человек у двери", "evidence": "A person is visible by the door.", "confidence": 0.8]]
        ])
        XCTAssertThrowsError(try VLMResponseValidator.parse(String(decoding: response, as: UTF8.self), expectedLanguage: "Что происходит на этой камере?", requiresAlertMatches: true))
    }

    @MainActor
    func testPromptExplicitlyRequiresEachSupportedLanguageAndNoSpeculation() {
        for (question, instruction) in [
            ("Что происходит на этой камере?", "только на русском языке"),
            ("מה רואים בתמונה?", "ענה בעברית בלבד"),
            ("What is visible?", "English only")
        ] {
            let prompt = WallModel.vlmPrompt(question: question, rules: [])
            XCTAssertTrue(prompt.contains(instruction), prompt)
            XCTAssertTrue(prompt.contains("Do not speculate"))
        }
    }

    private func responseJSON(_ answer: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["answer": answer, "matched_alerts": []])
        return String(decoding: data, as: UTF8.self)
    }

    func testQwenThinkingAndMarkdownWrappersPreserveStructuredAnswer() throws {
        let json = #"{"answer":"A man is sitting at a desk.","matched_alerts":[]}"#
        for response in [json, "```json\n\(json)\n```", "<think>Internal reasoning</think>\n```json\n\(json)\n```", "</think>\n\(json)"] {
            let reply = try VLMResponseValidator.parse(response, expectedLanguage: "What is happening in this camera?")
            XCTAssertEqual(reply.answer, "A man is sitting at a desk.")
            XCTAssertTrue(reply.matchedAlerts.isEmpty)
        }
    }

    func testIncompleteOrUnstructuredResponseIsRejectedWithFormatError() {
        for response in ["<think>Unfinished reasoning", "```", #"{"answer":"Incomplete""#, #"{"answer":"Invalid alerts","matched_alerts":"none"}"#, #"{"answer":"Invalid alerts","matched_alerts":null}"#, #"{"answer":" ","matched_alerts":[]}"#, "Unstructured scene description"] {
            XCTAssertThrowsError(try VLMResponseValidator.parse(response, expectedLanguage: "Describe the camera")) { error in
                guard case LocalVLMError.invalidStructuredResponse = error else {
                    return XCTFail("Expected a structured response error, got \(error)")
                }
            }
        }
    }

    func testAnswerOnlyJSONIsSafeForChatButNotForAlertChecks() throws {
        let response = #"{"answer":"The image is completely blank and contains no visible content."}"#
        let reply = try VLMResponseValidator.parse(response, expectedLanguage: "Describe the image.")
        XCTAssertTrue(reply.matchedAlerts.isEmpty)
        XCTAssertFalse(reply.hasExplicitAlertMatches)
        XCTAssertThrowsError(try VLMResponseValidator.parse(response, expectedLanguage: "Describe the image.", requiresAlertMatches: true))
        let complete = #"{"answer":"The image is completely blank and contains no visible content.","matched_alerts":[]}"#
        XCTAssertTrue(try VLMResponseValidator.parse(complete, expectedLanguage: "Describe the image.", requiresAlertMatches: true).matchedAlerts.isEmpty)
    }

    func testWrongLanguageHasDistinctError() {
        let reply = #"{"answer":"A man is sitting at a desk.","matched_alerts":[]}"#
        XCTAssertThrowsError(try VLMResponseValidator.parse(reply, expectedLanguage: "Что происходит на этой камере?")) { error in
            guard case LocalVLMError.unexpectedResponseLanguage = error else {
                return XCTFail("Expected a language error, got \(error)")
            }
        }
    }

    func testReportedBulgarianSceneAnswerIsRejectedForRussianQuestion() throws {
        let answer = "Обстановката изглежда спокойна и нормална. В кадъра се вижда външен коридор на сграда с голямо стъклено врато и стени. На пода има няколко мокри петна, а до стената са събрани различни материали, включително дървена кутия, черна решетка и други предмети. Не се виждат хора или активност, която да изисква внимание."
        let question = "Что происходит на этой камере?"
        XCTAssertEqual(VLMResponseLanguage.code(for: answer), "bg")
        XCTAssertEqual(VLMResponseLanguage.code(for: question), "ru")
        let data = try JSONSerialization.data(withJSONObject: ["answer": answer, "matched_alerts": []])
        let response = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertThrowsError(try VLMResponseValidator.parse(response, expectedLanguage: question)) { error in
            guard case LocalVLMError.unexpectedResponseLanguage = error else {
                return XCTFail("Expected the reported Bulgarian answer to be rejected, got \(error)")
            }
        }
    }

    func testWatchAlertPersistsRuleAndPerCameraTrackProvenance() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("alerts.json")
        let alert = VLMAlert(
            cameraID: UUID(), cameraName: "North", condition: "Red coat", evidence: "Red coat visible",
            watchID: UUID(), sourceTrackID: UUID(), clipID: UUID()
        )
        try VLMStore.save([alert], to: url)
        XCTAssertEqual(try VLMStore.loadAlerts(from: url), [alert])
    }

    func testLegacyRulesAndAlertsDefaultToNormalPriority() throws {
        let rule = VLMAlertRule(condition: "Door is open", priority: .critical)
        var ruleJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(rule)) as? [String: Any])
        ruleJSON.removeValue(forKey: "priority")
        let legacyRule = try JSONDecoder().decode(VLMAlertRule.self, from: JSONSerialization.data(withJSONObject: ruleJSON))
        XCTAssertEqual(legacyRule.priority, .normal)
        XCTAssertEqual(legacyRule.id, rule.id)
        let alert = VLMAlert(cameraID: UUID(), cameraName: "Door", condition: "Door is open", evidence: "Visible open door", priority: .critical)
        var alertJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(alert)) as? [String: Any])
        alertJSON.removeValue(forKey: "priority")
        let legacyAlert = try JSONDecoder().decode(VLMAlert.self, from: JSONSerialization.data(withJSONObject: alertJSON))
        XCTAssertEqual(legacyAlert.priority, .normal)
        XCTAssertEqual(legacyAlert.id, alert.id)
    }

    func testResponseLanguageMatchesOperatorQuestion() {
        XCTAssertEqual(VLMResponseLanguage.label(for: "Что происходит на этой камере?"), "Russian (ru)")
        XCTAssertEqual(VLMResponseLanguage.label(for: "What is happening in this camera?"), "English (en)")
    }

    func testVLMReplyMustBeValidJSONAndMatchQuestionLanguage() {
        let russianQuestion = "Что происходит на этой камере?"
        let russianReply = #"{"answer":"На изображении виден проход рядом со зданием.","matched_alerts":[]}"#
        let englishReply = #"{"answer":"A man is sitting at a desk.","matched_alerts":[]}"#
        let shortEnglishReply = #"{"answer":"A person is here.","matched_alerts":[]}"#

        XCTAssertNotNil(VLMResponseValidator.decode(russianReply, expectedLanguage: russianQuestion))
        XCTAssertNil(VLMResponseValidator.decode(englishReply, expectedLanguage: russianQuestion))
        XCTAssertNil(VLMResponseValidator.decode(shortEnglishReply, expectedLanguage: russianQuestion))
        XCTAssertNil(VLMResponseValidator.decode("Two unrelated scene descriptions", expectedLanguage: russianQuestion))
    }

    func testPreferencesRoundTripAndPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("vlm.json")
        var preferences = VLMPreferences()
        preferences.scheduleEnabled = true
        preferences.analyzeAllEnabledCameras = false
        let cameraID = UUID()
        preferences.scheduledCameraIDs = [cameraID]
        preferences.alertRules = [VLMAlertRule(condition: "A person enters the marked zone", priority: .critical)]

        try VLMStore.save(preferences, to: url)

        XCTAssertEqual(try VLMStore.loadPreferences(from: url), preferences)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testRejectsEmptyNativeModelPath() {
        var preferences = VLMPreferences()
        preferences.model = "   "
        XCTAssertThrowsError(try preferences.validate())
    }

    func testDefaultsKeepScheduledAnalysisOffAndUseSelectedCheckpoint() {
        let preferences = VLMPreferences()
        XCTAssertFalse(preferences.scheduleEnabled)
        XCTAssertTrue(preferences.analyzeAllEnabledCameras)
        XCTAssertEqual(preferences.intervalSeconds, 15)
        XCTAssertTrue(preferences.model.hasSuffix(".build/models/qwen3.5-9b"))
    }

    func testAnalysisScheduleUsesPerCameraIntervalsAndRoundRobinOrder() {
        var schedule = VLMAnalysisSchedule()
        let first = UUID()
        let second = UUID()
        let cameras = [first, second]

        XCTAssertEqual(schedule.nextCamera(in: cameras, now: 20, intervalSeconds: 15) { _ in true }, first)
        schedule.markSubmitted(cameraID: first, in: cameras, at: 20)
        XCTAssertEqual(schedule.nextCamera(in: cameras, now: 21, intervalSeconds: 15) { _ in true }, second)
        schedule.markSubmitted(cameraID: second, in: cameras, at: 21)
        XCTAssertNil(schedule.nextCamera(in: cameras, now: 34.99, intervalSeconds: 15) { _ in true })
        XCTAssertEqual(schedule.nextCamera(in: cameras, now: 35, intervalSeconds: 15) { _ in true }, first)
    }

    func testAnalysisScheduleDoesNotConsumeIntervalUntilSubmission() {
        var schedule = VLMAnalysisSchedule()
        let cameraID = UUID()
        let cameras = [cameraID]

        XCTAssertEqual(schedule.nextCamera(in: cameras, now: 20, intervalSeconds: 15) { _ in true }, cameraID)
        XCTAssertEqual(schedule.nextCamera(in: cameras, now: 20, intervalSeconds: 15) { _ in true }, cameraID)
        schedule.markSubmitted(cameraID: cameraID, in: cameras, at: 20)
        XCTAssertNil(schedule.nextCamera(in: cameras, now: 34.99, intervalSeconds: 15) { _ in true })
        XCTAssertEqual(schedule.nextCamera(in: cameras, now: 35, intervalSeconds: 15) { _ in true }, cameraID)
    }
}

import XCTest
import PDFKit
import ImageIO
import UniformTypeIdentifiers
@testable import CameraWall

final class CameraMissionTests: XCTestCase {
    func testMissionConsultDoesNotCommitAfterClearDisableDeletionOrCancellation() {
        XCTAssertTrue(CameraMissionConsultLifecycle.canCommit(
            featureEnabled: true, generationMatches: true, missionStillExists: true,
            questionStillPresent: true, taskCancelled: false
        ))
        XCTAssertFalse(CameraMissionConsultLifecycle.canCommit(
            featureEnabled: false, generationMatches: true, missionStillExists: true,
            questionStillPresent: true, taskCancelled: false
        ))
        XCTAssertFalse(CameraMissionConsultLifecycle.canCommit(
            featureEnabled: true, generationMatches: true, missionStillExists: false,
            questionStillPresent: true, taskCancelled: false
        ))
        XCTAssertFalse(CameraMissionConsultLifecycle.canCommit(
            featureEnabled: true, generationMatches: true, missionStillExists: true,
            questionStillPresent: false, taskCancelled: false
        ))
        XCTAssertFalse(CameraMissionConsultLifecycle.canCommit(
            featureEnabled: true, generationMatches: false, missionStillExists: true,
            questionStillPresent: true, taskCancelled: true
        ))
    }

    func testMissionConsultResponseIsNonemptyAndBounded() throws {
        XCTAssertEqual(try CameraMissionConsultResponse.shorten(" One vehicle entered.   It stopped. "), "One vehicle entered. It stopped.")
        let manySentences = (1...8).map { "Finding \($0)." }.joined(separator: " ")
        XCTAssertEqual(try CameraMissionConsultResponse.shorten(manySentences).components(separatedBy: ". ").count, 4)
        let long = try CameraMissionConsultResponse.shorten(String(repeating: "evidence ", count: 100))
        XCTAssertLessThanOrEqual(long.count, CameraMissionConsultResponse.maximumCharacters)
        XCTAssertThrowsError(try CameraMissionConsultResponse.shorten(" \n "))
    }

    func testMissionConsultThreadPersistsAcrossRunAppendAndLegacyMigration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missions.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let mission = try CameraMission(
            cameraID: UUID(), name: "North entrance", brief: "Describe visible activity",
            intervalSeconds: 3600, createdAt: now, scheduleReferenceDate: now
        )
        try Data(#"{"schemaVersion":2,"missions":[],"runs":[]}"#.utf8).write(to: url)
        let legacy = try CameraMissionStore.loadDocument(from: url)
        XCTAssertTrue(legacy.consults.isEmpty)
        let operatorMessage = try CameraMissionConsultMessage(missionID: mission.id, role: .operatorMessage, text: "Was the vehicle present?", createdAt: now)
        let assistantMessage = try CameraMissionConsultMessage(missionID: mission.id, role: .assistant, text: "One vehicle is in the saved run summary.", createdAt: now.addingTimeInterval(1))
        let consults = try CameraMissionStore.appendConsult(
            operatorMessage, missions: [mission], runs: [], existingConsults: [], to: url
        )
        _ = try CameraMissionStore.appendConsult(
            assistantMessage, missions: [mission], runs: [], existingConsults: consults, to: url
        )
        let run = CameraMissionRun(missionID: mission.id, cameraID: mission.cameraID, missionName: mission.name,
                                   status: .completed, occurredAt: now, summary: "One vehicle entered.")
        _ = try CameraMissionStore.appendRun(run, missions: [mission], existingRuns: [], to: url)
        let document = try CameraMissionStore.loadDocument(from: url)
        XCTAssertEqual(document.schemaVersion, 3)
        XCTAssertEqual(document.consults, [operatorMessage, assistantMessage])
        XCTAssertEqual(document.runs, [run])
    }

    func testMissionConsultPromptUsesOnlyBoundedLocalSummaries() throws {
        let mission = try CameraMission(cameraID: UUID(), name: "Loading bay", brief: "Inspect vehicles", intervalSeconds: 3600)
        let run = CameraMissionRun(missionID: mission.id, cameraID: mission.cameraID, missionName: mission.name,
                                   status: .completed, summary: "A blue truck entered.")
        let message = try CameraMissionConsultMessage(missionID: mission.id, role: .assistant, text: "Blue truck seen.")
        let prompt = try CameraMissionConsultPrompt.make(question: "When did it enter?", mission: mission, runs: [run], priorMessages: [message])
        XCTAssertTrue(prompt.contains("A blue truck entered."))
        XCTAssertTrue(prompt.contains("Blue truck seen."))
        XCTAssertTrue(prompt.contains("no tools"))
        XCTAssertThrowsError(try CameraMissionConsultPrompt.make(
            question: "Question", mission: mission, runs: [run],
            priorMessages: [try CameraMissionConsultMessage(missionID: UUID(), role: .assistant, text: "Unrelated")]
        ))
        XCTAssertThrowsError(try CameraMissionConsultMessage(missionID: mission.id, role: .operatorMessage, text: String(repeating: "x", count: 4001)))
    }

    func testMissionCollagePreservesChronologicalNumberedGridWithinBounds() throws {
        func image(gray: CGFloat) throws -> Data {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 80, height: 45, bitsPerComponent: 8, bytesPerRow: 80 * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.setFillColor(CGColor(gray: gray, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 45))
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let images = try [0.1, 0.3, 0.6, 0.9].map(image(gray:))
        for count in 1...4 {
            let collageData = try CameraMissionCollage.make(Array(images.prefix(count)))
            let source = try XCTUnwrap(CGImageSourceCreateWithData(collageData as CFData, nil))
            let collage = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
            XCTAssertEqual(collage.width, count == 1 ? 480 : 960)
            XCTAssertEqual(collage.height, count <= 2 ? 270 : 540)
            XCTAssertLessThanOrEqual(collageData.count, CameraMissionCollage.maximumImageBytes)
        }
        XCTAssertThrowsError(try CameraMissionCollage.make([]))
        XCTAssertThrowsError(try CameraMissionCollage.make([Data("not image".utf8)]))
    }

    func testSceneChangeScoreUsesDecodedPixelsAndRejectsMissingEvidence() throws {
        func image(gray: CGFloat) throws -> Data {
            let context = try XCTUnwrap(CGContext(
                data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ))
            context.setFillColor(gray: gray, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
            let data = NSMutableData()
            let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
            CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return data as Data
        }
        let dark = try image(gray: 0)
        let light = try image(gray: 1)
        XCTAssertEqual(try XCTUnwrap(CameraMissionFrameWindow.changeScore([dark, dark])), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(CameraMissionFrameWindow.changeScore([dark, light])), 1, accuracy: 0.001)
        XCTAssertNil(CameraMissionFrameWindow.changeScore([dark]))
        XCTAssertNil(CameraMissionFrameWindow.changeScore([dark, Data("not an image".utf8)]))
    }

    func testMissionAnalysisRetriesMalformedResponseThenSucceeds() async throws {
        var calls = 0
        let answer = try await CameraMissionAnalysis.answer(expectedLanguage: "Inspect the entrance") {
            calls += 1
            return calls == 1 ? "invalid" : #"{"answer":"One vehicle visible.","matched_alerts":[]}"#
        }
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(answer, "One vehicle visible.")
    }

    func testMissionAnalysisBoundsRetriesAndDoesNotRetryMissingModel() async {
        var calls = 0
        do {
            _ = try await CameraMissionAnalysis.answer(expectedLanguage: "Inspect") {
                calls += 1
                throw LocalVLMError.emptyResponse
            }
            XCTFail("Expected exhausted attempts")
        } catch { XCTAssertEqual(calls, CameraMissionAnalysis.maximumAttempts) }
        calls = 0
        do {
            _ = try await CameraMissionAnalysis.answer(expectedLanguage: "Inspect") {
                calls += 1
                throw LocalVLMError.modelNotFound("local fixture")
            }
            XCTFail("Expected missing model error")
        } catch { XCTAssertEqual(calls, 1) }
    }

    func testMissionAnalysisNeverRetriesCancellation() async {
        var calls = 0
        do {
            _ = try await CameraMissionAnalysis.answer(expectedLanguage: "Inspect") {
                calls += 1
                throw CancellationError()
            }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(calls, 1)
        } catch { XCTFail("Unexpected error: \(error)") }
    }

    func testMissionFrameWindowDeduplicatesAndCapsImages() {
        let first = Data("frame-1".utf8)
        let second = Data("frame-2".utf8)
        let third = Data("frame-3".utf8)
        let fourth = Data("frame-4".utf8)
        var images: [Data] = []
        images = CameraMissionFrameWindow.append(first, to: images)
        images = CameraMissionFrameWindow.append(first, to: images)
        images = CameraMissionFrameWindow.append(second, to: images)
        images = CameraMissionFrameWindow.append(third, to: images)
        images = CameraMissionFrameWindow.append(fourth, to: images)
        images = CameraMissionFrameWindow.append(Data("frame-5".utf8), to: images)

        XCTAssertEqual(images, [first, second, third, fourth])
    }

    func testMissionStoreRoundTripsPrivatelyAndSchedulerOrdersDueRuns() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missions.json")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let dueLater = try CameraMission(
            cameraID: UUID(), name: "Side entrance", brief: "Describe visible activity",
            intervalSeconds: 120, enabled: true, createdAt: now,
            nextRunAt: now.addingTimeInterval(30)
        )
        let dueSoon = try CameraMission(
            cameraID: UUID(), name: "Loading bay", brief: "Note visible vehicle movement",
            intervalSeconds: 60, enabled: true, createdAt: now,
            nextRunAt: now.addingTimeInterval(10)
        )
        let disabled = try CameraMission(
            cameraID: UUID(), name: "Disabled", brief: "No automatic run",
            intervalSeconds: 60, enabled: false, createdAt: now,
            nextRunAt: now.addingTimeInterval(-10)
        )
        let clockMission = try CameraMission(
            cameraID: UUID(), name: "Clock mission", brief: "Inspect at opening",
            intervalSeconds: 3600, scheduleKind: .clock, clockTimes: ["09:00"],
            weekdays: [0, 4], timeZoneIdentifier: "UTC", enabled: false,
            createdAt: now, scheduleReferenceDate: now
        )

        let run = CameraMissionRun(
            missionID: dueSoon.id,
            cameraID: dueSoon.cameraID,
            missionName: dueSoon.name,
            status: .completed,
            occurredAt: now,
            summary: "One visible vehicle entered the loading bay.",
            sceneChangeScore: 0.25
        )
        try CameraMissionStore.save([dueLater, dueSoon, disabled, clockMission], runs: [run], to: url)

        let document = try CameraMissionStore.loadDocument(from: url)
        XCTAssertEqual(document.schemaVersion, 3)
        XCTAssertEqual(document.runs, [run])
        XCTAssertEqual(document.runs.first?.sceneChangeScore, 0.25)
        let loaded = document.missions
        XCTAssertEqual(loaded, [dueLater, dueSoon, disabled, clockMission])
        XCTAssertTrue(CameraMissionScheduler.due(loaded, now: now).isEmpty)
        XCTAssertEqual(CameraMissionScheduler.due(loaded, now: now.addingTimeInterval(15)).map(\.id), [dueSoon.id])
        XCTAssertEqual(CameraMissionScheduler.due(loaded, now: now.addingTimeInterval(31)).map(\.id), [
            dueSoon.id, dueLater.id
        ])
        XCTAssertEqual(
            CameraMissionScheduler.next(loaded, now: now, forcedMissionID: dueLater.id)?.id,
            dueLater.id
        )
        XCTAssertNil(CameraMissionScheduler.next(loaded, now: now, forcedMissionID: disabled.id))
        let completed = try CameraMissionScheduler.finish(
            dueSoon,
            completedAt: now.addingTimeInterval(45),
            result: "Local summary"
        )
        XCTAssertEqual(completed.lastRunAt, now.addingTimeInterval(45))
        XCTAssertEqual(completed.nextRunAt, now.addingTimeInterval(105))
        XCTAssertEqual(completed.lastResult, "Local summary")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let edited = try CameraMission(
            id: dueSoon.id,
            cameraID: dueSoon.cameraID,
            name: dueSoon.name,
            brief: "Updated inspection brief",
            intervalSeconds: dueSoon.intervalSeconds,
            enabled: dueSoon.enabled,
            createdAt: dueSoon.createdAt,
            nextRunAt: dueSoon.nextRunAt,
            lastRunAt: dueSoon.lastRunAt,
            lastResult: dueSoon.lastResult
        )
        try CameraMissionStore.save([dueLater, edited, disabled], to: url)
        let afterEdit = try CameraMissionStore.loadDocument(from: url)
        XCTAssertEqual(afterEdit.missions.first(where: { $0.id == dueSoon.id })?.brief, "Updated inspection brief")
        XCTAssertEqual(afterEdit.runs, [run])

        let failedRun = CameraMissionRun(
            missionID: dueLater.id,
            cameraID: dueLater.cameraID,
            missionName: dueLater.name,
            status: .failed,
            occurredAt: now.addingTimeInterval(60),
            summary: "Local mission failed"
        )
        let appended = try CameraMissionStore.appendRun(
            failedRun,
            missions: afterEdit.missions,
            existingRuns: afterEdit.runs,
            to: url
        )
        XCTAssertEqual(appended, [run, failedRun])
        XCTAssertEqual(try CameraMissionStore.loadDocument(from: url).runs, [run, failedRun])
    }

    func testVersionOneMissionDocumentMigratesWithEmptyRunHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missions.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"{"schemaVersion":1,"missions":[]}"#.utf8).write(to: url)

        let legacy = try CameraMissionStore.loadDocument(from: url)
        XCTAssertEqual(legacy.schemaVersion, 1)
        XCTAssertTrue(legacy.missions.isEmpty)
        XCTAssertTrue(legacy.runs.isEmpty)

        try CameraMissionStore.save(legacy.missions, runs: legacy.runs, to: url)
        XCTAssertEqual(try CameraMissionStore.loadDocument(from: url).schemaVersion, 3)
    }

    func testVersionOneMissionEntryDefaultsToIntervalSchedule() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("missions.json")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let missionID = UUID().uuidString
        let cameraID = UUID().uuidString
        let data = Data(#"{"schemaVersion":1,"missions":[{"id":"\#(missionID)","cameraID":"\#(cameraID)","name":"Legacy","brief":"Legacy interval","intervalSeconds":3600,"enabled":false,"createdAt":"2026-03-02T08:00:00Z","nextRunAt":"2026-03-02T09:00:00Z","lastRunAt":null,"lastResult":null}]}"#.utf8)
        try data.write(to: url)

        let mission = try XCTUnwrap(CameraMissionStore.loadDocument(from: url).missions.first)

        XCTAssertEqual(mission.scheduleKind, .interval)
        XCTAssertTrue(mission.clockTimes.isEmpty)
        XCTAssertTrue(mission.weekdays.isEmpty)
    }

    func testMissionReportEscapesUntrustedTextAndContainsNoImagesOrScripts() {
        let run = CameraMissionRun(
            missionID: UUID(), cameraID: UUID(),
            missionName: #"Gate <script>alert("x")</script>"#,
            status: .completed,
            summary: #"Visible text: <img src=x onerror="run()"> & details"#
        )

        let html = CameraMissionRun.CameraMissionReport.renderHTML(runs: [run])

        XCTAssertTrue(html.contains("Gate &lt;script&gt;alert(&quot;x&quot;)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&lt;img src=x onerror=&quot;run()&quot;&gt; &amp; details"))
        XCTAssertFalse(html.contains("<script>"))
        XCTAssertFalse(html.contains("<img"))
        XCTAssertFalse(html.localizedCaseInsensitiveContains("data:image"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertTrue(html.contains("default-src 'none'; style-src 'unsafe-inline'"))
    }

    func testMissionPDFContainsLocalTextAndUsesPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("report.pdf")
        let run = CameraMissionRun(
            missionID: UUID(), cameraID: UUID(), missionName: "Entrance review",
            status: .completed, occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            summary: "One person and one vehicle were visible."
        )

        try CameraMissionRun.CameraMissionReport.renderPDF(runs: [run], to: url)

        let document = try XCTUnwrap(PDFDocument(url: url))
        XCTAssertGreaterThan(document.pageCount, 0)
        XCTAssertTrue(document.string?.contains("Entrance review") == true)
        XCTAssertTrue(document.string?.contains("One person and one vehicle") == true)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testMissionRejectsInvalidIntervalAndOversizedBrief() {
        XCTAssertThrowsError(try CameraMission(
            cameraID: UUID(), name: "Test", brief: "Brief",
            intervalSeconds: 30
        ))
        XCTAssertThrowsError(try CameraMission(
            cameraID: UUID(), name: "Test", brief: String(repeating: "x", count: 2001),
            intervalSeconds: 60
        ))
    }

    func testClockScheduleHonorsTimezoneWeekdaysAndStrictNextTime() throws {
        let calendar = Calendar(identifier: .gregorian)
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let after = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-02T08:30:00Z"))
        let next = try CameraMissionScheduler.nextRunAt(
            scheduleKind: .clock,
            intervalSeconds: 3600,
            clockTimes: ["09:00"],
            weekdays: [0],
            timeZoneIdentifier: "UTC",
            after: after
        )
        XCTAssertEqual(calendar.dateComponents(in: utc, from: next).hour, 9)
        XCTAssertEqual(calendar.dateComponents(in: utc, from: next).minute, 0)
        XCTAssertEqual(calendar.dateComponents(in: utc, from: next).weekday, 2)

        let afterSlot = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-02T09:00:00Z"))
        let followingMonday = try CameraMissionScheduler.nextRunAt(
            scheduleKind: .clock,
            intervalSeconds: 3600,
            clockTimes: ["09:00"],
            weekdays: [0],
            timeZoneIdentifier: "UTC",
            after: afterSlot
        )
        XCTAssertEqual(followingMonday.timeIntervalSince(afterSlot), 7 * 24 * 60 * 60)

        let clockMission = try CameraMission(
            cameraID: UUID(),
            name: "Morning loading check",
            brief: "Describe visible vehicle movement",
            intervalSeconds: 3600,
            scheduleKind: .clock,
            clockTimes: ["09:00"],
            weekdays: [0],
            timeZoneIdentifier: "UTC",
            createdAt: after,
            scheduleReferenceDate: after
        )
        let completed = try CameraMissionScheduler.finish(
            clockMission,
            completedAt: afterSlot,
            result: "No vehicle visible"
        )
        XCTAssertEqual(completed.nextRunAt.timeIntervalSince(afterSlot), 7 * 24 * 60 * 60)
    }

    func testMissionStartAndCommitRequireOptInIdleFreshSession() {
        func canStart(
            featureEnabled: Bool = true,
            wallRunning: Bool = true,
            connecting: Bool = false,
            vlmBusy: Bool = false,
            hasActiveMission: Bool = false,
            cameraEnabled: Bool = true,
            frameFresh: Bool = true
        ) -> Bool {
            CameraMissionScheduler.canStart(
                featureEnabled: featureEnabled,
                wallRunning: wallRunning,
                connecting: connecting,
                vlmBusy: vlmBusy,
                hasActiveMission: hasActiveMission,
                cameraEnabled: cameraEnabled,
                frameFresh: frameFresh
            )
        }

        XCTAssertTrue(canStart())
        XCTAssertFalse(canStart(featureEnabled: false))
        XCTAssertFalse(canStart(vlmBusy: true))
        XCTAssertFalse(canStart(frameFresh: false))
        XCTAssertFalse(CameraMissionScheduler.shouldCommit(
            featureEnabled: false, missionStillEnabled: true,
            generationMatches: true, sessionMatches: true, frameAge: 1
        ))
        XCTAssertFalse(CameraMissionScheduler.shouldCommit(
            featureEnabled: true, missionStillEnabled: false,
            generationMatches: true, sessionMatches: true, frameAge: 1
        ))
        XCTAssertFalse(CameraMissionScheduler.shouldCommit(
            featureEnabled: true, missionStillEnabled: true,
            generationMatches: true, sessionMatches: false, frameAge: 1
        ))
        XCTAssertFalse(CameraMissionScheduler.shouldCommit(
            featureEnabled: true, missionStillEnabled: true,
            generationMatches: true, sessionMatches: true, frameAge: 10
        ))
        XCTAssertTrue(CameraMissionScheduler.shouldCommit(
            featureEnabled: true, missionStillEnabled: true,
            generationMatches: true, sessionMatches: true, frameAge: 1
        ))
    }
}
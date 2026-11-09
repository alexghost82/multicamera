import XCTest
import CoreText
import ImageIO
import UniformTypeIdentifiers
@testable import CameraCore
@testable import CameraWall

final class TrackResearchTests: XCTestCase {
    func testScanHistorySearchFindsOlderEvidenceAndPromptKeepsItReadOnly() throws {
        let cameraID = UUID()
        let older = CameraScanRecord(cameraID: cameraID, cameraName: "Entrance", observedAt: Date(timeIntervalSince1970: 100), answer: "A red car was visible.")
        let newer = CameraScanRecord(cameraID: cameraID, cameraName: "Entrance", observedAt: Date(timeIntervalSince1970: 200), answer: "The entrance was empty.")
        let selected = TrackResearchSearch.selectScans(question: "red car", records: [newer, older], limit: 1)
        XCTAssertEqual(selected, [older])
        let prompt = try TrackResearchPrompt.make(question: "red car", records: [], scans: selected)
        XCTAssertTrue(prompt.contains(older.id.uuidString))
        XCTAssertTrue(prompt.contains("AUTOMATIC CAMERA SCANS"))
        XCTAssertTrue(prompt.contains("not live frames"))
        XCTAssertTrue(prompt.contains("scan_citations"))
        let response = "{\"answer\":\"A red car was recorded.\",\"citations\":[],\"scan_citations\":[\"\(older.id)\"]}"
        let reply = try XCTUnwrap(TrackResearchReply.parse(response, allowedTrackIDs: [], allowedScanIDs: [older.id]))
        XCTAssertEqual(reply.scanCitations, [older.id])
        XCTAssertNil(TrackResearchReply.parse(response, allowedTrackIDs: [], allowedScanIDs: []))
        let unsafe = "{\"answer\":\"A car.\",\"citations\":[],\"scan_citations\":[\"\(older.id)\"],\"actions\":[{\"kind\":\"describe_tracks\",\"trackIDs\":[\"\(older.id)\"]}]}"
        XCTAssertNil(TrackResearchReply.parse(unsafe, allowedTrackIDs: [], allowedScanIDs: [older.id]))
    }

    func testResearchReplyRejectsEveryTruncatedFencedPrefixWithoutTrap() throws {
        let json = #"{"answer":"A red car was recorded.","citations":[]}"#
        let fenced = "```json\n\(json)\n```"
        XCTAssertNotNil(TrackResearchReply.parse(json, allowedTrackIDs: []))
        XCTAssertNotNil(TrackResearchReply.parse(fenced, allowedTrackIDs: []))
        for end in fenced.indices {
            let prefix = String(fenced[..<end])
            XCTAssertNil(TrackResearchReply.parse(prefix, allowedTrackIDs: []), prefix)
        }
        XCTAssertNil(TrackResearchReply.parse(fenced + " trailing", allowedTrackIDs: []))
    }

    func testDescriptionBatchReplyRejectsUnterminatedCodeFenceWithoutTrap() {
        XCTAssertNil(TrackDescriptionBatchReply.parse("```json\n", requestedTrackIDs: [UUID()]))
        XCTAssertNil(TrackDescriptionBatchReply.parse("```json\n{\"descriptions\":[]}", requestedTrackIDs: [UUID()]))
        for response in ["```", "```json{", "```json\n{", "```json\n{}\ntrailing", "```json\n```"] {
            XCTAssertNil(TrackDescriptionBatchReply.parse(response, requestedTrackIDs: [UUID()]), response)
        }
    }

    func testLocalVisionReadsGeneratedVehicleTextFixture() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 640, height: 160, bitsPerComponent: 8, bytesPerRow: 640 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 160))
        let text = NSAttributedString(string: "AB1234", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica-Bold" as CFString, 80, nil),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1)
        ])
        context.textPosition = CGPoint(x: 40, y: 45)
        CTLineDraw(CTLineCreateWithAttributedString(text), context)
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let candidates = try VehicleTextReader.readCandidates(from: data as Data)
        XCTAssertTrue(candidates.contains { $0.text.replacingOccurrences(of: " ", with: "").contains("AB1234") })
    }

    func testVehicleTextPersistenceRequiresUninterruptedOptIn() {
        XCTAssertTrue(VehicleTextReader.shouldPersist(startedOptedIn: true, stillOptedIn: true, generationMatches: true))
        XCTAssertFalse(VehicleTextReader.shouldPersist(startedOptedIn: false, stillOptedIn: true, generationMatches: true))
        XCTAssertFalse(VehicleTextReader.shouldPersist(startedOptedIn: true, stillOptedIn: false, generationMatches: true))
        XCTAssertFalse(VehicleTextReader.shouldPersist(startedOptedIn: true, stillOptedIn: true, generationMatches: false))
    }

    func testVehicleTextEvidenceUsesStableDigestAndBoundedNormalizedCandidates() throws {
        let trackID = UUID()
        let now = Date(timeIntervalSince1970: 100)
        let imageData = Data("local synthetic crop".utf8)
        let evidence = try VehicleTextReader.evidence(candidates: [
            VehicleTextCandidate(text: " ab12 ", confidence: 0.9),
            VehicleTextCandidate(text: "AB12", confidence: 0.5),
            VehicleTextCandidate(text: "invalid", confidence: 2),
            VehicleTextCandidate(text: "broken\ntext", confidence: 0.9)
        ], imageData: imageData, trackID: trackID, readAt: now)
        XCTAssertTrue(evidence.isValid)
        XCTAssertEqual(evidence.candidates, [VehicleTextCandidate(text: "AB12", confidence: 0.9)])
        XCTAssertEqual(evidence.readAt, now)
        XCTAssertEqual(evidence.cropSHA256, try VehicleTextReader.evidence(candidates: [], imageData: imageData, trackID: trackID).cropSHA256)
        XCTAssertThrowsError(try VehicleTextReader.evidence(candidates: [], imageData: Data(), trackID: trackID))
    }

    func testQueryPlanPreparationFallsBackOnErrorsButPropagatesCancellation() async throws {
        let fallback = try await TrackResearchQueryPlan.prepare(question: "red coat") { _ in
            throw LocalVLMError.modelNotFound("local fixture")
        }
        XCTAssertNil(fallback)
        let malformed = try await TrackResearchQueryPlan.prepare(question: "red coat") { _ in "bad JSON" }
        XCTAssertNil(malformed)
        do {
            _ = try await TrackResearchQueryPlan.prepare(question: "red coat") { _ in throw CancellationError() }
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        }
        let plan = try await TrackResearchQueryPlan.prepare(question: "abrigo rojo") { prompt in
            XCTAssertTrue(prompt.contains("abrigo rojo"))
            XCTAssertFalse(prompt.contains("LOCAL TRACK RECORDS"))
            return #"{"concepts":[["red","rojo"],["coat","abrigo"]]}"#
        }
        XCTAssertEqual(plan?.concepts.count, 2)
    }

    func testQueryPlanRejectsUnboundedOrEmptyVocabulary() throws {
        XCTAssertNil(TrackResearchQueryPlan.parse("not JSON"))
        XCTAssertNil(TrackResearchQueryPlan.parse(#"{"concepts":[]}"#))
        XCTAssertNil(TrackResearchQueryPlan.parse(#"{"concepts":[[" "]]}"#))
        XCTAssertNil(TrackResearchQueryPlan.parse(#"{"concepts":[["!!!"]]}"#))
        let oversized = String(decoding: try JSONEncoder().encode(["concepts": [[String(repeating: "a", count: 129)]]]), as: UTF8.self)
        XCTAssertNil(TrackResearchQueryPlan.parse(oversized))
        XCTAssertThrowsError(try TrackResearchQueryPlan.prompt(question: String(repeating: "a", count: 2001)))
        let plan = try XCTUnwrap(TrackResearchQueryPlan.parse("```json\n{\"concepts\":[[\"red\",\"rojo\"]]}\n```"))
        XCTAssertEqual(plan.concepts, [["red", "rojo"]])
    }

    func testExpandedConceptsRetrieveOlderTranslatedEvidenceAcrossPages() throws {
        let plan = try XCTUnwrap(TrackResearchQueryPlan.parse(#"{"concepts":[["red","rojo"],["coat","abrigo"]]}"#))
        let matchingID = UUID()
        func record(id: UUID = UUID(), summary: String, time: TimeInterval) -> TrackedObjectRecord {
            TrackedObjectRecord(
                trackID: id, cameraID: UUID(), cameraName: "Entrance", label: "person",
                firstSeen: Date(timeIntervalSince1970: time), lastSeen: Date(timeIntervalSince1970: time),
                observationCount: 1, bestConfidence: 0.9, box: .zero, cropPath: nil,
                cutoutPath: nil, operatorGroupID: nil,
                description: TrackedObjectDescription(summary: summary, attributes: [:], overallConfidence: 0.9),
                describedAt: nil
            )
        }
        let older = record(id: matchingID, summary: "Person wearing a red coat", time: 1)
        let recent = record(summary: "Person wearing a blue shirt", time: 100)
        let selected = TrackResearchSearch.select(
            question: "abrigo rojo", records: [recent, older], limit: 1, queryPlan: plan
        )
        XCTAssertEqual(selected.map(\.trackID), [matchingID])
        let prompt = try TrackResearchPrompt.make(question: "abrigo rojo", records: selected, queryPlan: plan)
        XCTAssertTrue(prompt.contains(matchingID.uuidString))
        XCTAssertFalse(prompt.contains(recent.trackID.uuidString))
        let page = TrackResearchSearch.select(question: "abrigo rojo", records: [recent], limit: 1, queryPlan: plan)
        XCTAssertEqual(TrackResearchSearch.select(
            question: "abrigo rojo", records: page + [older], limit: 1, queryPlan: plan
        ).map(\.trackID), [matchingID])
    }

    func testActionSuggestionsMustUseAllowlistedKindAndCitedEvidenceOnly() throws {
        let trackID = UUID()
        let valid = """
        {"answer":"Description proposed.","citations":["\(trackID)"],"actions":[{"kind":"describe_tracks","trackIDs":["\(trackID)"]}]}
        """
        let reply = try XCTUnwrap(TrackResearchReply.parse(valid, allowedTrackIDs: [trackID]))
        XCTAssertEqual(reply.actions?.first?.trackIDs, [trackID])
        XCTAssertNil(TrackResearchReply.parse(valid, allowedTrackIDs: []))
        XCTAssertNil(TrackResearchReply.parse(valid.replacingOccurrences(of: "describe_tracks", with: "run_shell"), allowedTrackIDs: [trackID]))
        XCTAssertNil(TrackResearchReply.parse(valid.replacingOccurrences(of: "\"citations\":[\"\(trackID)\"]", with: "\"citations\":[]"), allowedTrackIDs: [trackID]))
    }

    func testReplyKeepsOnlyCitationsFromSuppliedEvidence() throws {
        let supportedID = UUID()
        let inventedID = UUID()
        let response = """
            ```json
            {"answer":"A red car was recorded.","citations":["\(supportedID.uuidString)","\(inventedID.uuidString)","\(supportedID.uuidString)"]}
            ```
            """

        let reply = try XCTUnwrap(TrackResearchReply.parse(response, allowedTrackIDs: [supportedID]))

        XCTAssertEqual(reply.answer, "A red car was recorded.")
        XCTAssertEqual(reply.citations, [supportedID])
    }

    func testReplyRejectsMalformedOrEmptyAnswers() {
        XCTAssertNil(TrackResearchReply.parse("not json", allowedTrackIDs: []))
        XCTAssertNil(TrackResearchReply.parse(#"{"answer":"  ","citations":[]}"#, allowedTrackIDs: []))
    }

    func testPromptIncludesOnlyThirtyRecentMetadataRecords() throws {
        let records = (0..<35).map { index in
            TrackedObjectRecord(
                trackID: UUID(), cameraID: UUID(), cameraName: "Camera \(index)", label: "person",
                firstSeen: Date(timeIntervalSince1970: Double(index)),
                lastSeen: Date(timeIntervalSince1970: Double(index)),
                observationCount: 1, bestConfidence: 0.9, box: .zero,
                cropPath: "private-image.jpg", cutoutPath: nil,
                operatorGroupID: nil, description: nil, describedAt: nil
            )
        }

        let prompt = try TrackResearchPrompt.make(question: "How many people?", records: records)

        XCTAssertTrue(prompt.localizedCaseInsensitiveContains(records[34].trackID.uuidString))
        XCTAssertFalse(prompt.localizedCaseInsensitiveContains(records[4].trackID.uuidString))
        XCTAssertFalse(prompt.contains("private-image.jpg"))
        XCTAssertTrue(prompt.contains("no tools, SQL access"))
    }

    func testPromptMapsAnAttachedCropToItsSelectedTrackID() throws {
        let trackID = UUID()
        let record = TrackedObjectRecord(
            trackID: trackID, cameraID: UUID(), cameraName: "Camera",
            label: "person", firstSeen: Date(), lastSeen: Date(), observationCount: 1,
            bestConfidence: 0.9, box: .zero, cropPath: "local.jpg", cutoutPath: nil,
            operatorGroupID: nil, description: nil, describedAt: nil
        )

        let prompt = try TrackResearchPrompt.make(
            question: "Describe the visible clothing", records: [record], imageTrackID: trackID
        )

        XCTAssertTrue(prompt.contains("attached image is the locally stored crop"))
        XCTAssertTrue(prompt.contains(trackID.uuidString))
        XCTAssertFalse(prompt.contains("local.jpg"))
    }

    func testDescriptionBatchReplyRequiresExactlyRequestedUUIDs() throws {
        let firstID = UUID()
        let secondID = UUID()
        let description = #"{"summary":"Visible dark coat","overallConfidence":0.8,"attributes":{}}"#
        let response = """
            {"descriptions":[
              {"trackID":"\(firstID.uuidString)","description":\(description)},
              {"trackID":"\(secondID.uuidString)","description":\(description)}
            ]}
            """

        let parsed = try XCTUnwrap(TrackDescriptionBatchReply.parse(response, requestedTrackIDs: [firstID, secondID]))

        XCTAssertEqual(Set(parsed.keys), [firstID, secondID])
        XCTAssertEqual(TrackDescriptionBatchReply.parse("```json\n\(response)\n```", requestedTrackIDs: [firstID, secondID]), parsed)
        let fenced = "```json\n\(response)\n```"
        for end in fenced.indices {
            let prefix = String(fenced[..<end])
            XCTAssertNil(TrackDescriptionBatchReply.parse(prefix, requestedTrackIDs: [firstID, secondID]), prefix)
        }
        XCTAssertNil(TrackDescriptionBatchReply.parse(fenced + " trailing", requestedTrackIDs: [firstID, secondID]))
        XCTAssertNil(TrackDescriptionBatchReply.parse(response, requestedTrackIDs: [firstID]))
        XCTAssertNil(TrackDescriptionBatchReply.parse(response, requestedTrackIDs: [firstID, UUID()]))
        XCTAssertNil(TrackDescriptionBatchReply.parse(response.replacingOccurrences(of: secondID.uuidString, with: firstID.uuidString), requestedTrackIDs: [firstID, secondID]))
        XCTAssertNil(TrackDescriptionBatchReply.parse(response.replacingOccurrences(of: "0.8", with: "1.8"), requestedTrackIDs: [firstID, secondID]))
        XCTAssertNil(TrackDescriptionBatchReply.parse(response.replacingOccurrences(of: secondID.uuidString, with: "invalid-uuid"), requestedTrackIDs: [firstID, secondID]))
    }

    func testDescriptionBatchPromptMapsTrackIDsAndCapsBatchSize() throws {
        let records = (0..<4).map { _ in TrackDescriptionBatchEvidence(trackID: UUID(), objectClass: "person") }

        let prompt = try TrackDescriptionBatchPrompt.make(records)

        XCTAssertTrue(prompt.contains("Never transfer evidence between images"))
        XCTAssertTrue(prompt.contains(records[0].trackID.uuidString))
        XCTAssertThrowsError(try TrackDescriptionBatchPrompt.make(records + [records[0]]))
    }

    func testVoiceTranscriptMergePreservesDraftAndCapsLength() {
        XCTAssertEqual(LocalVoiceInput.mergeTranscript("  show cars ", with: "Check camera"), "Check camera show cars")
        XCTAssertEqual(LocalVoiceInput.mergeTranscript("spoken", with: ""), "spoken")
        XCTAssertEqual(LocalVoiceInput.mergeTranscript(String(repeating: "a", count: 2100), with: "").count, 2000)
    }

    func testVehicleTextCandidatesAreDeduplicatedSortedAndBounded() {
        let candidates = VehicleTextCandidate.normalize([
            VehicleTextCandidate(text: "  ab12 ", confidence: 0.7),
            VehicleTextCandidate(text: "AB12", confidence: 0.9),
            VehicleTextCandidate(text: "x", confidence: 0.99),
            VehicleTextCandidate(text: "low", confidence: 0.1),
            VehicleTextCandidate(text: "CD34", confidence: 0.8)
        ], limit: 1)

        XCTAssertEqual(candidates, [VehicleTextCandidate(text: "AB12", confidence: 0.9)])
    }

    func testPromptRetrievesRelevantOlderRecordFromProvidedHistory() throws {
        let matchingID = UUID()
        let description = TrackedObjectDescription(
            summary: "Person wearing a red coat",
            attributes: [:],
            overallConfidence: 0.9
        )
        var records: [TrackedObjectRecord] = []
        for index in (0..<40).reversed() {
            let trackID: UUID = index == 0 ? matchingID : UUID()
            let trackDescription: TrackedObjectDescription? = index == 0 ? description : nil
            records.append(TrackedObjectRecord(
                trackID: trackID, cameraID: UUID(), cameraName: "Camera",
                label: "person", firstSeen: Date(timeIntervalSince1970: Double(index)),
                lastSeen: Date(timeIntervalSince1970: Double(index)), observationCount: 1,
                bestConfidence: 0.9, box: .zero, cropPath: "private-image.jpg", cutoutPath: nil,
                operatorGroupID: nil, description: trackDescription, describedAt: nil
            ))
        }

        let prompt = try TrackResearchPrompt.make(question: "Find the red coat", records: records)

        XCTAssertTrue(prompt.localizedCaseInsensitiveContains(matchingID.uuidString))
        XCTAssertFalse(prompt.contains("private-image.jpg"))
    }

    func testSearchCanMergePagesAndKeepAnOlderBestMatch() {
        let matchingID = UUID()
        let olderMatch = TrackedObjectRecord(
            trackID: matchingID, cameraID: UUID(), cameraName: "Camera",
            label: "person", firstSeen: Date(timeIntervalSince1970: 1),
            lastSeen: Date(timeIntervalSince1970: 1), observationCount: 1,
            bestConfidence: 0.9, box: .zero, cropPath: nil, cutoutPath: nil,
            operatorGroupID: nil,
            description: TrackedObjectDescription(
                summary: "Person wearing a distinct green coat", attributes: [:], overallConfidence: 0.9
            ),
            describedAt: nil
        )
        let recentPage = (0..<50).map { index in
            TrackedObjectRecord(
                trackID: UUID(), cameraID: UUID(), cameraName: "Camera",
                label: "person", firstSeen: Date(timeIntervalSince1970: Double(index + 2)),
                lastSeen: Date(timeIntervalSince1970: Double(index + 2)), observationCount: 1,
                bestConfidence: 0.9, box: .zero, cropPath: nil, cutoutPath: nil,
                operatorGroupID: nil, description: nil, describedAt: nil
            )
        }

        let retainedRecent = TrackResearchSearch.select(
            question: "green coat", records: recentPage, limit: TrackResearchPrompt.maximumRecords
        )
        let merged = TrackResearchSearch.select(
            question: "green coat", records: retainedRecent + [olderMatch],
            limit: TrackResearchPrompt.maximumRecords
        )

        XCTAssertEqual(merged.map(\.trackID), [matchingID])
    }

    func testNoMatchFallbackKeepsMostRecentRecordsAcrossPages() {
        let records = (0..<40).map { index in
            TrackedObjectRecord(
                trackID: UUID(), cameraID: UUID(), cameraName: "Camera",
                label: "person", firstSeen: Date(timeIntervalSince1970: Double(index)),
                lastSeen: Date(timeIntervalSince1970: Double(index)), observationCount: 1,
                bestConfidence: 0.9, box: .zero, cropPath: nil, cutoutPath: nil,
                operatorGroupID: nil, description: nil, describedAt: nil
            )
        }

        let recentPage = TrackResearchSearch.select(
            question: "unmatched detail", records: Array(records[20...]), limit: TrackResearchPrompt.maximumRecords
        )
        let merged = TrackResearchSearch.select(
            question: "unmatched detail", records: recentPage + records[..<20],
            limit: TrackResearchPrompt.maximumRecords
        )

        XCTAssertEqual(merged.map(\.lastSeen), merged.map(\.lastSeen).sorted(by: >))
        XCTAssertEqual(merged.first?.lastSeen, Date(timeIntervalSince1970: 39))
    }

    func testResearchStorePersistsPrivateBoundedHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("research.json")
        let messages = (0...TrackResearchStore.maximumMessages).map { index in
            TrackResearchMessage(role: .operatorMessage, text: "Question \(index)", citedTrackIDs: [])
        }

        try TrackResearchStore.save(messages, to: url)

        let restored = try TrackResearchStore.load(from: url)
        XCTAssertEqual(restored.count, TrackResearchStore.maximumMessages)
        XCTAssertEqual(restored.first?.text, "Question 1")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        try TrackResearchStore.clear(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(try TrackResearchStore.load(from: url).isEmpty)
    }
}
import XCTest
@testable import CameraCore
@testable import CameraWall

final class OperationsPreferencesTests: XCTestCase {
    func testWatchRuleMatchesOnlyScopedRecentDescribedTracksOnce() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cameraID = UUID()
        let record = TrackedObjectRecord(
            trackID: UUID(), cameraID: cameraID, cameraName: "North entrance", label: "person",
            firstSeen: now.addingTimeInterval(-10), lastSeen: now, observationCount: 2, bestConfidence: 0.9,
            box: .zero, cropPath: nil, cutoutPath: nil, operatorGroupID: nil,
            description: TrackedObjectDescription(
                summary: "Person wearing a red coat",
                attributes: ["clothing_color": TrackedAttribute(value: "red", confidence: 0.9, evidence: "Red coat visible")],
                overallConfidence: 0.9
            ), describedAt: now
        )
        var rule = try OperationsWatchRule(text: "If you see a RED coat", cameraIDs: [cameraID], createdAt: now, ttlSeconds: 120)
        XCTAssertEqual(rule.terms, ["red", "coat"])
        XCTAssertTrue(rule.matches(record, at: now.addingTimeInterval(30)))
        XCTAssertFalse(rule.matches(record, at: now.addingTimeInterval(120)))
        XCTAssertFalse(rule.matches(record, at: now.addingTimeInterval(301)))
        let otherCamera = TrackedObjectRecord(
            trackID: UUID(), cameraID: UUID(), cameraName: record.cameraName, label: record.label,
            firstSeen: record.firstSeen, lastSeen: record.lastSeen, observationCount: 1, bestConfidence: 0.9,
            box: .zero, cropPath: nil, cutoutPath: nil, operatorGroupID: nil,
            description: record.description, describedAt: now
        )
        XCTAssertFalse(rule.matches(otherCamera, at: now))
        rule.markFired(trackID: record.trackID)
        XCTAssertFalse(rule.matches(record, at: now))
        XCTAssertThrowsError(try OperationsWatchRule(text: "with", createdAt: now))
        XCTAssertThrowsError(try OperationsWatchRule(text: "red coat", createdAt: now, ttlSeconds: 1))
    }

    func testWatchStorePersistsPrivateRulesAndFiltersExpiredRules() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("watches.json")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let active = try OperationsWatchRule(text: "blue jacket", createdAt: now, ttlSeconds: 600)
        let forever = try OperationsWatchRule(text: "red backpack", createdAt: now, ttlSeconds: nil)
        try OperationsWatchStore.save([active, forever], to: url)
        XCTAssertEqual(try OperationsWatchStore.load(from: url, at: now), [active, forever])
        XCTAssertEqual(try OperationsWatchStore.load(from: url, at: now.addingTimeInterval(601)), [forever])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        var capped: [OperationsWatchRule] = []
        for _ in 0..<30 { capped.append(try OperationsWatchRule(text: "red coat")) }
        try OperationsWatchStore.save(capped, to: url)
        capped = try OperationsWatchStore.load(from: url)
        XCTAssertEqual(capped.count, OperationsWatchRule.maximumRules)
    }

    func testWatchFiredTrackEvictionRetainsMostRecentInsertionOrder() throws {
        let tracks = (0..<70).map { _ in UUID() }
        let rule = try OperationsWatchRule(text: "red coat", firedTrackIDs: tracks)
        XCTAssertEqual(rule.firedTrackIDs, Array(tracks.suffix(64)))
        var updated = rule
        let newest = UUID()
        updated.markFired(trackID: newest)
        XCTAssertEqual(updated.firedTrackIDs, Array((tracks.suffix(64) + [newest]).suffix(64)))
    }

    func testWatchEvaluatorCreatesOneEvidenceAlertPerRuleAndTrack() throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let cameraID = UUID()
        let trackID = UUID()
        let description = TrackedObjectDescription(
            summary: "Person wearing a red coat",
            attributes: ["clothing": TrackedAttribute(value: "red coat", confidence: 0.9, evidence: "Red coat visible")],
            overallConfidence: 0.9
        )
        let record = TrackedObjectRecord(
            trackID: trackID, cameraID: cameraID, cameraName: "North entrance", label: "person",
            firstSeen: now.addingTimeInterval(-5), lastSeen: now, observationCount: 2, bestConfidence: 0.9,
            box: .zero, cropPath: nil, cutoutPath: nil, operatorGroupID: nil, description: description, describedAt: now
        )
        let rule = try OperationsWatchRule(text: "red coat", cameraIDs: [cameraID], createdAt: now)
        let first = OperationsWatchEvaluator.evaluate(rules: [rule], records: [record], existingAlerts: [], at: now)
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.alerts.count, 1)
        XCTAssertEqual(first.alerts.first?.watchID, rule.id)
        XCTAssertEqual(first.alerts.first?.sourceTrackID, trackID)
        XCTAssertTrue(first.alerts.first?.evidence.contains("Red coat visible") == true)
        let repeated = OperationsWatchEvaluator.evaluate(rules: first.rules, records: [record], existingAlerts: first.alerts, at: now)
        XCTAssertFalse(repeated.changed)
        XCTAssertEqual(repeated.alerts.count, 1)
    }

    func testLocalMonitorDebouncesFaultsAndRecoveryAndPersistsBoundedHistory() throws {
        var monitor = LocalOperationsMonitor()
        let start = Date(timeIntervalSince1970: 2_000_000_000)
        func probe(_ status: LocalMonitorProbeStatus, second: Int) -> LocalMonitorProbe {
            LocalMonitorProbe(id: "relay", label: "Video relay", status: status,
                              detail: status == .down ? "Relay unavailable" : "Relay connected",
                              checkedAt: start.addingTimeInterval(Double(second * 5)))
        }
        XCTAssertTrue(monitor.update([probe(.down, second: 0)], at: start).isEmpty)
        XCTAssertTrue(monitor.update([probe(.down, second: 1)], at: start.addingTimeInterval(5)).isEmpty)
        let fault = monitor.update([probe(.down, second: 2)], at: start.addingTimeInterval(10))
        XCTAssertEqual(fault.map(\.kind), [.fault])
        XCTAssertEqual(monitor.snapshot.verdict, .fault)
        XCTAssertTrue(monitor.update([probe(.healthy, second: 3)], at: start.addingTimeInterval(15)).isEmpty)
        XCTAssertEqual(monitor.update([probe(.healthy, second: 4)], at: start.addingTimeInterval(20)).map(\.kind), [.recovered])
        XCTAssertEqual(monitor.snapshot.verdict, .ok)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitor.json")
        try LocalOperationsMonitorStore.save(monitor.history, to: url)
        XCTAssertEqual(try LocalOperationsMonitorStore.load(from: url), monitor.history)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let many = (0..<200).map { index in
            LocalMonitorEvent(occurredAt: start, probeID: "camera", label: "Camera", kind: .fault, detail: "Failure \(index)")
        }
        try LocalOperationsMonitorStore.save(many, to: url)
        XCTAssertEqual(try LocalOperationsMonitorStore.load(from: url).count, 120)
    }

    func testLocalMonitorWarningsAndInactiveChecksDoNotRaiseFaultTransitions() {
        var monitor = LocalOperationsMonitor()
        let now = Date(timeIntervalSince1970: 100)
        for second in 0..<4 {
            let warning = LocalMonitorProbe(id: "feed", label: "Camera feeds", status: .warning,
                                            detail: "One feed is stale", checkedAt: now.addingTimeInterval(Double(second * 5)))
            XCTAssertTrue(monitor.update([warning], at: warning.checkedAt).isEmpty)
        }
        let inactive = LocalMonitorProbe(id: "wall", label: "Camera wall", status: .inactive,
                                         detail: "Disconnected by operator", checkedAt: now)
        XCTAssertTrue(monitor.update([inactive], at: now).isEmpty)
        XCTAssertTrue(monitor.history.isEmpty)
    }

    func testConfiguredCriticalAlertEntersQueueBeforeAnyTriageDecision() {
        let alert = VLMAlert(cameraID: UUID(), cameraName: "Gate", condition: "Door is open", evidence: "Visible opening", priority: .critical)
        XCTAssertEqual(OperationsAlertQueue.pendingCriticalIDs(alerts: [alert], reviews: [:], acknowledgements: [:]), [alert.id])
        XCTAssertTrue(OperationsAlertQueue.pendingCriticalIDs(alerts: [alert], reviews: [:], acknowledgements: [alert.id: Date()]).isEmpty)
    }

    func testLegacyOperationsPreferencesKeepSoundDisabled() throws {
        let json = Data(#"{"personCountAlertsEnabled":true,"personThreshold":10,"holdSeconds":3,"cooldownSeconds":300}"#.utf8)
        let preferences = try JSONDecoder().decode(OperationsPreferences.self, from: json)
        XCTAssertFalse(preferences.criticalSoundEnabled)
        XCTAssertTrue(preferences.personCountAlertsEnabled)
    }

    func testCriticalQueueOrderingSoundGateAndReportEscaping() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let normal = VLMAlert(cameraID: UUID(), cameraName: "Normal", condition: "Condition", evidence: "Evidence")
        let critical = VLMAlert(cameraID: UUID(), cameraName: "<script>camera</script>", condition: "<img src=x>", evidence: "& evidence")
        let resolved = VLMAlert(cameraID: UUID(), cameraName: "Resolved", condition: "Condition", evidence: "Evidence")
        let reviews = [
            critical.id: OperationsAlertReview(alertID: critical.id, priority: .critical, status: .open, note: "<note>", updatedAt: now),
            resolved.id: OperationsAlertReview(alertID: resolved.id, priority: .critical, status: .resolved, note: "Checked", updatedAt: now)
        ]
        let alerts = [resolved, normal, critical]
        XCTAssertEqual(OperationsAlertQueue.ordered(alerts, reviews: reviews, acknowledgements: [:]).map(\.id), [critical.id, normal.id, resolved.id])
        let pending = OperationsAlertQueue.pendingCriticalIDs(alerts: alerts, reviews: reviews, acknowledgements: [:])
        XCTAssertEqual(pending, [critical.id])
        XCTAssertTrue(OperationsAlertQueue.shouldSound(featureEnabled: true, soundEnabled: true, previous: [], current: pending))
        XCTAssertFalse(OperationsAlertQueue.shouldSound(featureEnabled: false, soundEnabled: true, previous: [], current: pending))
        XCTAssertFalse(OperationsAlertQueue.shouldSound(featureEnabled: true, soundEnabled: false, previous: [], current: pending))
        XCTAssertFalse(OperationsAlertQueue.shouldSound(featureEnabled: true, soundEnabled: true, previous: pending, current: pending))
        let report = OperationsAlertReport.renderHTML(alerts: alerts, reviews: reviews, acknowledgements: [:], generatedAt: now)
        XCTAssertTrue(report.contains("&lt;script&gt;camera&lt;/script&gt;"))
        XCTAssertTrue(report.contains("&lt;note&gt;"))
        XCTAssertFalse(report.contains("<script>"))
        XCTAssertFalse(report.contains("<img"))
        XCTAssertTrue(report.contains("default-src 'none'"))
    }

    func testReportDisclosesTruncationAndKeepsQueueOrder() {
        let alerts = (0..<101).map { index in
            VLMAlert(createdAt: Date(timeIntervalSince1970: Double(index)), cameraID: UUID(),
                     cameraName: "Camera \(index)", condition: "Condition", evidence: "Evidence")
        }
        let report = OperationsAlertReport.renderHTML(alerts: alerts, reviews: [:], acknowledgements: [:])
        XCTAssertTrue(report.contains("Showing 100 of 101 stored alerts."))
        XCTAssertTrue(report.contains("Camera 100"))
        XCTAssertFalse(report.contains("<td>Camera 0</td>"))

        let complete = OperationsAlertReport.renderHTML(alerts: Array(alerts.prefix(100)), reviews: [:], acknowledgements: [:])
        XCTAssertFalse(complete.contains("Showing 100 of"))
    }

    func testCrowdAlertsDefaultOffAndPreferencesRoundTripWithPrivatePermissions() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("operations.json")

        XCTAssertFalse(OperationsPreferences().personCountAlertsEnabled)
        let preferences = OperationsPreferences(
            personCountAlertsEnabled: true,
            personThreshold: 18,
            holdSeconds: 5,
            cooldownSeconds: 600,
            criticalSoundEnabled: true
        )
        try OperationsPreferencesStore.save(preferences, to: url)

        XCTAssertEqual(try OperationsPreferencesStore.load(from: url), preferences)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCrowdEvaluatorRequiresSustainedCountAndRespectsCooldown() {
        let cameraID = UUID()
        var evaluator = CrowdAlertEvaluator()

        XCTAssertFalse(evaluator.shouldAlert(
            cameraID: cameraID, personCount: 10, threshold: 10, now: 0,
            holdSeconds: 3, cooldownSeconds: 60
        ))
        XCTAssertFalse(evaluator.shouldAlert(
            cameraID: cameraID, personCount: 12, threshold: 10, now: 2,
            holdSeconds: 3, cooldownSeconds: 60
        ))
        XCTAssertTrue(evaluator.shouldAlert(
            cameraID: cameraID, personCount: 11, threshold: 10, now: 3,
            holdSeconds: 3, cooldownSeconds: 60
        ))
        XCTAssertFalse(evaluator.shouldAlert(
            cameraID: cameraID, personCount: 20, threshold: 10, now: 20,
            holdSeconds: 3, cooldownSeconds: 60
        ))
        XCTAssertFalse(evaluator.shouldAlert(
            cameraID: cameraID, personCount: 0, threshold: 10, now: 21,
            holdSeconds: 3, cooldownSeconds: 60
        ))
    }
}
import Foundation
import CameraCore

/// Bounded evidence chosen across cameras, with aggregate coverage computed from the full store.
struct UnifiedHistoryEvidence {
    let json: String
    let since: Date?
    let until: Date?
    let cameraID: UUID?

    static func load(store: LocalTrackingStore, question: String, prior: [ACTAChatMessageRecord], cameras: [UUID: String], now: Date) throws -> Self {
        let previous = prior.map { message in
            let refs = message.structuredAnswer?.evidenceReferences ?? []
            return TrackResearchMessage(role: message.role == "user" ? .operatorMessage : .assistant,
                text: message.text,
                citedTrackIDs: refs.filter { $0.kind == "track" }.compactMap { UUID(uuidString: $0.recordID) },
                citedScanIDs: refs.filter { $0.kind == "scan" }.compactMap { UUID(uuidString: $0.recordID) }, createdAt: message.createdAt)
        }
        let scope = try UnifiedHistoryTimeScope.resolve(question: question, prior: previous, now: now)
        let start = scope?.start ?? Date(timeIntervalSince1970: 0)
        let end = scope?.end ?? now
        var directory = cameras
        for table in ["tracked_objects", "automatic_camera_scans"] {
            for row in try store.executeReadOnlyACTASQL("SELECT camera_id, camera_name FROM \(table) GROUP BY camera_id LIMIT 200") {
                if let id = row["camera_id"].flatMap(UUID.init(uuidString:)), let name = row["camera_name"] { directory[id] = name }
            }
        }
        let matched = directory.filter { question.localizedCaseInsensitiveContains($0.value) && !$0.value.isEmpty }
        let allCameras = question.localizedCaseInsensitiveContains("всех камер") || question.localizedCaseInsensitiveContains("all cameras")
        let cameraID = !allCameras && matched.count == 1 ? matched.first?.key : nil
        let cameraFilter = cameraID.map { " AND camera_id = '\($0.uuidString)'" } ?? ""
        var coverage: [[String: String]] = []
        for (table, time, kind) in [("tracked_objects", "last_seen", "track"), ("automatic_camera_scans", "observed_at", "scan")] {
            let rows = try store.executeReadOnlyACTASQL("SELECT camera_id, camera_name, COUNT(*) AS record_count, MIN(\(time)) AS first_record, MAX(\(time)) AS last_record FROM \(table) WHERE \(time) >= \(start.timeIntervalSince1970) AND \(time) < \(end.timeIntervalSince1970)\(cameraFilter) GROUP BY camera_id ORDER BY camera_name LIMIT 200")
            coverage += rows.map { row in
                var value = row
                value["kind"] = kind
                for key in ["first_record", "last_record"] { if let stamp = value[key].flatMap(Double.init) { value[key] = iso(Date(timeIntervalSince1970: stamp)) } }
                value["stat_id"] = "\(kind)-\(row["camera_id"] ?? "unknown")-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))"
                return value
            }
        }
        let selection = try TrackResearchSearch.load(from: store, question: question, priorMessages: previous, now: now, scopeOverride: scope)
        let tracks = selection.tracks.filter { cameraID == nil || $0.cameraID == cameraID }
        let scans = selection.scans.filter { $0.observedAt <= now && (cameraID == nil || $0.cameraID == cameraID) }
        // Even a general question must cover cameras whose latest record is older than the busiest camera's top N.
        var sampledTracks = balanced(tracks, camera: { $0.cameraID }, limit: 12)
        var sampledScans = balanced(scans, camera: { $0.cameraID }, limit: 12)
        if cameraID == nil {
            let represented = Set(coverage.compactMap { $0["camera_id"].flatMap(UUID.init(uuidString:)) })
            for id in represented.sorted(by: { $0.uuidString < $1.uuidString }) {
                if !sampledScans.contains(where: { $0.cameraID == id }) {
                    let rows = try store.executeReadOnlyACTASQL("SELECT scan_id, camera_id, camera_name, observed_at, answer FROM automatic_camera_scans WHERE camera_id = '\(id.uuidString)' AND observed_at >= \(start.timeIntervalSince1970) AND observed_at <= \(end.timeIntervalSince1970) ORDER BY observed_at DESC LIMIT 1")
                    if let row = rows.first, let scanID = row["scan_id"].flatMap(UUID.init(uuidString:)), let at = row["observed_at"].flatMap(Double.init) {
                        sampledScans.append(CameraScanRecord(id: scanID, cameraID: id, cameraName: row["camera_name"] ?? "", observedAt: Date(timeIntervalSince1970: at), answer: row["answer"] ?? ""))
                    }
                }
            }
        }
        sampledTracks = Array(sampledTracks.prefix(24)); sampledScans = Array(sampledScans.prefix(24))
        let trackRows: [[String: Any]] = sampledTracks.map {
            ["track_id": $0.trackID.uuidString, "camera_id": $0.cameraID.uuidString, "camera_name": $0.cameraName,
             "first_seen": iso($0.firstSeen), "last_seen": iso($0.lastSeen), "label": $0.label,
             "summary": String(($0.description?.summary ?? $0.label).prefix(500)), "has_saved_image": $0.cropPath != nil]
        }
        let scanRows: [[String: Any]] = sampledScans.map {
            ["scan_id": $0.id.uuidString, "camera_id": $0.cameraID.uuidString, "camera_name": $0.cameraName,
             "observed_at": iso($0.observedAt), "answer": String($0.answer.prefix(500))]
        }
        let payload: [String: Any] = ["since": iso(start), "until": iso(end), "coverage": coverage,
            "tracks": trackRows, "automatic_scans": scanRows,
            "limitations": "Counts cover the requested window; detail records are a bounded sample. A scan is a saved text observation, not a video recording. No claim of continuous video coverage."]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return Self(json: String(decoding: data, as: UTF8.self), since: scope?.start, until: scope?.end, cameraID: cameraID)
    }

    private static func balanced<T>(_ rows: [T], camera: (T) -> UUID, limit: Int) -> [T] {
        let groups = Dictionary(grouping: rows, by: camera)
        let keys = groups.keys.sorted { $0.uuidString < $1.uuidString }
        var result: [T] = []
        var index = 0
        while result.count < limit {
            let batch = keys.compactMap { key -> T? in guard let group = groups[key], group.indices.contains(index) else { return nil }; return group[index] }
            if batch.isEmpty { break }
            result += batch.prefix(limit - result.count); index += 1
        }
        return result
    }
    private static func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
}

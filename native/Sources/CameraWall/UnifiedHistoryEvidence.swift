import Foundation
import CameraCore

enum ACTACameraSelectionError: LocalizedError {
    case ambiguous
    case unresolved

    var errorDescription: String? {
        switch self {
        case .ambiguous:
            return "AMBIGUOUS_CAMERA: Multiple cameras match; specify a unique camera ID or ask for all cameras."
        case .unresolved:
            return "CAMERA_NOT_FOUND: Specify a unique camera name or ID, or ask for all cameras."
        }
    }
}

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
        let cameraID = try resolveCamera(question: question, directory: directory)
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
             "summary": String(($0.description?.summary ?? $0.label).prefix(500)), "has_saved_image": $0.cropPath != nil,
             "attributes": $0.description?.attributes.mapValues { String($0.value.prefix(100)) } ?? [:],
             "vehicle_ocr": (try? store.vehicleTextEvidence(for: $0.trackID))?.candidates.prefix(3).map(\.text) ?? []]
        }
        let scanRows: [[String: Any]] = sampledScans.map {
            ["scan_id": $0.id.uuidString, "camera_id": $0.cameraID.uuidString, "camera_name": $0.cameraName,
             "observed_at": iso($0.observedAt), "answer": String($0.answer.prefix(500))]
        }
        let totals: [[String: String]] = ["track", "scan"].map { kind in
            let rows = coverage.filter { $0["kind"] == kind }
            return ["stat_id": "all-\(kind)-\(Int(start.timeIntervalSince1970))-\(Int(end.timeIntervalSince1970))", "kind": kind,
                    "record_count": String(rows.reduce(0) { $0 + (Int($1["record_count"] ?? "") ?? 0) }),
                    "camera_count": String(rows.count), "first_record": rows.compactMap { $0["first_record"] }.min() ?? "",
                    "last_record": rows.compactMap { $0["last_record"] }.max() ?? ""]
        }
        let payload: [String: Any] = ["requested_since": scope == nil ? "all retained history" : iso(start), "requested_until": iso(end), "coverage": coverage, "totals": totals,
            "tracks": trackRows, "automatic_scans": scanRows,
            "limitations": "Counts cover the requested window; detail records are a bounded sample. A scan is a saved text observation, not a video recording. No claim of continuous video coverage."]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return Self(json: String(decoding: data, as: UTF8.self), since: scope?.start, until: scope?.end, cameraID: cameraID)
    }

    static func resolveCamera(question: String, directory: [UUID: String]) throws -> UUID? {
        let matched = directory.filter { question.localizedCaseInsensitiveContains($0.value) && !$0.value.isEmpty }
        let allCameras = requestsAllCameras(question)
        if excludesCameras(question) || (allCameras && restrictsAllCameras(question)) {
            throw ACTACameraSelectionError.unresolved
        }
        let requestedIDs = Set(question.split { !$0.isHexDigit && $0 != "-" }
            .compactMap { UUID(uuidString: String($0)) }.filter { directory[$0] != nil })
        if !allCameras && (requestedIDs.count > 1 || (requestedIDs.isEmpty && matched.count > 1)) {
            throw ACTACameraSelectionError.ambiguous
        }
        if allCameras { return nil }
        let words = question.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "-" }
        let markers: Set<String> = ["camera", "камере", "камера", "камеру", "камеры", "камерой", "камер"]
        let markerIndices = words.indices.filter { markers.contains(String(words[$0])) }
        guard !markerIndices.isEmpty else { return requestedIDs.first ?? matched.first?.key }
        var selected: Set<UUID> = []
        for marker in markerIndices {
            let nameIndex = words.index(after: marker)
            guard nameIndex < words.endIndex else { throw ACTACameraSelectionError.unresolved }
            let name = String(words[nameIndex])
            if let uuid = UUID(uuidString: name) {
                guard directory[uuid] != nil else { throw ACTACameraSelectionError.unresolved }
                selected.insert(uuid)
                continue
            }
            let candidates = directory.filter { _, value in
                value.lowercased().split { !$0.isLetter && !$0.isNumber }
                    .contains { $0 == name || (name.count >= 3 && $0.hasPrefix(name)) }
            }
            let exact = candidates.filter { matched[$0.key] != nil }
            if let id = requestedIDs.first, candidates[id] != nil {
                selected.insert(id)
            } else if exact.count == 1, let id = exact.first?.key {
                selected.insert(id)
            } else {
                guard name.count >= 3 else { throw ACTACameraSelectionError.unresolved }
                if candidates.count > 1 { throw ACTACameraSelectionError.ambiguous }
                guard let id = candidates.first?.key else { throw ACTACameraSelectionError.unresolved }
                selected.insert(id)
            }
        }
        if let requested = requestedIDs.first { selected.insert(requested) }
        if selected.count > 1 { throw ACTACameraSelectionError.ambiguous }
        return selected.first
    }

    static func requestsAllCameras(_ question: String) -> Bool {
        let text = cameraWords(question)
        return ["всех камер", "все камеры", "всем камерам", "all cameras", "all the cameras"]
            .contains { text.contains(" \($0) ") }
    }

    private static func restrictsAllCameras(_ question: String) -> Bool {
        let text = cameraWords(question)
        return ["not", "не", "except", "excluding", "without", "кроме", "исключая", "без"]
                .contains { text.contains(" \($0) ") }
            || ["apart from", "other than"].contains { text.contains(" \($0) ") }
    }

    private static func excludesCameras(_ question: String) -> Bool {
        let text = cameraWords(question)
        return ["no camera", "no cameras", "никакие камеры", "ни одной камеры"]
            .contains { text.contains(" \($0) ") }
    }

    private static func cameraWords(_ question: String) -> String {
        " " + question.lowercased().split { !$0.isLetter && !$0.isNumber }
            .joined(separator: " ") + " "
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
    private static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

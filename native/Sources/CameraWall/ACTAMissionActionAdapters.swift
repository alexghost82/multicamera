import CameraCore
import Foundation

struct WallMissionAction: ACTAActionProtocol {
    enum Kind: String, CaseIterable, Sendable {
        case list = "mission.list", create = "mission.create", edit = "mission.edit", delete = "mission.delete"
        case consult = "mission.ask_consult"
        case history = "mission.history", clearConsult = "mission.clear_consult", run = "mission.run_now"
    }
    let kind: Kind
    unowned let model: WallModel
    var id: String { kind.rawValue }
    var title: String { id }
    var description: String {
        switch kind {
        case .consult: return "Submit a local question (max 2000 characters) about saved mission run summaries. Persists the question; acceptance does not verify an answer. Read mission.history for the reply."
        case .list: return "Read saved local missions and execution state (idle/queued/running)."
        case .create: return "Create a local camera mission, disabled by default. clock_times is comma-separated HH:mm; weekdays is comma-separated 0=Monday...6=Sunday, empty means every day. Clock schedules require an explicit IANA time_zone."
        case .edit: return "Edit one saved local mission by UUID; preserves history and recomputes next_run only when schedule changes. weekdays uses 0=Monday...6=Sunday, empty means every day. Can set enabled."
        case .delete: return "Delete a mission and its consultation, preserving recorded run summaries. Requires operator confirmation."
        case .history: return "Read saved mission runs and consultation only. Does not inspect fresh frames or run inference."
        case .clearConsult: return "Permanently clear one mission's consultation while preserving runs; requires confirmation."
        case .run: return "Unavailable until mission execution is coordinated across application instances."
        }
    }
    var classification: ACTAActionClassification {
        switch kind {
        case .list, .history: return .inspect
        case .delete, .clearConsult: return .destructive
        case .run, .consult: return .serviceAffecting
        case .create, .edit: return .reversible
        }
    }
    var parameters: [ACTAActionParameterSchema] {
        func field(_ name: String, _ type: String, _ required: Bool = false, _ values: [String]? = nil) -> ACTAActionParameterSchema {
            ACTAActionParameterSchema(name: name, type: type, description: name, isRequired: required, allowedValues: values)
        }
        switch kind {
        case .consult: return [field("mission_id", "string", true), field("question", "string", true)]
        case .list: return []
        case .history: return [field("mission_id", "string", true), field("limit", "integer")]
        case .delete, .clearConsult, .run: return [field("mission_id", "string", true)]
        case .create, .edit:
            return (kind == .edit ? [field("mission_id", "string", true)] : []) + [
                field("camera_id", "string", kind == .create), field("name", "string", kind == .create),
                field("brief", "string", kind == .create), field("interval_seconds", "integer"),
                field("schedule_kind", "string", false, ["interval", "clock"]), field("clock_times", "string"),
                field("weekdays", "string"), field("time_zone", "string"), field("enabled", "boolean")]
        }
    }
    func validate(parameters: [String: String]) throws {
        switch kind {
        case .history:
            if let raw = parameters["limit"], Int(raw) == nil {
                throw ConfigurationError.invalid("Limit must be an integer from 1 to 100.")
            }
        case .create, .edit:
            if let raw = parameters["interval_seconds"], Int(raw) == nil {
                throw ConfigurationError.invalid("Mission interval must be an integer.")
            }
            if let raw = parameters["schedule_kind"], CameraMissionScheduleKind(rawValue: raw) == nil {
                throw ConfigurationError.invalid("Mission schedule must be interval or clock.")
            }
            if let raw = parameters["enabled"], !["true", "false", "1", "0"].contains(raw) {
                throw ConfigurationError.invalid("Mission enabled must be a boolean.")
            }
        default: break
        }
    }
    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        guard kind != .run else {
            return .failed(actionID: id, error: "UNAVAILABLE: Mission execution is not coordinated across application instances.")
        }
        try validate(parameters: parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard model.featurePreferences.enabledFeatures.contains(.scheduledMissions) else {
                throw CameraFeatureStoreError.featureDisabled(.scheduledMissions)
            }
            if kind == .create || kind == .edit {
                _ = try model.featurePolicySnapshotChecked()
            }
            let before = try model.missionDocumentChecked()
            func json<T: Encodable>(_ value: T) throws -> String {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys]
                return String(decoding: try encoder.encode(value), as: UTF8.self)
            }
            func evidenceJSON<T: Encodable>(_ rows: [T], identifiers: (T) -> [String: String]) throws -> String {
                let objects = try rows.map { row -> [String: Any] in
                    let encoded = try json(row)
                    guard var object = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any] else {
                        throw ConfigurationError.invalid("Mission evidence serialization failed.")
                    }
                    identifiers(row).forEach { object[$0.key] = $0.value }
                    return object
                }
                return String(decoding: try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]), as: UTF8.self)
            }
            func success(_ summary: String, _ output: String) -> ACTAActionResult {
                ACTAActionResult(actionID: id, success: true, summary: summary, outputJSON: output)
            }
            if kind == .list {
                let states = Dictionary(uniqueKeysWithValues: before.missions.map { ($0.id.uuidString, model.missionExecutionStatus($0.id)) })
                let rows = try evidenceJSON(before.missions) {
                    ["mission_id": $0.id.uuidString, "camera_id": $0.cameraID.uuidString, "created_at": $0.createdAt.ISO8601Format(), "type": "mission"]
                }
                return success("Read saved missions and runtime state.", "{\"missions\":\(rows),\"execution\":\(try json(states))}")
            }
            if kind == .history {
                guard let missionID = parameters["mission_id"].flatMap(UUID.init(uuidString:)) else {
                    throw ConfigurationError.invalid("Mission UUID does not identify a saved mission.")
                }
                let limit = parameters["limit"].flatMap(Int.init) ?? 20
                guard (1...100).contains(limit) else { throw ConfigurationError.invalid("Limit must be 1...100.") }
                let runs = before.runs.filter { $0.missionID == missionID }.sorted { $0.occurredAt > $1.occurredAt }
                let consults = before.consults.filter { $0.missionID == missionID }
                guard before.missions.contains(where: { $0.id == missionID }) || !runs.isEmpty else {
                    throw ConfigurationError.invalid("Mission UUID does not identify a saved mission.")
                }
                let runRows = try evidenceJSON(Array(runs.prefix(limit))) {
                    ["run_id": $0.id.uuidString, "mission_id": $0.missionID.uuidString,
                     "camera_id": $0.cameraID.uuidString, "occurred_at": $0.occurredAt.ISO8601Format(), "type": "mission_run"]
                }
                let consultRows = try evidenceJSON(Array(consults.suffix(limit))) {
                    ["event_id": $0.id.uuidString, "mission_id": $0.missionID.uuidString, "created_at": $0.createdAt.ISO8601Format(),
                     "type": $0.role == .operatorMessage ? "mission_consult_question" : "mission_consult_response"]
                }
                return success("Read saved mission history; no fresh observations.", "{\"runs\":\(runRows),\"consults\":\(consultRows)}")
            }
            var existing: CameraMission?
            if kind != .create {
                guard let uuid = parameters["mission_id"].flatMap(UUID.init(uuidString:)),
                      let found = before.missions.first(where: { $0.id == uuid }) else {
                    throw ConfigurationError.invalid("Mission UUID does not identify a saved mission.")
                }
                existing = found
            }
            if let existing {
                switch kind {
                case .consult:
                    let question = parameters["question"] ?? ""
                    guard question.count <= 2000 else {
                        throw ConfigurationError.invalid("Mission question must not exceed 2000 characters.")
                    }
                    let questionID = try model.askMissionConsult(missionID: existing.id, question: question)
                    let saved = try model.missionDocumentChecked()
                    guard saved.consults.contains(where: { $0.id == questionID && $0.missionID == existing.id && $0.role == .operatorMessage }) else {
                        throw ConfigurationError.invalid("Mission consultation request verification failed.")
                    }
                    return success("Local consultation request accepted; no answer has been verified.", "{\"question_id\":\(try json(questionID.uuidString)),\"accepted\":true,\"completion_verified\":false}")
                case .delete, .clearConsult:
                    if kind == .delete { try model.deleteCameraMissionChecked(existing.id) }
                    else { try model.clearMissionConsult(missionID: existing.id) }
                    let saved = try model.missionDocumentChecked()
                    let expected = kind == .delete ? before.missions.filter { $0.id != existing.id } : before.missions
                    guard try json(saved.missions) == json(expected), saved.runs == before.runs,
                          saved.consults == before.consults.filter({ $0.missionID != existing.id }) else {
                        throw ConfigurationError.invalid("Mission deletion or consultation clearing verification failed.")
                    }
                    return success("Mission change saved and verified; run history preserved.", "{\"deleted\":true}")
                default: break
                }
            }
            guard kind == .create || kind == .edit else { return .unsupported(actionID: id) }
            guard kind != .edit || parameters.count > 1 else { throw ConfigurationError.invalid("Specify at least one mission change.") }
            let camera = parameters["camera_id"].flatMap(UUID.init(uuidString:)) ?? existing?.cameraID
            let checkedConfiguration = try model.cameraConfigurationChecked()
            guard let camera, checkedConfiguration.cameras.contains(where: { $0.id == camera }),
                  parameters["camera_id"] == nil || UUID(uuidString: parameters["camera_id"] ?? "") != nil else {
                throw ConfigurationError.invalid("Camera UUID does not identify a configured camera.")
            }
            let schedule = parameters["schedule_kind"].flatMap(CameraMissionScheduleKind.init(rawValue:)) ?? existing?.scheduleKind ?? .interval
            func csv(_ name: String) throws -> [String] {
                guard let raw = parameters[name] else { return [] }
                if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [] }
                let values = raw.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
                guard values.allSatisfy({ !$0.isEmpty }), Set(values).count == values.count else {
                    throw ConfigurationError.invalid("Schedule lists must contain unique nonempty comma-separated values.")
                }
                return values
            }
            let times = parameters["clock_times"] != nil ? try csv("clock_times") : existing?.clockTimes ?? []
            let weekdayStrings = parameters["weekdays"] != nil ? try csv("weekdays") : existing?.weekdays.map(String.init) ?? []
            let weekdays = weekdayStrings.compactMap(Int.init)
            guard weekdays.count == weekdayStrings.count, Set(weekdays).count == weekdays.count,
                  weekdays.allSatisfy({ (0...6).contains($0) }) else {
                throw ConfigurationError.invalid("Mission weekdays must be unique integers from 0 to 6.")
            }
            guard schedule == .clock || parameters["clock_times"] == nil && parameters["weekdays"] == nil else {
                throw ConfigurationError.invalid("Clock times and weekdays require a clock schedule.")
            }
            let zone = parameters["time_zone"] ?? existing?.timeZoneIdentifier ?? TimeZone.current.identifier
            guard TimeZone(identifier: zone) != nil,
                  schedule != .clock || existing?.scheduleKind == .clock || parameters["time_zone"] != nil else {
                throw ConfigurationError.invalid("Clock schedules require an explicit valid IANA time zone.")
            }
            let interval = parameters["interval_seconds"].flatMap(Int.init) ?? existing?.intervalSeconds ?? 3600
            let clockTimes = schedule == .clock ? times : []
            let days = schedule == .clock ? weekdays.sorted() : []
            let changed = existing.map { $0.scheduleKind != schedule || (schedule == .interval && $0.intervalSeconds != interval) || $0.clockTimes != clockTimes || $0.weekdays != days || $0.timeZoneIdentifier != zone } ?? false
            let mission = try CameraMission(id: existing?.id ?? UUID(), cameraID: camera,
                name: parameters["name"] ?? existing?.name ?? "", brief: parameters["brief"] ?? existing?.brief ?? "",
                intervalSeconds: interval, scheduleKind: schedule, clockTimes: clockTimes, weekdays: days,
                timeZoneIdentifier: zone, enabled: parameters["enabled"].map { $0 == "true" || $0 == "1" } ?? existing?.enabled ?? false,
                createdAt: existing?.createdAt ?? context.now, scheduleReferenceDate: context.now,
                nextRunAt: changed ? nil : existing?.nextRunAt, lastRunAt: existing?.lastRunAt, lastResult: existing?.lastResult)
            try model.saveCameraMission(mission)
            let saved = try model.missionDocumentChecked()
            guard let persisted = saved.missions.first(where: { $0.id == mission.id }), try json(persisted) == json(mission),
                  saved.runs == before.runs, saved.consults == before.consults else {
                throw ConfigurationError.invalid("Mission save persistence verification failed.")
            }
            return success("Mission saved and verified.", "{\"mission\":\(try json(persisted))}")
        }
    }
    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool { true }
}

import CameraCore
import Combine
import Foundation
import SwiftUI

enum ACTACameraScope: String, CaseIterable, Identifiable {
    case all = "All cameras"
    case live = "Live"
    case offline = "Offline"

    var id: String { rawValue }
    var title: LocalizedStringKey { LocalizedStringKey(rawValue) }
}

enum ACTACameraPresentation: String, CaseIterable, Identifiable {
    case grid
    case list

    var id: String { rawValue }
    var title: LocalizedStringKey { self == .grid ? "Grid" : "List" }
    var icon: String { self == .grid ? "square.grid.2x2" : "list.bullet" }
}

@MainActor
final class ACTACanvasFilterState: ObservableObject {
    @Published var cameraScope: ACTACameraScope = .all
    @Published var locationFilter: String?
    @Published var searchText = ""
    @Published var alertsOnly = false
    @Published var favoritesOnly = false
    @Published var selectedCameraIDs: Set<UUID>?
    @Published var arrangeCameras = false
    @Published var presentation: ACTACameraPresentation = .grid
    @Published var analysisSection: VLMPanelSection = .ask
    let analysisVoiceInput: LocalVoiceInput
    var analysisVoiceBusy: Bool { analysisVoiceInput.isBusy }
    var analysisScheduleRefreshOnAppear = true

    init(analysisVoiceInput: LocalVoiceInput = LocalVoiceInput()) {
        self.analysisVoiceInput = analysisVoiceInput
    }

    func stopAnalysisVoice() {
        analysisVoiceInput.stop()
    }

    func selectAnalysisSectionFromGUI(_ section: VLMPanelSection) {
        if analysisSection == .ask && section != .ask { stopAnalysisVoice() }
        analysisScheduleRefreshOnAppear = true
        analysisSection = section
    }

    static func locationGroup(_ location: String?) -> String {
        let trimmed = location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Other" : trimmed
    }

    func includesCamera(id: UUID) -> Bool {
        selectedCameraIDs?.contains(id) ?? true
    }

    func includes(name: String, location: String?, stale: Bool?, favorite: Bool, hasEvents: Bool) -> Bool {
        guard cameraScope == .all || (cameraScope == .live) == (stale == false) else { return false }
        guard locationFilter == nil || Self.locationGroup(location) == locationFilter else { return false }
        guard !favoritesOnly || favorite else { return false }
        guard !alertsOnly || hasEvents else { return false }
        return searchText.isEmpty || "\(name) \(location ?? "")".localizedCaseInsensitiveContains(searchText)
    }
}

@MainActor
final class ACTACanvasFilterBridge {
    private struct Entry {
        weak var state: ACTACanvasFilterState?
    }
    private var entries: [Entry] = []
    private weak var writtenState: ACTACanvasFilterState?
    private weak var arrangeWrittenState: ACTACanvasFilterState?
    private weak var presentationWrittenState: ACTACanvasFilterState?
    private weak var analysisWrittenState: ACTACanvasFilterState?
    private var analysisWrittenSection: VLMPanelSection?
    private weak var selectionWrittenState: ACTACanvasFilterState?
    private var selectionInventory: Set<UUID>?
    private var selectionValue: Set<UUID>?

    func attach(_ state: ACTACanvasFilterState) {
        writtenState = nil
        arrangeWrittenState = nil
        presentationWrittenState = nil
        analysisWrittenState = nil
        analysisWrittenSection = nil
        clearSelectionWrite()
        entries.removeAll { $0.state == nil || $0.state === state }
        entries.append(Entry(state: state))
    }

    func detach(_ state: ACTACanvasFilterState) {
        writtenState = nil
        arrangeWrittenState = nil
        presentationWrittenState = nil
        analysisWrittenState = nil
        analysisWrittenSection = nil
        clearSelectionWrite()
        entries.removeAll { $0.state == nil || $0.state === state }
    }

    var activeState: ACTACanvasFilterState? {
        let states = entries.compactMap(\.state)
        return states.count == 1 ? states.first : nil
    }

    func recordWrite(to state: ACTACanvasFilterState) {
        writtenState = state
    }

    var writtenActiveState: ACTACanvasFilterState? {
        guard let state = activeState, state === writtenState else { return nil }
        return state
    }

    func recordArrangeWrite(to state: ACTACanvasFilterState) {
        arrangeWrittenState = state
    }

    var arrangeWrittenActiveState: ACTACanvasFilterState? {
        guard let state = activeState, state === arrangeWrittenState else { return nil }
        return state
    }

    func recordPresentationWrite(to state: ACTACanvasFilterState) {
        presentationWrittenState = state
    }

    var presentationWrittenActiveState: ACTACanvasFilterState? {
        guard let state = activeState, state === presentationWrittenState else { return nil }
        return state
    }

    func recordAnalysisWrite(to state: ACTACanvasFilterState, section: VLMPanelSection) {
        analysisWrittenState = state
        analysisWrittenSection = section
    }

    func verifiesAnalysisSection(_ section: VLMPanelSection) -> Bool {
        guard let state = activeState, state === analysisWrittenState else { return false }
        return analysisWrittenSection == section && state.analysisSection == section
    }

    private func clearSelectionWrite() {
        selectionWrittenState = nil
        selectionInventory = nil
        selectionValue = nil
    }

    func recordSelectionWrite(to state: ACTACanvasFilterState, inventory: Set<UUID>, selection: Set<UUID>) {
        selectionWrittenState = state
        selectionInventory = inventory
        selectionValue = selection
    }

    func verifiesSelection(inventory: Set<UUID>, selection: Set<UUID>) -> Bool {
        guard let state = activeState, state === selectionWrittenState else { return false }
        return selectionInventory == inventory && selectionValue == selection && state.selectedCameraIDs == selection
    }
}

struct ACTACanvasSetFilterAction: ACTAActionProtocol {
    let id = "canvas.set_filter"
    let title = "Set camera canvas filters"
    let description = "Update only supplied filters in the unique attached security center, even if another section is visible. Search matches camera name and location; events means stored VLM alerts or ISAPI events, not live events. Location names must match an enabled camera group; an empty location clears it. Camera-picker selection is unchanged. Verification checks GUI state, not rendering or camera connectivity."
    let classification = ACTAActionClassification.reversible
    let parameters = [
        ACTAActionParameterSchema(name: "search", type: "string", description: "Exact search text; empty clears search", allowsEmpty: true),
        ACTAActionParameterSchema(name: "location", type: "string", description: "Exact enabled camera location group; empty selects all locations", allowsEmpty: true),
        ACTAActionParameterSchema(name: "status", type: "string", description: "Camera status", allowedValues: ["all", "live", "offline"]),
        ACTAActionParameterSchema(name: "favorites_only", type: "boolean", description: "Show only favorite cameras"),
        ACTAActionParameterSchema(name: "events_only", type: "boolean", description: "Show only cameras with stored VLM alerts or ISAPI events")
    ]
    let bridge: ACTACanvasFilterBridge
    let locationGroups: @MainActor @Sendable () -> Set<String>?

    private func parsed(_ parameters: [String: String]) throws -> (String?, String?, ACTACameraScope?, Bool?, Bool?) {
        guard !parameters.isEmpty, Set(parameters.keys).isSubset(of: ["search", "location", "status", "favorites_only", "events_only"]),
              parameters["search"].map({ $0.utf8.count <= 4096 }) ?? true,
              parameters["location"].map({ value in
                  let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                  return value.utf8.count <= 4096 && (value.isEmpty || (!trimmed.isEmpty && value == trimmed && value != "All Locations"))
              }) ?? true else {
            throw ConfigurationError.invalid("INVALID_ARGUMENT: Provide supported filters; search and location are limited to 4096 UTF-8 bytes.")
        }
        let status: ACTACameraScope?
        switch parameters["status"] {
        case nil: status = nil
        case "all": status = .all
        case "live": status = .live
        case "offline": status = .offline
        default: throw ConfigurationError.invalid("INVALID_ARGUMENT: Invalid status.")
        }
        func boolean(_ key: String) throws -> Bool? {
            switch parameters[key] {
            case nil: return nil
            case "true": return true
            case "false": return false
            default: throw ConfigurationError.invalid("INVALID_ARGUMENT: Invalid \(key).")
            }
        }
        return (parameters["search"], parameters["location"], status, try boolean("favorites_only"), try boolean("events_only"))
    }

    func validate(parameters: [String: String]) throws {
        _ = try parsed(parameters)
    }

    func execute(parameters: [String: String], context: ACTAActionContext) async throws -> ACTAActionResult {
        let (search, location, status, favorites, events) = try parsed(parameters)
        return try await MainActor.run {
            try Task.checkCancellation()
            guard let state = bridge.activeState else {
                return .failed(actionID: id, error: "UNAVAILABLE: No unique active camera view.")
            }
            if let location, !location.isEmpty {
                guard let groups = locationGroups() else {
                    return .failed(actionID: id, error: "UNAVAILABLE: Camera location inventory is unavailable.")
                }
                guard groups.contains(location) else {
                    return .failed(actionID: id, error: "INVALID_ARGUMENT: Location is not an enabled camera group.")
                }
            }
            if let search { state.searchText = search }
            if let location { state.locationFilter = location.isEmpty ? nil : location }
            if let status { state.cameraScope = status }
            if let favorites { state.favoritesOnly = favorites }
            if let events { state.alertsOnly = events }
            bridge.recordWrite(to: state)
            guard matches(state, search: search, location: location, status: status, favorites: favorites, events: events) else {
                return .failed(actionID: id, error: "Camera filter state readback failed.")
            }
            return ACTAActionResult(actionID: id, success: true,
                summary: "Camera view filter state updated; rendering and camera connectivity were not verified.",
                outputJSON: "{}")
        }
    }

    func verify(parameters: [String: String], context: ACTAActionContext) async throws -> Bool {
        let (search, location, status, favorites, events) = try parsed(parameters)
        return await MainActor.run {
            guard let state = bridge.writtenActiveState else { return false }
            if let location, !location.isEmpty {
                guard let groups = locationGroups(), groups.contains(location) else { return false }
            }
            return matches(state, search: search, location: location, status: status, favorites: favorites, events: events)
        }
    }

    @MainActor
    private func matches(_ state: ACTACanvasFilterState, search: String?, location: String?, status: ACTACameraScope?,
                         favorites: Bool?, events: Bool?) -> Bool {
        (search == nil || state.searchText == search)
            && (location == nil || state.locationFilter == (location == "" ? nil : location))
            && (status == nil || state.cameraScope == status)
            && (favorites == nil || state.favoritesOnly == favorites)
            && (events == nil || state.alertsOnly == events)
    }
}

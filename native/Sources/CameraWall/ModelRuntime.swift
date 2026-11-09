import Foundation
import Combine

enum LocalModelService: String, CaseIterable, Identifiable, Sendable {
    case yolo, segmentation, personReID, vehicleReID, qwen

    var id: String { rawValue }

    var title: String {
        switch self {
        case .yolo: return "YOLO26n"
        case .segmentation: return "Segmentation"
        case .personReID: return "Person ReID"
        case .vehicleReID: return "Vehicle ReID"
        case .qwen: return "Qwen"
        }
    }
}

enum LocalModelState: Equatable, Sendable {
    case waiting
    case loading
    case ready
    case failed(String)

    var label: String {
        switch self {
        case .waiting: return "Waiting"
        case .loading: return "Loading"
        case .ready: return "Ready"
        case .failed: return "Error"
        }
    }
}

@MainActor
final class LocalModelRuntime: ObservableObject {
    typealias Loader = @Sendable (LocalModelService, String) async throws -> Void

    @Published private(set) var states: [LocalModelService: LocalModelState] = Dictionary(
        uniqueKeysWithValues: LocalModelService.allCases.map { ($0, .waiting) }
    )
    @Published private(set) var qwenModelPath = ""
    private let load: Loader
    private var preparation: Task<Void, Never>?
    private var generation = UUID()

    init(load: @escaping Loader) {
        self.load = load
    }

    @discardableResult
    func start(modelPath: String) -> Task<Void, Never> {
        if let preparation, qwenModelPath == modelPath { return preparation }
        if qwenModelPath != modelPath {
            cancel()
            qwenModelPath = modelPath
            states[.qwen] = .waiting
        }
        let token = UUID()
        generation = token
        let load = load
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == token { self.preparation = nil } }
            for service in LocalModelService.allCases {
                guard !Task.isCancelled, self.generation == token else { return }
                guard self.states[service] != .ready else { continue }
                self.states[service] = .loading
                do {
                    try await load(service, modelPath)
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    self.states[service] = .ready
                } catch is CancellationError {
                    if self.generation == token { self.states[service] = .waiting }
                    return
                } catch {
                    guard self.generation == token else { return }
                    self.states[service] = .failed(error.localizedDescription)
                }
            }
        }
        preparation = task
        return task
    }

    func cancel() {
        generation = UUID()
        preparation?.cancel()
        preparation = nil
        for service in LocalModelService.allCases where states[service] == .loading {
            states[service] = .waiting
        }
    }
}
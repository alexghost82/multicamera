import Foundation

// Shared across canvas windows. A gesture remains active until its commit or
// cancellation completes, even if it has not moved yet.
@MainActor
final class ACTACanvasGestureTracker {
    static let shared = ACTACanvasGestureTracker()
    private var active: Set<UUID> = []

    var hasActiveGestures: Bool { !active.isEmpty }

    func begin() -> UUID {
        let token = UUID()
        active.insert(token)
        return token
    }

    func end(_ token: UUID) {
        active.remove(token)
    }
}

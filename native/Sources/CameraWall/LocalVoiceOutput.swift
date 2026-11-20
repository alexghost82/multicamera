import Combine
import Darwin
import Foundation

@MainActor
protocol LocalVoiceOutputProcess: AnyObject {
    func stop()
}

enum LocalVoiceReviewStatus {
    static func message(verified: Bool, operationID: UUID, localeIdentifier: String) -> String {
        message(outcome: verified ? .executedVerified : .executedUnverified,
                operationID: operationID, localeIdentifier: localeIdentifier)
    }

    static func message(outcome: LocalVoiceReviewOutcome, operationID: UUID, localeIdentifier: String) -> String {
        let id = operationID.uuidString
        switch Locale(identifier: localeIdentifier).language.languageCode?.identifier {
        case "ru":
            switch outcome {
            case .executedVerified:
                return "Действие выполнено и проверено. Идентификатор операции: \(id)."
            case .executedUnverified:
                return "Результат действия не подтверждён. Идентификатор операции: \(id)."
            case .rejected:
                return "Действие отклонено оператором. Идентификатор операции: \(id)."
            case .failed:
                return "Выполнение действия завершилось ошибкой. Идентификатор операции: \(id)."
            }
        case "he":
            switch outcome {
            case .executedVerified:
                return "הפעולה בוצעה ואומתה. מזהה הפעולה: \(id)."
            case .executedUnverified:
                return "תוצאת הפעולה לא אומתה. מזהה הפעולה: \(id)."
            case .rejected:
                return "הפעולה נדחתה על ידי המפעיל. מזהה הפעולה: \(id)."
            case .failed:
                return "ביצוע הפעולה נכשל. מזהה הפעולה: \(id)."
            }
        default:
            switch outcome {
            case .executedVerified:
                return "Action completed and verified. Operation ID: \(id)."
            case .executedUnverified:
                return "Action result was not verified. Operation ID: \(id)."
            case .rejected:
                return "Action rejected by operator. Operation ID: \(id)."
            case .failed:
                return "Action execution failed. Operation ID: \(id)."
            }
        }
    }

    /// Safe spoken prompt announcing a pending operator review without reading sensitive parameter values.
    static func promptAnnouncement(actionID: String, operationID: UUID, localeIdentifier: String) -> String {
        let shortID = String(operationID.uuidString.prefix(8))
        let safeAction = actionID.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "_", with: " ")
        switch Locale(identifier: localeIdentifier).language.languageCode?.identifier {
        case "ru":
            return "Требуется подтверждение действия \(safeAction). Код операции \(shortID). Проверьте параметры на экране."
        case "he":
            return "נדרש אישור מפעיל לפעולה \(safeAction). מזהה פעולה \(shortID). בדוק את הפרטים על המסך."
        default:
            return "Operator confirmation required for \(safeAction). Operation \(shortID). Review full details on screen."
        }
    }
}

@MainActor
final class LocalVoiceOutput: ObservableObject {
    static let shared = LocalVoiceOutput(acquireAudioLease: { try LocalVoiceAudioLease.acquire() },
        startProcessWithLease: { text, voice, lease, completion in
            try ESpeakVoiceOutputProcess(text: text, voice: voice, audioLease: lease, completion: completion)
        })

    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    private var owner: UUID?
    private var attempt: UUID?
    private var stopping = false
    private var process: (any LocalVoiceOutputProcess)?
    private var audioLease: LocalVoiceAudioLease?
    private var transitioning = false
    private var pendingTransitions: [() -> Void] = []
    private var idleWaiters: [@MainActor () -> Void] = []
    private var pendingReplacement: (token: UUID, text: String, localeIdentifier: String, owner: UUID)?
    private let startProcess: @MainActor (String, String, LocalVoiceAudioLease?, @escaping @MainActor (String?) -> Void) throws -> any LocalVoiceOutputProcess
    private let acquireAudioLease: @MainActor () throws -> LocalVoiceAudioLease?

    convenience init(startProcess: @escaping @MainActor (String, String, @escaping @MainActor (String?) -> Void) throws -> any LocalVoiceOutputProcess = {
        try ESpeakVoiceOutputProcess(text: $0, voice: $1, completion: $2)
    }) {
        self.init(acquireAudioLease: { nil }, startProcess: startProcess)
    }

    init(acquireAudioLease: @escaping @MainActor () throws -> LocalVoiceAudioLease?,
         startProcess: @escaping @MainActor (String, String, @escaping @MainActor (String?) -> Void) throws -> any LocalVoiceOutputProcess = {
        try ESpeakVoiceOutputProcess(text: $0, voice: $1, completion: $2)
    }) {
        self.startProcess = { text, voice, _, completion in try startProcess(text, voice, completion) }
        self.acquireAudioLease = acquireAudioLease
    }

    private init(acquireAudioLease: @escaping @MainActor () throws -> LocalVoiceAudioLease?,
                 startProcessWithLease: @escaping @MainActor (String, String, LocalVoiceAudioLease?, @escaping @MainActor (String?) -> Void) throws -> any LocalVoiceOutputProcess) {
        self.startProcess = startProcessWithLease
        self.acquireAudioLease = acquireAudioLease
    }

    var isAttemptActive: Bool { attempt != nil }
    func isOwned(by owner: UUID) -> Bool { self.owner == owner && attempt != nil }

    func speak(_ text: String, localeIdentifier: String, owner: UUID) {
        guard !transitioning, attempt == nil else { return }
        transition {
            self.pendingReplacement = nil
            self.startSpeech(text, localeIdentifier: localeIdentifier, owner: owner)
        }
    }

    /// Interrupts any active speech output and starts speaking `text` as soon as the prior process exits
    /// and releases `LocalVoiceAudioLease`.
    func interruptAndSpeak(_ text: String, localeIdentifier: String, owner: UUID) {
        transition {
            if self.attempt == nil {
                self.pendingReplacement = nil
                self.startSpeech(text, localeIdentifier: localeIdentifier, owner: owner)
                return
            }
            let token = UUID()
            self.pendingReplacement = (token, text, localeIdentifier, owner)
            self.stopActiveAttempt()
        }
    }

    /// Stops any active speech output and invokes `completion` once the child exits and releases the audio lease.
    /// If already idle, invokes `completion` immediately.
    func stopAndNotifyWhenIdle(_ completion: @escaping @MainActor () -> Void) {
        transition {
            self.pendingReplacement = nil
            if self.attempt == nil {
                completion()
                return
            }
            self.idleWaiters.append(completion)
            self.stopActiveAttempt()
        }
    }

    private func startSpeech(_ text: String, localeIdentifier: String, owner: UUID) {
        errorMessage = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 8_000 else {
            errorMessage = "Speech requires non-empty text of at most 8000 UTF-8 bytes."
            return
        }
        let voice: String
        switch Locale(identifier: localeIdentifier).language.languageCode?.identifier {
        case "en": voice = "en-us"
        case "ru": voice = "ru"
        case "he": voice = "he"
        default:
            errorMessage = "Speech is unavailable for this language."
            return
        }
        do {
            audioLease = try acquireAudioLease()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let id = UUID()
        attempt = id
        self.owner = owner
        stopping = false
        isBusy = true
        do {
            let started = try startProcess(trimmed, voice, audioLease) { [weak self] error in
                self?.finished(id, error: error)
            }
            if attempt == id {
                process = started
                if stopping { started.stop() }
            } else {
                started.stop()
            }
        } catch {
            finished(id, error: "Local speech could not be started: \(error.localizedDescription)")
        }
    }

    func stop(owner: UUID) {
        transition {
            if self.pendingReplacement?.owner == owner { self.pendingReplacement = nil }
            guard self.owner == owner else { return }
            self.stopActiveAttempt()
        }
    }

    func stopAll() {
        transition {
            self.pendingReplacement = nil
            self.stopActiveAttempt()
        }
    }

    private func stopActiveAttempt() {
        guard attempt != nil, !stopping else { return }
        stopping = true
        process?.stop()
    }

    private func finished(_ id: UUID, error: String?) {
        transition {
            guard self.attempt == id else { return }
            if !self.stopping { self.errorMessage = error }
            self.attempt = nil
            self.owner = nil
            self.process = nil
            self.audioLease = nil
            self.stopping = false
            self.isBusy = false
            let waiters = self.idleWaiters
            self.idleWaiters = []
            for waiter in waiters {
                waiter()
            }
            if self.attempt == nil, let replacement = self.pendingReplacement {
                self.pendingReplacement = nil
                self.startSpeech(replacement.text, localeIdentifier: replacement.localeIdentifier, owner: replacement.owner)
            }
        }
    }

    private func transition(_ operation: @escaping () -> Void) {
        if transitioning {
            pendingTransitions.append(operation)
            return
        }
        transitioning = true
        operation()
        while !pendingTransitions.isEmpty {
            pendingTransitions.removeFirst()()
        }
        transitioning = false
    }
}

@MainActor
final class ESpeakVoiceOutputProcess: LocalVoiceOutputProcess {
    static let sandboxProfile = "(version 1) (allow default) (deny network*)"
    private let process: Process

    init(text: String, voice: String, renderWithoutPlayback: Bool = false, audioLease: LocalVoiceAudioLease? = nil,
         completion: @escaping @MainActor (String?) -> Void) throws {
        let candidates = ["/opt/homebrew/bin/espeak-ng", "/usr/local/bin/espeak-ng"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw VoiceOutputError.engineUnavailable
        }
        let process = Process()
        let input = Pipe()
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else {
            throw VoiceOutputError.pipeUnavailable
        }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.sandboxProfile,
                             executable, "-v", voice, "--stdin"] + (renderWithoutPlayback ? ["--stdout"] : [])
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        let childLease = try audioLease?.duplicateForChild()
        process.standardError = childLease ?? FileHandle.nullDevice
        try process.run()
        do {
            try childLease?.close()
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            throw error
        }
        self.process = process
        let data = Data(text.utf8)
        DispatchQueue.global(qos: .userInitiated).async {
            var inputError: String?
            do {
                try input.fileHandleForWriting.write(contentsOf: data)
                try input.fileHandleForWriting.close()
            } catch {
                inputError = "Local speech input failed: \(error.localizedDescription)"
                try? input.fileHandleForWriting.close()
            }
            process.waitUntilExit()
            let result = inputError ?? (process.terminationStatus == 0 ? nil : "Local speech synthesis failed.")
            Task { @MainActor in completion(result) }
        }
    }

    func stop() {
        if process.isRunning { process.terminate() }
    }
}

private enum VoiceOutputError: LocalizedError {
    case engineUnavailable, pipeUnavailable

    var errorDescription: String? {
        switch self {
        case .engineUnavailable: return "eSpeak NG is not installed."
        case .pipeUnavailable: return "The local speech input pipe could not be secured."
        }
    }
}

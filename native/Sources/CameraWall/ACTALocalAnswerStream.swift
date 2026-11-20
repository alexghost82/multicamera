import CameraCore
import Foundation

final class ACTAStreamPreviewSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var revision = 0
    private var step = 0
    private var lastStepRevision = 0
    private let onPreview: @Sendable (String, Int) -> Void

    init(onPreview: @escaping @Sendable (String, Int) -> Void) {
        self.onPreview = onPreview
    }

    func beginStep() -> @Sendable (String, Int) -> Void {
        lock.lock()
        step += 1
        let currentStep = step
        lastStepRevision = 0
        revision += 1
        let clearRevision = revision
        lock.unlock()
        onPreview("", clearRevision)
        return { [self] text, stepRevision in
            lock.lock()
            guard step == currentStep, stepRevision > lastStepRevision else {
                lock.unlock()
                return
            }
            lastStepRevision = stepRevision
            revision += 1
            let currentRevision = revision
            lock.unlock()
            onPreview(text, currentRevision)
        }
    }

    func endStep() {
        lock.lock()
        step += 1
        revision += 1
        let clearRevision = revision
        lock.unlock()
        onPreview("", clearRevision)
    }
}

/// Extracts only a final-answer field from an incomplete JSON response.
final class ACTALocalAnswerStream: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes: [UInt8] = []
    private var lastEmission: TimeInterval = 0
    private var lastText = ""
    private var revision = 0
    private var discarded = false
    private let onPreview: @Sendable (String, Int) -> Void

    init(onPreview: @escaping @Sendable (String, Int) -> Void) {
        self.onPreview = onPreview
    }

    func close() {
        lock.lock()
        discarded = true
        lastText = ""
        lock.unlock()
    }

    func append(_ chunk: String) {
        lock.lock()
        guard !discarded else { lock.unlock(); return }
        if bytes.count + chunk.utf8.count > 65_536 { discarded = true }
        else { bytes.append(contentsOf: chunk.utf8) }
        let now = ProcessInfo.processInfo.systemUptime
        let sanitized = !discarded ? Self.extract(bytes).map(ACTAOpSec.sanitizeText) : nil
        guard let text = sanitized, !text.isEmpty else {
            guard !lastText.isEmpty else { lock.unlock(); return }
            lastText = ""
            revision += 1
            let currentRevision = revision
            lock.unlock()
            onPreview("", currentRevision)
            return
        }
        guard now - lastEmission >= 0.12 else { lock.unlock(); return }
        guard text != lastText else { lock.unlock(); return }
        lastText = text
        lastEmission = now
        revision += 1
        let currentRevision = revision
        lock.unlock()
        onPreview(text, currentRevision)
    }

    static func extract(_ bytes: [UInt8]) -> String? {
        if let terminal = extractTerminalAnswer(bytes) { return terminal }
        var index = 0
        func whitespace() {
            while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
        }
        func stringEnd(from start: Int) -> Int? {
            var i = start + 1
            var escaped = false
            while i < bytes.count {
                let byte = bytes[i]
                if escaped { escaped = false }
                else if byte == 92 { escaped = true }
                else if byte == 34 { return i }
                i += 1
            }
            return nil
        }
        func decodeString(_ start: Int, _ end: Int) -> String? {
            try? JSONDecoder().decode(String.self, from: Data(bytes[start...end]))
        }
        whitespace()
        guard index < bytes.count, bytes[index] == 123 else { return nil }
        index += 1
        while true {
            whitespace()
            guard index < bytes.count, bytes[index] == 34,
                  let keyEnd = stringEnd(from: index),
                  let key = decodeString(index, keyEnd) else { return nil }
            index = keyEnd + 1
            whitespace()
            guard index < bytes.count, bytes[index] == 58 else { return nil }
            index += 1
            whitespace()
            guard index < bytes.count else { return nil }
            if key == "answerMarkdown" {
                guard bytes[index] == 34 else { return nil }
                if let end = stringEnd(from: index) { return decodeString(index, end) }
                let start = index
                var end = bytes.count
                while end > start && bytes.count - end <= 12 {
                    var partial = Array(bytes[start..<end])
                    partial.append(34)
                    if let text = try? JSONDecoder().decode(String.self, from: Data(partial)) { return text }
                    end -= 1
                }
                return nil
            }
            var depth = 0
            var inString = false
            var escaped = false
            while index < bytes.count {
                let byte = bytes[index]
                if inString {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { inString = false }
                } else if byte == 34 {
                    inString = true
                } else if byte == 123 || byte == 91 {
                    depth += 1
                } else if byte == 125 || byte == 93 {
                    if depth == 0 { return nil }
                    depth -= 1
                } else if byte == 44 && depth == 0 {
                    index += 1
                    break
                }
                index += 1
            }
            if index >= bytes.count { return nil }
        }
    }

    private static func extractTerminalAnswer(_ bytes: [UInt8]) -> String? {
        for removed in 0...min(12, bytes.count) {
            let prefix = bytes.dropLast(removed)
            var stack: [UInt8] = []
            var inString = false
            var escaped = false
            var valid = true
            for byte in prefix {
                if inString {
                    if escaped { escaped = false }
                    else if byte == 92 { escaped = true }
                    else if byte == 34 { inString = false }
                } else if byte == 34 {
                    inString = true
                } else if byte == 123 || byte == 91 {
                    stack.append(byte)
                } else if byte == 125 || byte == 93 {
                    guard let opening = stack.popLast(),
                          (opening == 123 && byte == 125) || (opening == 91 && byte == 93) else {
                        valid = false
                        break
                    }
                }
            }
            guard valid else { return nil }
            if escaped { continue }
            var candidate = Array(prefix)
            if inString { candidate.append(34) }
            candidate.append(contentsOf: stack.reversed().map { $0 == 123 ? 125 : 93 })
            guard let parsed = try? JSONSerialization.jsonObject(with: Data(candidate)) else {
                if inString { continue }
                return nil
            }
            guard let object = parsed as? [String: Any],
                  let calls = object["tool_calls"] as? [[String: Any]], calls.count == 1,
                  let call = calls.first, (call["name"] as? String ?? call["tool"] as? String) == "present_answer",
                  let arguments = (call["arguments"] ?? call["args"]) as? [String: Any],
                  let answer = arguments["answerMarkdown"] as? String else { return nil }
            return answer
        }
        return nil
    }
}

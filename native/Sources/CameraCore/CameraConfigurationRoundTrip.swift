import Foundation

/// Compares the original JSON with the encoded configuration without losing
/// duplicate keys or rounding JSON numbers through floating-point parsing.
enum CameraConfigurationRoundTrip {
    static func preservesFields(original: Data, encoded: Data) -> Bool {
        do {
            var sourceParser = Parser(original)
            var encodedParser = Parser(encoded)
            return includes(try sourceParser.parse(), try encodedParser.parse(), path: [])
        } catch {
            return false
        }
    }

    private static let nullableCameraFields: Set<String> = [
        "location", "mainstream", "localDeviceID", "screenDisplayID", "fileURL", "fileBookmarkData"
    ]

    private static func includes(_ source: Value, _ encoded: Value, path: [String]) -> Bool {
        switch (source, encoded) {
        case let (.object(before), .object(after)):
            for (key, value) in before {
                if let replacement = after[key] {
                    guard includes(value, replacement, path: path + [key]) else { return false }
                } else if path == ["cameras", "*"], nullableCameraFields.contains(key), value == .null {
                    continue
                } else {
                    return false
                }
            }
            return true
        case let (.array(before), .array(after)):
            guard before.count == after.count else { return false }
            return zip(before, after).allSatisfy { includes($0, $1, path: path + ["*"]) }
        case let (.string(before), .string(after)):
            if path == ["cameras", "*", "id"], let first = UUID(uuidString: before),
               let second = UUID(uuidString: after) {
                return first == second
            }
            return before.utf8.elementsEqual(after.utf8)
        default:
            return source == encoded
        }
    }

    private indirect enum Value: Equatable {
        case object([String: Value])
        case array([Value])
        case string(String)
        case number(Number)
        case boolean(Bool)
        case null
    }

    private struct Number: Equatable {
        let negative: Bool
        let digits: String
        let exponent: Int
    }

    private struct InvalidJSON: Error {}

    private struct Parser {
        private let bytes: [UInt8]
        private var position = 0

        init(_ data: Data) { bytes = Array(data) }

        mutating func parse() throws -> Value {
            guard bytes.count <= 4_000_000 else { throw InvalidJSON() }
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { position = 3 }
            let result = try value(depth: 0)
            whitespace()
            guard position == bytes.count else { throw InvalidJSON() }
            return result
        }

        private mutating func value(depth: Int) throws -> Value {
            guard depth <= 128 else { throw InvalidJSON() }
            whitespace()
            guard position < bytes.count else { throw InvalidJSON() }
            switch bytes[position] {
            case 123: return try object(depth: depth + 1)
            case 91: return try array(depth: depth + 1)
            case 34: return .string(try string())
            case 116: try literal("true"); return .boolean(true)
            case 102: try literal("false"); return .boolean(false)
            case 110: try literal("null"); return .null
            case 45, 48...57: return .number(try number())
            default: throw InvalidJSON()
            }
        }

        private mutating func object(depth: Int) throws -> Value {
            position += 1
            whitespace()
            var result: [String: Value] = [:]
            if consume(125) { return .object(result) }
            while true {
                whitespace()
                let key = try string()
                guard result[key] == nil else { throw InvalidJSON() }
                whitespace()
                guard consume(58) else { throw InvalidJSON() }
                result[key] = try value(depth: depth)
                whitespace()
                if consume(125) { return .object(result) }
                guard consume(44) else { throw InvalidJSON() }
            }
        }

        private mutating func array(depth: Int) throws -> Value {
            position += 1
            whitespace()
            var result: [Value] = []
            if consume(93) { return .array(result) }
            while true {
                result.append(try value(depth: depth))
                whitespace()
                if consume(93) { return .array(result) }
                guard consume(44) else { throw InvalidJSON() }
            }
        }

        private mutating func string() throws -> String {
            guard position < bytes.count, bytes[position] == 34 else { throw InvalidJSON() }
            let start = position
            position += 1
            while position < bytes.count {
                let byte = bytes[position]
                position += 1
                if byte == 34 {
                    return try JSONDecoder().decode(String.self, from: Data(bytes[start..<position]))
                }
                guard byte >= 32 else { throw InvalidJSON() }
                if byte == 92 {
                    guard position < bytes.count else { throw InvalidJSON() }
                    position += 1
                }
            }
            throw InvalidJSON()
        }

        private mutating func number() throws -> Number {
            let negative = consume(45)
            var digits: [UInt8] = []
            if consume(48) {
                digits.append(48)
                if peekDigit() { throw InvalidJSON() }
            } else {
                guard peekDigit(), bytes[position] != 48 else { throw InvalidJSON() }
                while peekDigit() { digits.append(bytes[position]); position += 1 }
            }
            var fraction = 0
            if consume(46) {
                guard peekDigit() else { throw InvalidJSON() }
                while peekDigit() {
                    digits.append(bytes[position])
                    position += 1
                    fraction += 1
                }
            }
            var exponent = 0
            if consume(101) || consume(69) {
                let negativeExponent = consume(45)
                if !negativeExponent { _ = consume(43) }
                guard peekDigit() else { throw InvalidJSON() }
                while peekDigit() {
                    guard exponent <= 10_000 else { throw InvalidJSON() }
                    exponent = exponent * 10 + Int(bytes[position] - 48)
                    position += 1
                }
                guard exponent <= 10_000 else { throw InvalidJSON() }
                if negativeExponent { exponent = -exponent }
            }
            guard digits.count <= 1024 else { throw InvalidJSON() }
            guard let first = digits.firstIndex(where: { $0 != 48 }) else {
                return Number(negative: false, digits: "0", exponent: 0)
            }
            var last = digits.count - 1
            while digits[last] == 48 { last -= 1 }
            let normalizedExponent = exponent - fraction + (digits.count - 1 - last)
            return Number(negative: negative, digits: String(decoding: digits[first...last], as: UTF8.self),
                          exponent: normalizedExponent)
        }

        private mutating func literal(_ text: StaticString) throws {
            let value = Array(String(describing: text).utf8)
            guard position + value.count <= bytes.count,
                  bytes[position..<(position + value.count)].elementsEqual(value) else { throw InvalidJSON() }
            position += value.count
        }

        private mutating func whitespace() {
            while position < bytes.count, [9, 10, 13, 32].contains(bytes[position]) { position += 1 }
        }

        private mutating func consume(_ byte: UInt8) -> Bool {
            guard position < bytes.count, bytes[position] == byte else { return false }
            position += 1
            return true
        }

        private func peekDigit() -> Bool {
            position < bytes.count && (48...57).contains(bytes[position])
        }
    }
}

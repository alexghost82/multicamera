import AppKit
import Foundation

final class InterfaceLocalization {
    private struct Template {
        let key: String
        let value: String
        let expression: NSRegularExpression
        let arguments: [Int]
    }

    private static let formatTokens = try! NSRegularExpression(pattern: #"%%|%(?:([1-9][0-9]*)\$)?[-+0-9.#]*(?:hh|ll|[hlLzjt])?([@diuoxXfFeEgGcs])"#)
    private static let english = InterfaceLocalization(language: .english)
    private static let russian = InterfaceLocalization(language: .russian)

    static func shared(for language: AppLanguage) -> InterfaceLocalization {
        language == .russian ? russian : english
    }

    static func bundle(for language: AppLanguage) -> Bundle? {
        if let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"), let bundle = Bundle(path: path) {
            return bundle
        }
        let nativeRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return Bundle(url: nativeRoot.appendingPathComponent("Resources/\(language.rawValue).lproj"))
    }

    static func configure(_ panel: NSSavePanel, title: String, language: AppLanguage) {
        panel.title = language.localized(title)
        panel.prompt = language.localized(panel is NSOpenPanel ? "Open" : "Save")
        panel.nameFieldLabel = language.localized("File name:")
    }

    private let language: AppLanguage
    private let strings: [String: String]
    private let templates: [Template]

    init(language: AppLanguage, bundle: Bundle? = nil) {
        self.language = language
        let resource = (bundle ?? Self.bundle(for: language))?.url(forResource: "Localizable", withExtension: "strings")
        if let resource, let data = try? Data(contentsOf: resource),
           let dictionary = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
            strings = dictionary
        } else {
            strings = [:]
        }
        templates = strings.compactMap { key, value in
            let source = key as NSString
            let tokens = Self.formatTokens.matches(in: key, range: NSRange(location: 0, length: source.length))
            guard tokens.contains(where: { source.substring(with: $0.range) != "%%" }) else { return nil }
            var pattern = "^"
            var offset = 0
            var arguments: [Int] = []
            var nextArgument = 0
            for token in tokens {
                pattern += NSRegularExpression.escapedPattern(for: source.substring(with: NSRange(location: offset, length: token.range.location - offset)))
                if source.substring(with: token.range) == "%%" {
                    pattern += "%"
                } else {
                    pattern += "(.+?)"
                    let position = token.range(at: 1)
                    arguments.append(position.location == NSNotFound ? nextArgument : (Int(source.substring(with: position))! - 1))
                    nextArgument += 1
                }
                offset = NSMaxRange(token.range)
            }
            pattern += NSRegularExpression.escapedPattern(for: source.substring(from: offset)) + "$"
            guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
            return Template(key: key, value: value, expression: expression, arguments: arguments)
        }.sorted { $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count > $1.key.count }
    }

    func localized(_ key: String, arguments: [CVarArg] = []) -> String {
        let format = strings[key] ?? key
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: language.locale, arguments: arguments)
    }

    func message(_ text: String) -> String {
        translate(text, depth: 0)
    }

    private func translate(_ text: String, depth: Int) -> String {
        guard !text.isEmpty, language == .russian else { return text }
        if let translated = strings[text] { return translated }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for template in templates {
            guard let match = template.expression.firstMatch(in: text, range: range) else { continue }
            var values: [String] = Array(repeating: "", count: (template.arguments.max() ?? -1) + 1)
            for (index, position) in template.arguments.enumerated() {
                let captured = (text as NSString).substring(with: match.range(at: index + 1))
                let isNestedError = template.key.localizedCaseInsensitiveContains("failed:")
                    || template.key.localizedCaseInsensitiveContains("error:")
                    || template.key.hasPrefix("Cannot load configuration.")
                let isFallMetricBlock = position == 1 && (template.key.hasPrefix("Fall confirmed after ")
                    || template.key.hasPrefix("Person remained down on floor for "))
                let isPosture = position == 0 && template.key.hasPrefix("Person in %@ posture ")
                if isFallMetricBlock && depth < 3 {
                    values[position] = captured.components(separatedBy: ", ")
                        .map { translate($0, depth: depth + 1) }.joined(separator: ", ")
                } else {
                    values[position] = (isNestedError || isPosture) && depth < 3
                        ? translate(captured, depth: depth + 1) : captured
                }
            }
            return Self.substitute(template.value, values: values)
        }
        return text
    }

    private static func substitute(_ format: String, values: [String]) -> String {
        let source = format as NSString
        let tokens = formatTokens.matches(in: format, range: NSRange(location: 0, length: source.length))
        var result = ""
        var offset = 0
        var nextArgument = 0
        for token in tokens {
            result += source.substring(with: NSRange(location: offset, length: token.range.location - offset))
            if source.substring(with: token.range) == "%%" {
                result += "%"
            } else {
                let position = token.range(at: 1)
                let index = position.location == NSNotFound ? nextArgument : (Int(source.substring(with: position))! - 1)
                result += values.indices.contains(index) ? values[index] : source.substring(with: token.range)
                nextArgument += 1
            }
            offset = NSMaxRange(token.range)
        }
        return result + source.substring(from: offset)
    }
}
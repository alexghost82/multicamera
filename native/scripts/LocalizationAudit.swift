import Foundation
import SwiftParser
import SwiftSyntax

struct UIString: Codable {
    let file: String
    let line: Int
    let context: String
    let key: String
    let interpolated: Bool
}

final class UIStringVisitor: SyntaxVisitor {
    let file: String
    let locations: SourceLocationConverter
    var strings: [UIString] = []
    private let calls: Set<String> = [
        "Text", "Button", "Toggle", "Stepper", "Label", "TextField", "SecureField",
        "Picker", "Section", "DisclosureGroup", "GroupBox", "Menu", "ContentUnavailableView",
        "LabeledContent", "LocalizedStringKey", "localized", "localizedMessage", "help",
        "accessibilityLabel", "accessibilityHint", "accessibilityValue", "navigationTitle",
        "confirmationDialog", "alert", "section", "counter", "note", "invalid", "setError",
        "pageHeading", "emptyPage", "sectionHeader", "reportMetric", "metric", "configure"
    ]

    init(file: String, tree: SourceFileSyntax) {
        self.file = file
        locations = SourceLocationConverter(fileName: file, tree: tree)
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        // Comparison operands are stored identifiers, not the labels in ternary branches.
        if let expressions = node.parent?.as(ExprListSyntax.self) {
            let elements = Array(expressions)
            if let index = elements.firstIndex(where: { $0.id == node.id }) {
                let adjacent = [index - 1, index + 1].filter { elements.indices.contains($0) }
                if adjacent.contains(where: { ["==", "!="].contains(elements[$0].trimmedDescription) }) {
                    return .skipChildren
                }
            }
        }
        var key = ""
        var interpolated = false
        for segment in node.segments {
            switch segment {
            case .stringSegment(let text): key += text.content.text
            case .expressionSegment: key += "%@"; interpolated = true
            @unknown default: fatalError("Unsupported Swift string segment; update the localization audit")
            }
        }
        if let data = "[\"\(key)\"]".data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String], let value = decoded.first {
            key = value
        }
        // Reverse-DNS service/bundle identifiers remain byte-identical across languages.
        if key.range(of: #"^[a-z0-9_-]+(?:\.[a-z0-9_-]+){2,}$"#, options: .regularExpression) != nil { return .skipChildren }
        guard key.unicodeScalars.contains(where: { (65...90).contains($0.value) || (97...122).contains($0.value) }),
              let context = context(for: Syntax(node)) else { return .skipChildren }
        strings.append(UIString(file: file, line: locations.location(for: node.positionAfterSkippingLeadingTrivia).line,
            context: context, key: key, interpolated: interpolated))
        return .skipChildren
    }

    private func context(for node: Syntax) -> String? {
        var current = node.parent
        while let ancestor = current {
            if let argument = ancestor.as(LabeledExprSyntax.self),
               ["systemImage", "symbol", "systemName", "icon"].contains(argument.label?.text ?? "") { return nil }
                if let argument = ancestor.as(LabeledExprSyntax.self), argument.label?.text == "label",
                    let call = argument.parent?.parent?.as(FunctionCallExprSyntax.self),
                    call.calledExpression.trimmedDescription == "DispatchQueue" { return nil }
                if let argument = ancestor.as(LabeledExprSyntax.self),
                    ["label", "detail", "message", "title", "subtitle"].contains(argument.label?.text ?? "") {
                     return "argument:\(argument.label!.text)"
                }
            if let call = ancestor.as(FunctionCallExprSyntax.self) {
                let name = call.calledExpression.as(DeclReferenceExprSyntax.self)?.baseName.text
                    ?? call.calledExpression.as(MemberAccessExprSyntax.self)?.declName.baseName.text
                if let name, ["accessibilityIdentifier", "anchorPreference", "CTFontCreateWithName", "NSClassFromString"].contains(name) { return nil }
                if let name, calls.contains(name) { return name }
                if let name, ["systemName", "Image", "imageNamed", "appendingPathComponent", "URL", "NSImage"].contains(name) { return nil }
            }
            if let binding = ancestor.as(PatternBindingSyntax.self) {
                let name = binding.pattern.trimmedDescription
                if ["title", "subtitle", "label", "message", "errorDescription", "notice", "status", "vlmStatus", "detectionStatus", "error", "errorMessage", "loadError", "saveError", "prompt"].contains(name) {
                    if name != "prompt" { return "property:\(name)" }
                    return nil
                }
            }
            if let assignment = ancestor.as(SequenceExprSyntax.self),
               let operation = assignment.elements.firstIndex(where: { $0.is(AssignmentExprSyntax.self) }) {
                let left = assignment.elements.prefix(upTo: operation).map(\.trimmedDescription).joined()
                if ["title", "message", "notice", "status", "error", "errorMessage", "loadError", "saveError", "vlmStatus", "detectionStatus", "prompt"].contains(where: { left == $0 || left.hasSuffix("." + $0) }) {
                    if left == "prompt" || left.hasSuffix(".prompt") { return nil }
                    return "assignment:\(left)"
                }
            }
            if ancestor.is(EnumCaseDeclSyntax.self), file.contains("View.swift") || file.contains("Panel.swift") {
                return "enum-case"
            }
            current = ancestor.parent
        }
        return nil
    }
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let directory = root.appendingPathComponent("Sources")
let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)!
var entries: [UIString] = []
for case let file as URL in files where file.pathExtension == "swift" {
    let tree = Parser.parse(source: try String(contentsOf: file, encoding: .utf8))
    let visitor = UIStringVisitor(file: file.path.replacingOccurrences(of: root.path + "/", with: ""), tree: tree)
    visitor.walk(tree)
    entries += visitor.strings
}
entries.sort { ($0.file, $0.line) < ($1.file, $1.line) }
let destination = CommandLine.arguments.dropFirst().first { !$0.hasPrefix("--") }
let output = destination.map { URL(fileURLWithPath: $0) }
    ?? root.appendingPathComponent(".build/localization-audit/strings.json")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(entries).write(to: output, options: .atomic)
print("UI string occurrences: \(entries.count); unique keys: \(Set(entries.map(\.key)).count)")
print(output.path)

if CommandLine.arguments.contains("--check") {
    let data = try Data(contentsOf: root.appendingPathComponent("Resources/ru.lproj/Localizable.strings"))
    let catalog = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: String]
    func normalized(_ key: String) -> String {
        key.replacingOccurrences(of: "%([0-9]+\\$)?[-+0-9.#]*(ll|l|z)?[diufg@]", with: "%@", options: .regularExpression)
            .replacingOccurrences(of: "%%", with: "%")
    }
    let covered = Set(catalog.keys.map(normalized))
    let missing = entries.filter { !covered.contains(normalized($0.key)) }
    for entry in missing { print("MISSING \(entry.file):\(entry.line): \(entry.key)") }
    print("Untranslated source occurrences: \(missing.count)")
    if !missing.isEmpty { exit(1) }
}

if CommandLine.arguments.contains("--check-compiled") {
    let directory = root.appendingPathComponent(".build/localization-audit/compiled")
    let catalog = try PropertyListSerialization.propertyList(
        from: Data(contentsOf: root.appendingPathComponent("Resources/ru.lproj/Localizable.strings")), format: nil) as! [String: String]
    var keys: Set<String> = []
    for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        where file.pathExtension == "stringsdata" {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
        guard let source = object["source"] as? String, source.hasPrefix(root.path + "/Sources/"),
              FileManager.default.fileExists(atPath: source),
              let tables = object["tables"] as? [String: [[String: Any]]] else { continue }
        for item in tables["Localizable"] ?? [] {
            if let key = item["key"] as? String, !key.isEmpty { keys.insert(key) }
        }
    }
    guard !keys.isEmpty else { fatalError("No compiled UI keys; run the documented compiler extraction first") }
    try JSONSerialization.data(withJSONObject: keys.sorted(), options: [.prettyPrinted, .withoutEscapingSlashes])
        .write(to: root.appendingPathComponent(".build/localization-audit/compiler-keys.json"), options: .atomic)
    let missing = keys.filter { catalog[$0]?.isEmpty != false }.sorted()
    for key in missing { print("MISSING COMPILED: \(key)") }
    print("Compiled UI keys: \(keys.count); untranslated: \(missing.count)")
    if !missing.isEmpty { exit(1) }
}
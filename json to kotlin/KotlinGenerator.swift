// KotlinGenerator.swift
// JSON to Kotlin generator ported from provided Python script
// Created by Assistant

import Foundation

// MARK: - Public API

struct KotlinGeneratorOptions {
    var rootClassName: String = "Root"
    var forceNullableNested: Bool = true
    var classMode: ClassMode = .nested
    var annotationMode: AnnotationMode = .none
    var ignoredKeys: Set<String> = []
}

enum ClassMode: String { case nested, topLevel }

enum AnnotationMode: String { case none, gson, moshi }

enum GenError: Error, LocalizedError {
    case emptyInput
    case invalidTopLevel

    var errorDescription: String? {
        switch self {
        case .emptyInput: return "JSON input is empty"
        case .invalidTopLevel: return "Top-level JSON must be an object or array"
        }
    }
}

struct KotlinGenerator {
    // Entry point
    static func generate(jsonText: String, options: KotlinGeneratorOptions) throws -> String {
        let trimmed = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw GenError.emptyInput }
        let normalized = normalizeSmartQuotes(in: trimmed)

        // Validate JSON first to preserve useful Foundation parse errors.
        let data = Data(normalized.utf8)
        _ = try JSONSerialization.jsonObject(with: data, options: [])
        var parser = OrderedJSONParser(text: normalized)
        let json = try parser.parse()

        // If array, wrap as {"items": [...]}
        let top: JSONValue
        if case let .array(arr) = json {
            top = .object([("items", .array(arr))])
        } else {
            top = json
        }
        guard case .object = top else { throw GenError.invalidTopLevel }

        // Remove ignored keys
        let cleaned = removeIgnoredKeys(top, ignored: options.ignoredKeys)

        // Infer types
        let inferred = inferType(from: cleaned)

        // Build class tree
        let rootInput = options.rootClassName.trimmingCharacters(in: .whitespacesAndNewlines)
        let rootName = toPascalCase(rootInput.isEmpty ? "RootResponse" : rootInput)
        var usedGlobal: Set<String> = [rootName]
        let rootClass = buildClassDef(className: rootName, node: inferred, rootName: rootName, isRoot: true, classMode: options.classMode, globalUsedNames: &usedGlobal)

        // Render
        let lines: [String]
        switch options.classMode {
        case .nested:
            lines = renderClassDef(rootClass, indentDepth: 0, nullableDepth: 0, forceNullableNested: options.forceNullableNested, annotationMode: options.annotationMode, inlineNested: true)
        case .topLevel:
            let entries = collectClassEntries(rootClass)
            var acc: [String] = []
            for (idx, entry) in entries.enumerated() {
                acc.append(contentsOf: renderClassDef(entry.classDef, indentDepth: 0, nullableDepth: entry.depth, forceNullableNested: options.forceNullableNested, annotationMode: options.annotationMode, inlineNested: false))
                if idx < entries.count - 1 { acc.append("") }
            }
            lines = acc
        }

        var imports: [String] = []
        switch options.annotationMode {
        case .gson: imports.append("import com.google.gson.annotations.SerializedName")
        case .moshi: imports.append("import com.squareup.moshi.Json")
        case .none: break
        }

        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        if imports.isEmpty { return body }
        return imports.joined(separator: "\n") + "\n\n" + body
    }
}

private func normalizeSmartQuotes(in text: String) -> String {
    var normalized = text
    let replacements: [(String, String)] = [
        ("\u{201C}", "\""), // left double quotation mark
        ("\u{201D}", "\""), // right double quotation mark
        ("\u{201E}", "\""), // double low-9 quotation mark
        ("\u{201F}", "\""), // double high-reversed-9 quotation mark
        ("\u{00AB}", "\""), // left-pointing guillemet
        ("\u{00BB}", "\""), // right-pointing guillemet
        ("\u{FF02}", "\""), // full-width quotation mark
        ("\u{2018}", "'"),
        ("\u{2019}", "'"),
        ("\u{FF07}", "'")
    ]

    for (from, to) in replacements {
        normalized = normalized.replacingOccurrences(of: from, with: to)
    }
    return normalized
}

// MARK: - Name helpers

private let kotlinKeywords: Set<String> = [
    "as","break","class","continue","do","else","false","for","fun","if","in","interface","is","null","object","package","return","super","this","throw","true","try","typealias","typeof","val","var","when","while"
]

private func toPascalCase(_ text: String) -> String {
    let parts = text.split(whereSeparator: { !($0.isLetter || $0.isNumber) })
    let cleaned = parts.map { String($0) }.filter { !$0.isEmpty }
    guard !cleaned.isEmpty else { return "Generated" }
    var value = cleaned.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
    if value.first?.isNumber == true { value = "N" + value }
    return value
}

private func toSafePropertyName(_ name: String) -> String {
    guard !name.isEmpty else { return "value" }
    let regex = try! NSRegularExpression(pattern: "^[A-Za-z_][A-Za-z0-9_]*$")
    let range = NSRange(location: 0, length: name.utf16.count)
    if regex.firstMatch(in: name, options: [], range: range) != nil && !kotlinKeywords.contains(name) {
        return name
    }
    let escaped = name.replacingOccurrences(of: "`", with: "")
    return "`" + escaped + "`"
}

private func singularize(_ word: String) -> String {
    guard !word.isEmpty else { return "Item" }
    let lower = word.lowercased()
    if lower == "data" { return "DataItem" }
    if lower.hasSuffix("ies"), word.count > 3 { return String(word.dropLast(3)) + "y" }
    if lower.hasSuffix("ses"), word.count > 3 { return String(word.dropLast(2)) }
    if lower.hasSuffix("s"), !lower.hasSuffix("ss"), word.count > 1 { return String(word.dropLast()) }
    return word
}

private func uniqueName(_ name: String, used: inout Set<String>) -> String {
    let base = name
    var candidate = base
    var counter = 2
    while used.contains(candidate) {
        candidate = base + String(counter)
        counter += 1
    }
    used.insert(candidate)
    return candidate
}

private func listItemClassName(fieldName: String, parentName: String, rootName: String, isRoot: Bool) -> String {
    if isRoot && fieldName == "data" && rootName.hasSuffix("Response") {
        let suffix = String(rootName.dropLast("Response".count))
        return suffix.isEmpty ? "Item" : suffix
    }
    let singular = singularize(fieldName)
    if ["data","item","items","list"].contains(singular.lowercased()) {
        return parentName + "Item"
    }
    return toPascalCase(singular)
}

// MARK: - Type system

enum JSONValue {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null
}

private struct OrderedJSONParser {
    private let chars: [Character]
    private var index: Int = 0

    init(text: String) {
        self.chars = Array(text)
    }

    mutating func parse() throws -> JSONValue {
        skipWhitespace()
        let value = try parseValue()
        skipWhitespace()
        guard isAtEnd else {
            throw NSError(domain: "OrderedJSONParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON"])
        }
        return value
    }

    private var isAtEnd: Bool { index >= chars.count }

    private mutating func skipWhitespace() {
        while !isAtEnd, chars[index].isWhitespace {
            index += 1
        }
    }

    private mutating func parseValue() throws -> JSONValue {
        guard !isAtEnd else {
            throw NSError(domain: "OrderedJSONParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unexpected end of JSON input"])
        }
        switch chars[index] {
        case "{":
            return try parseObject()
        case "[":
            return try parseArray()
        case "\"":
            return .string(try parseString())
        case "t":
            try consumeLiteral("true")
            return .bool(true)
        case "f":
            try consumeLiteral("false")
            return .bool(false)
        case "n":
            try consumeLiteral("null")
            return .null
        case "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return .number(try parseNumber())
        default:
            throw NSError(domain: "OrderedJSONParser", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON value"])
        }
    }

    private mutating func parseObject() throws -> JSONValue {
        try consume("{")
        skipWhitespace()
        var items: [(String, JSONValue)] = []
        if try consumeIf("}") {
            return .object(items)
        }

        while true {
            skipWhitespace()
            let key = try parseString()
            skipWhitespace()
            try consume(":")
            skipWhitespace()
            let value = try parseValue()
            items.append((key, value))
            skipWhitespace()

            if try consumeIf("}") {
                break
            }
            try consume(",")
        }

        return .object(items)
    }

    private mutating func parseArray() throws -> JSONValue {
        try consume("[")
        skipWhitespace()
        var values: [JSONValue] = []
        if try consumeIf("]") {
            return .array(values)
        }

        while true {
            skipWhitespace()
            values.append(try parseValue())
            skipWhitespace()

            if try consumeIf("]") {
                break
            }
            try consume(",")
        }

        return .array(values)
    }

    private mutating func parseString() throws -> String {
        try consume("\"")
        var result = ""

        while !isAtEnd {
            let ch = chars[index]
            index += 1

            if ch == "\"" {
                return result
            }
            if ch == "\\" {
                guard !isAtEnd else {
                    throw NSError(domain: "OrderedJSONParser", code: 4, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string escape"])
                }
                let escaped = chars[index]
                index += 1
                switch escaped {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "/": result.append("/")
                case "b": result.append("\u{0008}")
                case "f": result.append("\u{000C}")
                case "n": result.append("\n")
                case "r": result.append("\r")
                case "t": result.append("\t")
                case "u":
                    let scalar = try parseUnicodeScalar()
                    result.unicodeScalars.append(scalar)
                default:
                    throw NSError(domain: "OrderedJSONParser", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON string escape"])
                }
            } else {
                result.append(ch)
            }
        }

        throw NSError(domain: "OrderedJSONParser", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unterminated JSON string"])
    }

    private mutating func parseUnicodeScalar() throws -> UnicodeScalar {
        guard index + 3 < chars.count else {
            throw NSError(domain: "OrderedJSONParser", code: 7, userInfo: [NSLocalizedDescriptionKey: "Invalid unicode escape"])
        }
        var hex = ""
        for _ in 0..<4 {
            hex.append(chars[index])
            index += 1
        }
        guard let value = UInt32(hex, radix: 16), let scalar = UnicodeScalar(value) else {
            throw NSError(domain: "OrderedJSONParser", code: 8, userInfo: [NSLocalizedDescriptionKey: "Invalid unicode escape"])
        }
        return scalar
    }

    private mutating func parseNumber() throws -> String {
        let start = index

        if chars[index] == "-" {
            index += 1
        }

        guard !isAtEnd else {
            throw NSError(domain: "OrderedJSONParser", code: 9, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON number"])
        }

        if chars[index] == "0" {
            index += 1
        } else {
            guard chars[index].isNumber else {
                throw NSError(domain: "OrderedJSONParser", code: 10, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON number"])
            }
            while !isAtEnd, chars[index].isNumber {
                index += 1
            }
        }

        if !isAtEnd, chars[index] == "." {
            index += 1
            guard !isAtEnd, chars[index].isNumber else {
                throw NSError(domain: "OrderedJSONParser", code: 11, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON number"])
            }
            while !isAtEnd, chars[index].isNumber {
                index += 1
            }
        }

        if !isAtEnd, chars[index] == "e" || chars[index] == "E" {
            index += 1
            if !isAtEnd, chars[index] == "+" || chars[index] == "-" {
                index += 1
            }
            guard !isAtEnd, chars[index].isNumber else {
                throw NSError(domain: "OrderedJSONParser", code: 12, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON number"])
            }
            while !isAtEnd, chars[index].isNumber {
                index += 1
            }
        }

        return String(chars[start..<index])
    }

    private mutating func consumeLiteral(_ literal: String) throws {
        for expected in literal {
            guard !isAtEnd, chars[index] == expected else {
                throw NSError(domain: "OrderedJSONParser", code: 13, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON literal"])
            }
            index += 1
        }
    }

    private mutating func consume(_ char: Character) throws {
        guard !isAtEnd, chars[index] == char else {
            throw NSError(domain: "OrderedJSONParser", code: 14, userInfo: [NSLocalizedDescriptionKey: "Invalid JSON syntax"])
        }
        index += 1
    }

    private mutating func consumeIf(_ char: Character) throws -> Bool {
        if !isAtEnd, chars[index] == char {
            index += 1
            return true
        }
        return false
    }
}

indirect enum NodeKind { case any, null, primitive(String), list(TypeNode), object([(String, TypeNode)]) }

final class TypeNode {
    var kind: NodeKind
    var nullable: Bool

    init(kind: NodeKind, nullable: Bool = false) {
        self.kind = kind
        self.nullable = nullable
    }
}

final class TypeSpec {
    var kind: SpecKind
    var nullable: Bool
    var primitive: String
    var className: String
    var element: TypeSpec?

    init(kind: SpecKind, nullable: Bool = false, primitive: String = "", className: String = "", element: TypeSpec? = nil) {
        self.kind = kind
        self.nullable = nullable
        self.primitive = primitive
        self.className = className
        self.element = element
    }
}

enum SpecKind { case any, primitive, object, list }

struct FieldDef { var name: String; var jsonName: String; var typeSpec: TypeSpec }

struct ClassDef { var name: String; var fields: [FieldDef]; var nested: [ClassDef] }

private func cloneNode(_ node: TypeNode) -> TypeNode {
    let clonedKind: NodeKind
    switch node.kind {
    case .any:
        clonedKind = .any
    case .null:
        clonedKind = .null
    case let .primitive(value):
        clonedKind = .primitive(value)
    case let .list(element):
        clonedKind = .list(cloneNode(element))
    case let .object(fields):
        var copiedFields: [(String, TypeNode)] = []
        for (key, value) in fields {
            copiedFields.append((key, cloneNode(value)))
        }
        clonedKind = .object(copiedFields)
    }
    return TypeNode(kind: clonedKind, nullable: node.nullable)
}

private func intKind(_ v: Int64) -> String {
    let min32 = Int64(Int32.min)
    let max32 = Int64(Int32.max)
    return (min32...max32).contains(v) ? "Int" : "Long"
}

private func inferType(from value: JSONValue) -> TypeNode {
    switch value {
    case .null:
        return TypeNode(kind: .null)
    case .bool:
        return TypeNode(kind: .primitive("Boolean"))
    case .string:
        return TypeNode(kind: .primitive("String"))
    case let .number(raw):
        if raw.contains(".") || raw.contains("e") || raw.contains("E") {
            return TypeNode(kind: .primitive("Double"))
        }
        if let intValue = Int64(raw) {
            return TypeNode(kind: .primitive(intKind(intValue)))
        }
        return TypeNode(kind: .primitive("Long"))
    case let .array(arr):
        if arr.isEmpty { return TypeNode(kind: .list(TypeNode(kind: .any))) }
        var element = inferType(from: arr[0])
        for item in arr.dropFirst() { element = mergeNodes(element, inferType(from: item)) }
        return TypeNode(kind: .list(element))
    case let .object(items):
        var fields: [(String, TypeNode)] = []
        for (key, itemValue) in items {
            fields.append((key, inferType(from: itemValue)))
        }
        return TypeNode(kind: .object(fields))
    }
}

private func mergeNumeric(_ left: String, _ right: String) -> String {
    let values: Set<String> = [left, right]
    if values.contains("Number") { return "Number" }
    if values == ["Int", "Long"] { return "Long" }
    if values.contains("Double") && (values.contains("Int") || values.contains("Long")) { return "Number" }
    if values == ["Double"] { return "Double" }
    return "Number"
}

private func mergeNodes(_ left: TypeNode, _ right: TypeNode) -> TypeNode {
    switch (left.kind, right.kind) {
    case (.null, .null):
        return TypeNode(kind: .any, nullable: true)
    case (.null, _):
        var r = cloneNode(right); r.nullable = true; return r
    case (_, .null):
        var l = cloneNode(left); l.nullable = true; return l
    default: break
    }
    let nullable = left.nullable || right.nullable
    switch (left.kind, right.kind) {
    case let (.primitive(lp), .primitive(rp)):
        if lp == rp { return TypeNode(kind: .primitive(lp), nullable: nullable) }
        let numeric: Set<String> = ["Int","Long","Double","Number"]
        if numeric.contains(lp) && numeric.contains(rp) {
            return TypeNode(kind: .primitive(mergeNumeric(lp, rp)), nullable: nullable)
        }
        return TypeNode(kind: .any, nullable: nullable)
    case let (.list(le), .list(re)):
        return TypeNode(kind: .list(mergeNodes(le, re)), nullable: nullable)
    case let (.object(lo), .object(ro)):
        var leftMap: [String: TypeNode] = [:]
        for (key, value) in lo {
            leftMap[key] = value
        }
        var rightMap: [String: TypeNode] = [:]
        for (key, value) in ro {
            rightMap[key] = value
        }

        var keys = lo.map { $0.0 }
        let leftKeys = Set(keys)
        for (key, _) in ro where !leftKeys.contains(key) {
            keys.append(key)
        }

        var merged: [(String, TypeNode)] = []
        for key in keys {
            switch (leftMap[key], rightMap[key]) {
            case let (l?, r?):
                merged.append((key, mergeNodes(l, r)))
            case let (l?, nil):
                let opt = cloneNode(l)
                opt.nullable = true
                merged.append((key, opt))
            case let (nil, r?):
                let opt = cloneNode(r)
                opt.nullable = true
                merged.append((key, opt))
            default: break
            }
        }
        return TypeNode(kind: .object(merged), nullable: nullable)
    case (.any, _), (_, .any):
        return TypeNode(kind: .any, nullable: nullable)
    default:
        return TypeNode(kind: .any, nullable: nullable)
    }
}

private func nodeToSpec(_ node: TypeNode) -> TypeSpec {
    switch node.kind {
    case let .primitive(p): return TypeSpec(kind: .primitive, nullable: node.nullable, primitive: p)
    case .any: return TypeSpec(kind: .any, nullable: node.nullable)
    case .null: return TypeSpec(kind: .any, nullable: true)
    case let .list(el):
        let elementSpec = nodeToSpec(el)
        return TypeSpec(kind: .list, nullable: node.nullable, element: elementSpec)
    case .object:
        // For object, produce object kind with empty className placeholder (will be set later)
        return TypeSpec(kind: .object, nullable: node.nullable)
    }
}

private func isIdField(_ name: String) -> Bool {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !n.isEmpty else { return false }
    return n == "id" || n.hasSuffix("id")
}

private func isAmountOrPercentageField(_ name: String) -> Bool {
    let n = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !n.isEmpty else { return false }
    return n.contains("amount") || n.contains("percentage") || n.contains("percent") || n.contains("total") || n.contains("fee")
}

private func applyFieldTypeOverride(fieldName: String, spec: TypeSpec) -> TypeSpec {
    var spec = spec
    guard spec.kind == .primitive else { return spec }
    let numeric: Set<String> = ["Int","Long","Double","Number"]
    guard numeric.contains(spec.primitive) else { return spec }
    if isIdField(fieldName) { spec.primitive = "Long"; return spec }
    if isAmountOrPercentageField(fieldName) { spec.primitive = "Number"; return spec }
    return spec
}

private func buildClassDef(className: String, node: TypeNode, rootName: String, isRoot: Bool, classMode: ClassMode, globalUsedNames: inout Set<String>) -> ClassDef {
    guard case let .object(fields) = node.kind else { return ClassDef(name: className, fields: [], nested: []) }

    var classDef = ClassDef(name: className, fields: [], nested: [])
    var usedNested: Set<String> = []

    for (fieldName, fieldNode) in fields {
        switch fieldNode.kind {
        case .object:
            let rawName = toPascalCase(fieldName)
            let nestedName: String
            switch classMode {
            case .topLevel:
                nestedName = uniqueName(rawName, used: &globalUsedNames)
            case .nested:
                nestedName = uniqueName(rawName, used: &usedNested)
            }
            let nestedDef = buildClassDef(className: nestedName, node: fieldNode, rootName: rootName, isRoot: false, classMode: classMode, globalUsedNames: &globalUsedNames)
            classDef.nested.append(nestedDef)
            var spec = TypeSpec(kind: .object, nullable: fieldNode.nullable, className: nestedName)
            spec = applyFieldTypeOverride(fieldName: fieldName, spec: spec)
            classDef.fields.append(FieldDef(name: fieldName, jsonName: fieldName, typeSpec: spec))
        case let .list(elNode):
            if case .object = elNode.kind {
                let raw = listItemClassName(fieldName: fieldName, parentName: className, rootName: rootName, isRoot: isRoot)
                let candidate = toPascalCase(raw)
                let nestedName: String
                switch classMode {
                case .topLevel: nestedName = uniqueName(candidate, used: &globalUsedNames)
                case .nested: nestedName = uniqueName(candidate, used: &usedNested)
                }
                let nestedDef = buildClassDef(className: nestedName, node: elNode, rootName: rootName, isRoot: false, classMode: classMode, globalUsedNames: &globalUsedNames)
                classDef.nested.append(nestedDef)
                var elementSpec = TypeSpec(kind: .object, nullable: elNode.nullable, className: nestedName)
                let listSpec = TypeSpec(kind: .list, nullable: fieldNode.nullable, element: elementSpec)
                let overridden = applyFieldTypeOverride(fieldName: fieldName, spec: listSpec)
                classDef.fields.append(FieldDef(name: fieldName, jsonName: fieldName, typeSpec: overridden))
            } else {
                let elementSpec = nodeToSpec(elNode)
                let listSpec = TypeSpec(kind: .list, nullable: fieldNode.nullable, element: elementSpec)
                let overridden = applyFieldTypeOverride(fieldName: fieldName, spec: listSpec)
                classDef.fields.append(FieldDef(name: fieldName, jsonName: fieldName, typeSpec: overridden))
            }
        default:
            var spec = nodeToSpec(fieldNode)
            spec = applyFieldTypeOverride(fieldName: fieldName, spec: spec)
            classDef.fields.append(FieldDef(name: fieldName, jsonName: fieldName, typeSpec: spec))
        }
    }
    return classDef
}

// MARK: - Rendering

private func escapeKotlinString(_ value: String) -> String { value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") }

private func renderFieldAnnotation(_ mode: AnnotationMode, jsonName: String) -> String {
    let escaped = escapeKotlinString(jsonName)
    switch mode {
    case .gson: return "@SerializedName(\"\(escaped)\")"
    case .moshi: return "@Json(name = \"\(escaped)\")"
    case .none: return ""
    }
}

private func renderTypeSpec(_ spec: TypeSpec, nullableDepth: Int, forceNullableNested: Bool, applyForceNullable: Bool = true) -> String {
    let base: String
    switch spec.kind {
    case .primitive: base = spec.primitive
    case .object: base = spec.className
    case .any: base = "Any"
    case .list:
        let elementType: String
        if let el = spec.element {
            elementType = renderTypeSpec(el, nullableDepth: nullableDepth, forceNullableNested: forceNullableNested, applyForceNullable: false)
        } else {
            elementType = "Any"
        }
        base = "List<\(elementType)>"
    }
    let nullable = spec.nullable || (forceNullableNested && applyForceNullable && nullableDepth > 0)
    return base + (nullable ? "?" : "")
}

private func renderClassDef(_ classDef: ClassDef, indentDepth: Int, nullableDepth: Int, forceNullableNested: Bool, annotationMode: AnnotationMode, inlineNested: Bool, indentSize: Int = 4) -> [String] {
    let indent = String(repeating: " ", count: indentSize * indentDepth)
    var lines: [String] = ["\(indent)data class \(classDef.name)("]

    let total = classDef.fields.count
    for (index, field) in classDef.fields.enumerated() {
        let propIndent = String(repeating: " ", count: indentSize * (indentDepth + 1))
        let kotlinName = toSafePropertyName(field.name)
        let annotation = renderFieldAnnotation(annotationMode, jsonName: field.jsonName)
        let kotlinType = renderTypeSpec(field.typeSpec, nullableDepth: nullableDepth, forceNullableNested: forceNullableNested, applyForceNullable: true)
        let suffix = index < total - 1 ? "," : ""
        if !annotation.isEmpty { lines.append("\(propIndent)\(annotation)") }
        lines.append("\(propIndent)val \(kotlinName): \(kotlinType)\(suffix)")
    }

    lines.append("\(indent))")

    if inlineNested && !classDef.nested.isEmpty {
        lines[lines.count - 1] += "{"
        for (idx, nested) in classDef.nested.enumerated() {
            lines.append(contentsOf: renderClassDef(nested, indentDepth: indentDepth + 1, nullableDepth: nullableDepth + 1, forceNullableNested: forceNullableNested, annotationMode: annotationMode, inlineNested: inlineNested, indentSize: indentSize))
            if idx < classDef.nested.count - 1 { lines.append("") }
        }
        lines.append("\(indent)}")
    }

    return lines
}

private func collectClassEntries(_ classDef: ClassDef, depth: Int = 0) -> [(classDef: ClassDef, depth: Int)] {
    var entries: [(ClassDef, Int)] = [(classDef, depth)]
    for nested in classDef.nested { entries.append(contentsOf: collectClassEntries(nested, depth: depth + 1)) }
    return entries
}

// MARK: - Utilities

private func removeIgnoredKeys(_ value: JSONValue, ignored: Set<String>) -> JSONValue {
    guard !ignored.isEmpty else { return value }
    switch value {
    case let .object(items):
        var cleaned: [(String, JSONValue)] = []
        for (key, item) in items where !ignored.contains(key) {
            cleaned.append((key, removeIgnoredKeys(item, ignored: ignored)))
        }
        return .object(cleaned)
    case let .array(arr):
        return .array(arr.map { removeIgnoredKeys($0, ignored: ignored) })
    case .string, .number, .bool, .null:
        return value
    }
}

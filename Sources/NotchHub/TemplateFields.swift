import Foundation

/// Plain templates keep their existing on-disk shape. Fields are parsed, never executed.
struct TemplateFields {
    enum Part: Equatable { case text(String), field(String) }
    let parts: [Part]
    let names: [String]
    static let maximumFields = 32

    init(_ source: String) throws {
        guard source.utf8.count <= HubStore.maxBytes else { throw ClipActionFailure("Шаблон превышает 30 МБ") }
        var parts: [Part] = [], names: [String] = [], literal = ""
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\\" {
                let next = source.index(after: index)
                if source[next...].hasPrefix("{{") {
                    literal += "{{"; index = source.index(next, offsetBy: 2); continue
                }
            }
            if source[index...].hasPrefix("{{") {
                if !literal.isEmpty { parts.append(.text(literal)); literal = "" }
                let start = source.index(index, offsetBy: 2)
                guard let end = source.range(of: "}}", range: start..<source.endIndex) else {
                    throw ClipActionFailure("Закрой поле двойными скобками: {{Имя}}")
                }
                let name = source[start..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty, name.count <= 80,
                      !name.contains(where: { $0 == "{" || $0 == "}" || $0.isNewline || $0 == "\\" }) else {
                    throw ClipActionFailure("Имя поля: от 1 до 80 символов, без скобок и переносов строк")
                }
                if !names.contains(name) {
                    guard names.count < Self.maximumFields else { throw ClipActionFailure("В шаблоне может быть до 32 разных полей") }
                    names.append(name)
                }
                parts.append(.field(name)); index = end.upperBound
            } else {
                literal.append(source[index]); index = source.index(after: index)
            }
        }
        if !literal.isEmpty { parts.append(.text(literal)) }
        self.parts = parts; self.names = names
    }

    func render(values: [String: String], requireValues: Bool = true) throws -> String {
        if requireValues, let missing = names.first(where: { (values[$0] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            throw ClipActionFailure("Заполни поле «\(missing)»")
        }
        var output = "", byteCount = 0
        for part in parts {
            let value: String
            switch part {
            case .text(let text): value = text
            case .field(let name): value = values[name] ?? ""
            }
            guard value.utf8.count <= HubStore.maxBytes - byteCount else { throw ClipActionFailure("Результат превышает 30 МБ") }
            byteCount += value.utf8.count; output += value
        }
        return output
    }
}

/// Exact text and UTF-16 selection, rather than a lossy reverse transformation.
struct FormattingSnapshot: Equatable {
    let text: String
    let selection: NSRange
    init(text: String, selection: NSRange) {
        self.text = text
        self.selection = Range(selection, in: text) == nil ? NSRange(location: 0, length: 0) : selection
    }
}

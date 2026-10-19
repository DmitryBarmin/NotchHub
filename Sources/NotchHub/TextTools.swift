import Foundation

enum TextTransform: String, CaseIterable, Identifiable {
    case plainText, fixLayout, upper, lower, titleCase, sentenceCase, formatJSON, cleanURL
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plainText: return "Без форматирования"
        case .fixLayout: return "Исправить раскладку"
        case .upper: return "ВСЕ ЗАГЛАВНЫЕ"
        case .lower: return "все строчные"
        case .titleCase: return "Каждое Слово С Заглавной"
        case .sentenceCase: return "Как в предложении"
        case .formatJSON: return "Форматировать JSON"
        case .cleanURL: return "Убрать метки из ссылки"
        }
    }
    var caseExample: String? {
        switch self {
        case .upper: return "АБВ"
        case .lower: return "абв"
        case .titleCase: return "Аб Вг"
        case .sentenceCase: return "Абв."
        default: return nil
        }
    }
    var symbol: String {
        switch self {
        case .plainText: return "textformat"
        case .fixLayout: return "globe"
        case .upper: return "textformat.abc"
        case .lower: return "textformat.abc.dottedunderline"
        case .titleCase: return "textformat.size"
        case .sentenceCase: return "textformat.alt"
        case .formatJSON: return "curlybraces"
        case .cleanURL: return "link"
        }
    }
    func apply(to text: String) throws -> String {
        switch self {
        case .plainText: return text
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .titleCase: return text.capitalized
        case .sentenceCase:
            var startsSentence = true
            return String(text.lowercased().flatMap { character -> String in
                if character.isLetter {
                    defer { startsSentence = false }
                    return startsSentence ? String(character).uppercased() : String(character)
                }
                if ".!?\n".contains(character) { startsSentence = true }
                return String(character)
            })
        case .fixLayout:
            let latin = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?")
            let russian = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")
            let containsRussian = text.unicodeScalars.contains { (0x0400...0x04ff).contains($0.value) }
            let mapping = Dictionary(uniqueKeysWithValues: containsRussian ? zip(russian, latin).map { ($0, $1) } : zip(latin, russian).map { ($0, $1) })
            return String(text.map { mapping[$0] ?? $0 })
        case .formatJSON:
            let writing: JSONSerialization.WritingOptions = [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]
            for reading: JSONSerialization.ReadingOptions in [[.fragmentsAllowed], [.fragmentsAllowed, .json5Allowed], [.json5Allowed, .topLevelDictionaryAssumed]] {
                if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: reading),
                   (!reading.contains(.topLevelDictionaryAssumed) || (json as? [String: Any])?.isEmpty == false),
                   JSONSerialization.isValidJSONObject([json]),
                   let data = try? JSONSerialization.data(withJSONObject: json, options: writing) {
                    return String(decoding: data, as: UTF8.self)
                }
            }
            do {
                let data = try JSONSerialization.data(withJSONObject: ["text": text], options: writing)
                return String(decoding: data, as: UTF8.self)
            } catch {
                throw ClipActionFailure("Не удалось создать JSON. Исходный текст не изменён.")
            }
        case .cleanURL:
            guard URL(string: text, encodingInvalidCharacters: false) != nil,
                  var components = URLComponents(string: text),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty,
                  let items = components.queryItems else { return text }
            let tracking = Set(["fbclid", "gclid", "dclid", "msclkid", "mc_cid", "mc_eid", "igshid"])
            let filtered = items.filter { !($0.name.lowercased().hasPrefix("utm_") || tracking.contains($0.name.lowercased())) }
            guard filtered.count != items.count else { return text }
            // Keep the original percent encoding of retained parameters.
            let encoded = components.percentEncodedQuery?.components(separatedBy: "&") ?? []
            guard encoded.count == items.count else { return text }
            let retained = zip(items, encoded).filter { item, _ in !item.name.lowercased().hasPrefix("utm_") && !tracking.contains(item.name.lowercased()) }.map(\.1)
            components.percentEncodedQuery = retained.isEmpty ? nil : retained.joined(separator: "&")
            return components.string ?? text
        }
    }
}

/// AppKit and Accessibility use UTF-16 ranges; never index Swift graphemes with them.
enum TextSelectionTransform {
    static func apply(_ transform: TextTransform, to text: String, range: NSRange) throws -> (text: String, selection: NSRange) {
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text),
              (swiftRange.lowerBound == text.endIndex || text.indices.contains(swiftRange.lowerBound)),
              (swiftRange.upperBound == text.endIndex || text.indices.contains(swiftRange.upperBound)) else {
            throw ClipActionFailure("Выделение изменилось — выдели текст снова")
        }
        let result = try transform.apply(to: String(text[swiftRange]))
        return (result, NSRange(location: range.location, length: (result as NSString).length))
    }
}

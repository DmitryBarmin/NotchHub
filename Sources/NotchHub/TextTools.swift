import Foundation

enum TextTransform: String, CaseIterable, Identifiable {
    case plainText, fixLayout, upper, lower, titleCase, formatJSON, cleanURL
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plainText: return "Без форматирования"
        case .fixLayout: return "Исправить раскладку"
        case .upper: return "ПРОПИСНЫЕ"
        case .lower: return "строчные"
        case .titleCase: return "Начинать С Прописных"
        case .formatJSON: return "Форматировать JSON"
        case .cleanURL: return "Убрать метки из ссылки"
        }
    }
    func apply(to text: String) throws -> String {
        switch self {
        case .plainText: return text
        case .upper: return text.uppercased()
        case .lower: return text.lowercased()
        case .titleCase: return text.capitalized
        case .fixLayout:
            let latin = Array("`qwertyuiop[]asdfghjkl;'zxcvbnm,./~QWERTYUIOP{}ASDFGHJKL:\"ZXCVBNM<>?")
            let russian = Array("ёйцукенгшщзхъфывапролджэячсмитьбю.ЁЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,")
            let containsRussian = text.unicodeScalars.contains { (0x0400...0x04ff).contains($0.value) }
            let mapping = Dictionary(uniqueKeysWithValues: containsRussian ? zip(russian, latin).map { ($0, $1) } : zip(latin, russian).map { ($0, $1) })
            return String(text.map { mapping[$0] ?? $0 })
        case .formatJSON:
            let json = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
            return String(decoding: data, as: UTF8.self)
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

import AppKit
import Combine

struct TextCorrectionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Explicit proofreading through the user's own gateway. The app only ever holds the gateway key.
enum TextCorrectionLimits {
    static let maxCharacters = 6000
    static let maxBytes = 24 * 1024
    /// The corrected paragraph is about the size of the source; the body limit also bounds error payloads.
    static let maxResultBytes = 4 * maxBytes
    static let responseBytes = maxResultBytes + 4096
    static let timeout: TimeInterval = 60
    static func validate(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TextCorrectionFailure("Нет текста для исправления") }
        guard text.count <= maxCharacters else { throw TextCorrectionFailure("Текст длиннее \(maxCharacters) символов — исправь его частями") }
        guard text.utf8.count <= maxBytes else { throw TextCorrectionFailure("Текст больше 24 КБ — исправь его частями") }
    }
}

struct TextCorrectionResult: Equatable {
    let text: String
    let model: String?
    let effort: String?
    let provider: String?

    init(text: String, model: String?, effort: String?, provider: String? = nil) {
        self.text = text; self.model = model; self.effort = effort; self.provider = provider
    }
}

struct LocalSpellingIssue: Equatable {
    let range: NSRange
    let correction: String?
}

struct LocalSpellingOutcome: Equatable {
    let text: String
    let misspellingCount: Int
    let correctedCount: Int
    let unresolvedCount: Int
}

enum LocalSpellingEngine {
    private static let protectedPatterns = [
        #"(?i)\b(?:https?://|www\.)[^\s<>]+"#,
        #"(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b"#,
        #"(?<![\p{L}\p{N}])(?:[A-Za-z]:\\|~?/|\.{1,2}/|[A-Za-z0-9_.-]+/)[^\s<>]+"#,
        #"\b[A-Za-z_][A-Za-z0-9_]*_[A-Za-z0-9_]+\b"#,
        #"\b[a-z][A-Za-z0-9]*[A-Z][A-Za-z0-9]*\b"#,
        #"\b[A-Za-z0-9]+(?:[.-][A-Za-z0-9]+)+\b"#,
        #"(?<!\w)[+-]?\d[\d.,:%/-]*(?!\w)"#
    ]

    static func apply(_ issues: [LocalSpellingIssue], to source: String) -> LocalSpellingOutcome {
        let protected = protectedRanges(in: source)
        var replacements: [(NSRange, String)] = []
        var unresolved = 0
        let string = source as NSString
        for issue in issues {
            guard issue.range.location >= 0, issue.range.length > 0,
                  NSMaxRange(issue.range) <= string.length,
                  Range(issue.range, in: source) != nil,
                  !protected.contains(where: { NSIntersectionRange($0, issue.range).length > 0 }) else { continue }
            guard let correction = issue.correction, !correction.isEmpty,
                  correction.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
                unresolved += 1; continue
            }
            let original = string.substring(with: issue.range)
            guard correction != original else { unresolved += 1; continue }
            replacements.append((issue.range, correction))
        }
        replacements.sort { $0.0.location > $1.0.location }
        var output = source as NSString
        for (range, replacement) in replacements { output = output.replacingCharacters(in: range, with: replacement) as NSString }
        return LocalSpellingOutcome(text: output as String, misspellingCount: issues.count,
                                    correctedCount: replacements.count, unresolvedCount: unresolved)
    }

    static func isProtected(_ range: NSRange, in source: String) -> Bool {
        protectedRanges(in: source).contains { NSIntersectionRange($0, range).length > 0 }
    }

    private static func protectedRanges(in source: String) -> [NSRange] {
        protectedPatterns.flatMap { pattern -> [NSRange] in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
            return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).map(\.range)
        } + codeRanges(in: source)
    }

    private static func codeRanges(in source: String) -> [NSRange] {
        let ns = source as NSString
        var ranges: [NSRange] = []
        var cursor = 0
        while cursor < ns.length {
            let lineRange = ns.lineRange(for: NSRange(location: cursor, length: 0))
            let line = ns.substring(with: lineRange).trimmingCharacters(in: .newlines)
            if let opening = try? NSRegularExpression(pattern: #"^ {0,3}(`{3,}|~{3,})"#),
               let match = opening.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
                let marker = (line as NSString).substring(with: match.range(at: 1))
                let markerChar = marker.first!
                var closingCursor = NSMaxRange(lineRange)
                var closeEnd = ns.length
                var foundClose = false
                while closingCursor < ns.length {
                    let candidateRange = ns.lineRange(for: NSRange(location: closingCursor, length: 0))
                    let candidate = ns.substring(with: candidateRange).trimmingCharacters(in: .newlines)
                    let escaped = NSRegularExpression.escapedPattern(for: String(markerChar))
                    let closePattern = "^ {0,3}" + escaped + "{" + String(marker.count) + ",}[ \\t]*$"
                    if let close = try? NSRegularExpression(pattern: closePattern),
                       close.firstMatch(in: candidate, range: NSRange(location: 0, length: (candidate as NSString).length)) != nil {
                        closeEnd = NSMaxRange(candidateRange)
                        foundClose = true
                        break
                    }
                    closingCursor = NSMaxRange(candidateRange)
                }
                ranges.append(NSRange(location: lineRange.location, length: closeEnd - lineRange.location))
                cursor = foundClose ? closeEnd : ns.length
                continue
            }
            cursor = NSMaxRange(lineRange)
        }

        // Inline code closes only with the same number of backticks. An unmatched delimiter
        // protects the remainder, avoiding edits inside malformed or truncated code.
        var index = 0
        while index < ns.length {
            guard ns.character(at: index) == 96 else { index += 1; continue }
            var runEnd = index + 1
            while runEnd < ns.length && ns.character(at: runEnd) == 96 { runEnd += 1 }
            let runLength = runEnd - index
            var search = runEnd
            var closeRange: NSRange?
            while search < ns.length {
                guard ns.character(at: search) == 96 else { search += 1; continue }
                var candidateEnd = search + 1
                while candidateEnd < ns.length && ns.character(at: candidateEnd) == 96 { candidateEnd += 1 }
                if candidateEnd - search == runLength {
                    closeRange = NSRange(location: search, length: runLength)
                    break
                }
                search = candidateEnd
            }
            let end = closeRange.map(NSMaxRange) ?? ns.length
            ranges.append(NSRange(location: index, length: end - index))
            index = end
        }
        return ranges
    }
}

enum MacSpellingCorrector {
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); cancelled = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    }

    static func correct(_ source: String) async throws -> LocalSpellingOutcome {
        try TextCorrectionLimits.validate(source)
        let cancellation = CancellationFlag()
        return try await withTaskCancellationHandler {
          try await withCheckedThrowingContinuation { continuation in
            let queue = DispatchQueue(label: "local-spelling-corrections", qos: .userInitiated)
            queue.async {
                let checker = NSSpellChecker.shared
                let available = checker.availableLanguages
                let russian = available.first { $0.lowercased().hasPrefix("ru") }
                let english = available.first { $0.lowercased().hasPrefix("en") }
                guard russian != nil || english != nil else {
                    continuation.resume(throwing: TextCorrectionFailure("В macOS не включён словарь русского или английского языка"))
                    return
                }
                let tag = NSSpellChecker.uniqueSpellDocumentTag()
                guard !cancellation.isCancelled else {
                    checker.closeSpellDocument(withTag: tag)
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let ns = source as NSString
                let wordExpression = try! NSRegularExpression(pattern: #"[\p{L}\p{M}]+(?:['’][\p{L}\p{M}]+)*"#)
                let words = wordExpression.matches(in: source, range: NSRange(location: 0, length: ns.length))
                    .filter { !LocalSpellingEngine.isProtected($0.range, in: source) }
                var issues: [LocalSpellingIssue] = []
                for finding in words {
                    if cancellation.isCancelled {
                        checker.closeSpellDocument(withTag: tag)
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let word = ns.substring(with: finding.range)
                    let hasCyrillic = word.unicodeScalars.contains { (0x0400...0x052F).contains(Int($0.value)) }
                    let hasLatin = word.range(of: #"\p{Latin}"#, options: .regularExpression) != nil
                    let language: String?
                    if hasCyrillic && !hasLatin { language = russian }
                    else if hasLatin && !hasCyrillic { language = english }
                    else { continue }
                    guard let language else { continue }
                    var wordCount = 0
                    let misspelling = checker.checkSpelling(of: word, startingAt: 0, language: language,
                        wrap: false, inSpellDocumentWithTag: tag, wordCount: &wordCount)
                    guard misspelling.location != NSNotFound, misspelling.length > 0,
                          misspelling.location >= 0, NSMaxRange(misspelling) <= (word as NSString).length else { continue }
                    let correction = checker.correction(forWordRange: misspelling, in: word,
                        language: language, inSpellDocumentWithTag: tag)
                    let correctedRange = NSRange(location: finding.range.location + misspelling.location,
                                                  length: misspelling.length)
                    issues.append(LocalSpellingIssue(range: correctedRange, correction: correction))
                }
                checker.closeSpellDocument(withTag: tag)
                continuation.resume(returning: LocalSpellingEngine.apply(issues, to: source))
            }
          }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

struct TextCorrectionClient {
    typealias Transport = (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    static let path = "correct"
    private let transport: Transport
    init(transport: Transport? = nil) {
        self.transport = transport ?? { request, limit in try await TransferRequest.perform(request, limit: limit, timeout: TextCorrectionLimits.timeout) }
    }
    static func request(text: String, endpoint: URL, key: String) throws -> URLRequest {
        try TextCorrectionLimits.validate(text)
        guard !key.isEmpty else { throw TextCorrectionFailure("Сохрани ключ отправки в Настройки → Передача") }
        var request = URLRequest(url: endpoint.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": text], options: [.withoutEscapingSlashes])
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = TextCorrectionLimits.timeout
        return request
    }
    static func result(from body: Data, status: Int) throws -> TextCorrectionResult {
        guard status == 200 else { throw TextCorrectionFailure(message(for: status)) }
        struct Payload: Decodable { let text: String; let model: String?; let effort: String? }
        guard body.count <= TextCorrectionLimits.responseBytes, let payload = try? JSONDecoder().decode(Payload.self, from: body) else {
            throw TextCorrectionFailure("Сервер вернул неожиданный ответ")
        }
        guard !payload.text.isEmpty, payload.text.utf8.count <= TextCorrectionLimits.maxResultBytes else { throw TextCorrectionFailure("Сервер вернул пустой или слишком длинный текст") }
        return TextCorrectionResult(text: payload.text, model: payload.model, effort: payload.effort)
    }
    func correct(_ text: String, endpoint: URL, key: String) async throws -> TextCorrectionResult {
        let request = try Self.request(text: text, endpoint: endpoint, key: key)
        let (body, response) = try await transport(request, TextCorrectionLimits.responseBytes)
        try Task.checkCancellation()
        return try Self.result(from: body, status: response.statusCode)
    }
    static func message(for status: Int) -> String {
        switch status {
        case 400: return "Сервер отклонил текст. Проверь, что это обычный текст до 6000 символов"
        case 401, 403: return "Проверь ключ отправки в Настройки → Передача"
        case 404: return "Сервер не поддерживает исправление ошибок. Обнови сервер"
        case 413: return "Текст превышает лимит сервера"
        case 429: return "Слишком много запросов. Повтори через минуту"
        case 502, 503, 504: return "Сервис исправления временно недоступен (\(status)). Повтори позже"
        default: return "Сервер недоступен (\(status))"
        }
    }
}

/// Consent is scoped to the gateway origin: a new server address asks again.
final class TextCorrectionConsent: ObservableObject {
    static let preferenceKey = "textCorrectionConsentOriginV1"
    @Published private(set) var origin: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        origin = defaults.string(forKey: Self.preferenceKey)
    }
    func isGranted(for endpoint: URL) -> Bool { origin == endpoint.absoluteString }
    func grant(for endpoint: URL) { origin = endpoint.absoluteString; defaults.set(origin, forKey: Self.preferenceKey) }
    func revoke() { origin = nil; defaults.removeObject(forKey: Self.preferenceKey) }
    static func notice(for endpoint: URL) -> String {
        "Текст покинет этот Mac: он уйдёт на сервер \(endpoint.host ?? endpoint.absoluteString) и будет исправлен моделью OpenAI через серверный Hermes. Отправляется только этот текст, без истории буфера. Согласие сохраняется для этого адреса; при смене сервера вопрос появится снова."
    }
}

/// Owns one in-flight correction. Stale or cancelled requests never touch the editor or the clipboard.
@MainActor final class TextCorrectionController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var pendingConsent: String?
    @Published private(set) var message: String?
    @Published private(set) var result: TextCorrectionResult?
    @Published private(set) var copied = false
    let settings: TransferSettings
    let consent: TextCorrectionConsent
    private let client: TextCorrectionClient
    private let changeCount: () -> Int
    private let hasProtectedClipboard: () -> Bool
    private let localCorrector: (String) async throws -> LocalSpellingOutcome
    private let copy: (String) -> Void
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var pending: (text: String, endpoint: URL, apply: (TextCorrectionResult) -> Bool)?

    init(settings: TransferSettings, consent: TextCorrectionConsent, transport: TextCorrectionClient.Transport? = nil,
         changeCount: (() -> Int)? = nil, hasProtectedClipboard: (() -> Bool)? = nil, copy: ((String) -> Void)? = nil,
         localCorrector: ((String) async throws -> LocalSpellingOutcome)? = nil) {
        self.settings = settings; self.consent = consent
        client = TextCorrectionClient(transport: transport)
        self.changeCount = changeCount ?? { NSPasteboard.general.changeCount }
        self.hasProtectedClipboard = hasProtectedClipboard ?? Self.generalClipboardIsProtected
        self.localCorrector = localCorrector ?? MacSpellingCorrector.correct
        self.copy = copy ?? { text in
            let board = NSPasteboard.general
            board.clearContents(); board.setString(text, forType: .string)
        }
    }
    var host: String { settings.endpointURL?.host ?? "—" }

    private static func generalClipboardIsProtected() -> Bool {
        let board = NSPasteboard.general
        let protected = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        let types = (board.types ?? []) + (board.pasteboardItems ?? []).flatMap { $0.types }
        return types.contains { protected.contains($0.rawValue) }
    }

    /// Explicit user action. Nothing leaves the Mac before consent for this server is confirmed.
    /// `apply` runs on success and reports whether the result replaced the editor text.
    func request(text: String, apply: @escaping (TextCorrectionResult) -> Bool) {
        guard !busy else { return }
        pendingConsent = nil; pending = nil
        do { try TextCorrectionLimits.validate(text) } catch { message = error.localizedDescription; return }
        guard let endpoint = settings.endpointURL, !settings.uploadKey.isEmpty else {
            message = "Сохрани адрес сервера и ключ отправки в Настройки → Передача. Передачу включать не нужно."; return
        }
        guard consent.isGranted(for: endpoint) else {
            pending = (text, endpoint, apply); pendingConsent = TextCorrectionConsent.notice(for: endpoint); message = nil; return
        }
        start(text: text, endpoint: endpoint, key: settings.uploadKey, apply: apply)
    }

    /// Local spelling correction never reads gateway settings or requests network consent.
    func correctLocally(text: String, apply: @escaping (TextCorrectionResult) -> Bool) {
        guard !busy else { return }
        pendingConsent = nil; pending = nil
        do { try TextCorrectionLimits.validate(text) } catch { message = error.localizedDescription; return }
        let token = UUID(); generation = token
        let snapshot = changeCount()
        busy = true; copied = false; result = nil
        message = "Проверяю орфографию словарём macOS…"
        operation = Task {
            defer { if generation == token { busy = false; operation = nil } }
            do {
                let outcome = try await localCorrector(text)
                try Task.checkCancellation()
                guard generation == token else { return }
                guard outcome.correctedCount > 0 else {
                    message = outcome.misspellingCount == 0
                        ? "Словарь macOS не нашёл явных орфографических ошибок."
                        : "Словарь macOS не предложил безопасных исправлений. Текст не изменён."
                    return
                }
                let corrected = TextCorrectionResult(text: outcome.text, model: nil, effort: nil, provider: "Словарь macOS")
                result = corrected
                let applied = apply(corrected)
                if changeCount() == snapshot && !hasProtectedClipboard() {
                    copy(corrected.text); copied = true
                    message = applied ? "Исправлено локально и скопировано — вставь через ⌘V" : "Исправление скопировано — вставь через ⌘V"
                } else {
                    message = applied ? "Исправлено локально. Буфер изменился или содержит защищённые данные, поэтому результат не скопирован." : "Исправление показано ниже. Буфер изменился или содержит защищённые данные — скопируй его вручную."
                }
                if outcome.unresolvedCount > 0 { message = (message ?? "") + " Некоторые слова оставлены без изменений." }
            } catch is CancellationError {
            } catch { if generation == token { message = "Не удалось проверить словарём macOS: \(error.localizedDescription)" } }
        }
    }
    func confirmConsent() {
        guard let pending, let endpoint = settings.endpointURL, !settings.uploadKey.isEmpty else { declineConsent(); return }
        guard endpoint == pending.endpoint else {
            self.pending = nil; pendingConsent = nil
            message = "Адрес сервера изменился. Нажми «Полная правка…» снова и подтверди отправку для нового адреса."
            return
        }
        consent.grant(for: endpoint)
        self.pending = nil; pendingConsent = nil
        start(text: pending.text, endpoint: endpoint, key: settings.uploadKey, apply: pending.apply)
    }
    func declineConsent() {
        pending = nil; pendingConsent = nil
        message = "Отправка отменена. Текст остался на Mac."
    }
    private func start(text: String, endpoint: URL, key: String, apply: @escaping (TextCorrectionResult) -> Bool) {
        let token = UUID(); generation = token
        let snapshot = changeCount()
        busy = true; copied = false; result = nil
        message = "Исправляю ошибки через сервер \(endpoint.host ?? "")…"
        operation = Task {
            defer { if generation == token { busy = false; operation = nil } }
            do {
                let corrected = try await client.correct(text, endpoint: endpoint, key: key)
                try Task.checkCancellation()
                guard generation == token else { return }
                guard settings.endpointURL == endpoint, settings.uploadKey == key, consent.isGranted(for: endpoint) else {
                    message = "Настройки сервера или согласие изменились. Результат не применён и не скопирован."
                    return
                }
                result = corrected
                let applied = apply(corrected)
                if changeCount() == snapshot && !hasProtectedClipboard() {
                    copy(corrected.text); copied = true
                    message = applied ? "Исправлено и скопировано — вставь через ⌘V" : "Исправление скопировано — вставь через ⌘V"
                } else {
                    message = applied ? "Исправлено. Буфер изменился или содержит защищённые данные, поэтому результат не скопирован." : "Буфер изменился или содержит защищённые данные. Исправление показано ниже — скопируй его кнопкой."
                }
            } catch is CancellationError {
            } catch { if generation == token { message = "Не удалось исправить: \(error.localizedDescription)" } }
        }
    }
    func copyResult() {
        guard let result else { return }
        copy(result.text); copied = true; message = "Исправление скопировано — вставь через ⌘V"
    }
    func clearResult() { result = nil; copied = false; message = nil }
    func cancel() {
        generation = UUID()
        operation?.cancel(); operation = nil
        busy = false; pending = nil; pendingConsent = nil; result = nil; copied = false; message = nil
    }
}

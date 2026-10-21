import AppKit
import Combine
import CryptoKit
import ImageIO
import Security
import UniformTypeIdentifiers

struct TransferFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct TransferItem: Codable, Identifiable {
    var id = UUID()
    var kind: Clip.Kind
    var title: String
    var text: String?
    var data: Data?
    var filename: String?
}

final class TransferSettings: ObservableObject {
    static let defaultEndpoint = URL(string: "https://augreality.online:9443")!
    static let preferenceKey = "transferEndpointV1"
    static let keychainService = "local.notchhub.transfer"
    @Published private(set) var endpointURL: URL?
    @Published private(set) var uploadKey: String
    @Published private(set) var message: String?
    private let defaults: UserDefaults
    private let readKey: (String) -> String?
    private let writeKey: (String, String) throws -> Void

    init(defaults: UserDefaults = .standard, readKey: ((String) -> String?)? = nil, writeKey: ((String, String) throws -> Void)? = nil) {
        self.defaults = defaults
        let reader = readKey ?? Self.readKeychain
        self.readKey = reader
        self.writeKey = writeKey ?? Self.writeKeychain
        let saved = defaults.string(forKey: Self.preferenceKey) ?? Self.defaultEndpoint.absoluteString
        let endpoint = Self.validatedEndpoint(saved)
        endpointURL = endpoint
        uploadKey = endpoint.flatMap { reader($0.absoluteString) } ?? ""
    }
    static func validatedEndpoint(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines), encodingInvalidCharacters: false),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host != nil, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { return nil }
        let local = ["localhost", "127.0.0.1", "[::1]", "::1"].contains(components.host?.lowercased() ?? "")
        guard components.scheme?.lowercased() == "https" || (components.scheme?.lowercased() == "http" && local) else { return nil }
        var origin = components
        origin.path = ""
        origin.scheme = components.scheme?.lowercased()
        origin.host = components.host?.lowercased()
        return origin.url
    }
    @discardableResult func save(endpoint: String, key: String) -> Bool {
        guard let endpoint = Self.validatedEndpoint(endpoint) else { message = "Укажи HTTPS-адрес сервера без пути, пароля и параметров"; return false }
        let secret = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard secret.isEmpty || (secret.utf8.count >= 32 && secret.utf8.count <= 512 && !secret.contains(where: \.isWhitespace)) else {
            message = "Ключ должен содержать от 32 до 512 символов без пробелов"; return false
        }
        do {
            try writeKey(endpoint.absoluteString, secret)
            defaults.set(endpoint.absoluteString, forKey: Self.preferenceKey)
            endpointURL = endpoint; uploadKey = secret; message = "Настройки передачи сохранены"
            return true
        } catch { message = error.localizedDescription; return false }
    }
    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: account]
    }
    private static func readKeychain(_ account: String) -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private static func writeKeychain(_ account: String, _ key: String) throws {
        let identity = query(account)
        if key.isEmpty {
            let result = SecItemDelete(identity as CFDictionary)
            guard result == errSecSuccess || result == errSecItemNotFound else { throw TransferFailure("Не удалось удалить ключ из Связки ключей (\(result))") }
            return
        }
        let data = Data(key.utf8)
        var result = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if result == errSecItemNotFound {
            var entry = identity
            entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            result = SecItemAdd(entry as CFDictionary, nil)
        }
        guard result == errSecSuccess else { throw TransferFailure("Не удалось сохранить ключ в Связке ключей (\(result))") }
    }
}

enum TransferCodec {
    static let itemLimit = 20
    static let itemBytes = 30 * 1024 * 1024
    static let totalBytes = 60 * 1024 * 1024
    static let wireBytes = 90 * 1024 * 1024
    private static let magic = Data("NHTRANS1".utf8)
    private static let authenticated = Data("NotchHub.Transfer.v1".utf8)
    private struct Envelope: Codable { let version: Int; let items: [TransferItem] }

    static func validFilename(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 240 && name != "." && name != ".." &&
        !name.contains("/") && !name.contains("\\") && !name.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
    private static func completePNG(_ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard bytes.count >= 8, Array(bytes.prefix(8)) == [137, 80, 78, 71, 13, 10, 26, 10] else { return false }
            var offset = 8, hasPixels = false
            while offset <= bytes.count - 12 {
                let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
                guard length <= bytes.count - offset - 12 else { return false }
                let type = Array(bytes[(offset + 4)..<(offset + 8)])
                if type == [73, 68, 65, 84] { hasPixels = true }
                offset += length + 12
                if type == [73, 69, 78, 68] { return length == 0 && offset == bytes.count && hasPixels }
            }
            return false
        }
    }
    static func validate(_ items: [TransferItem]) throws {
        guard !items.isEmpty, items.count <= itemLimit, Set(items.map(\.id)).count == items.count else { throw TransferFailure("Передача должна содержать от 1 до 20 отдельных элементов") }
        var bytes = 0
        for item in items {
            try Task.checkCancellation()
            guard item.title.utf8.count <= 4096 else { throw TransferFailure("Слишком длинное название элемента") }
            switch item.kind {
            case .text:
                guard let text = item.text, !text.isEmpty, item.data == nil, item.filename == nil, text.utf8.count <= itemBytes else { throw TransferFailure("Повреждённый текст в передаче") }
                bytes += text.utf8.count
            case .image, .file:
                guard item.text == nil, let data = item.data, !data.isEmpty, data.count <= itemBytes,
                      let filename = item.filename, validFilename(filename) else { throw TransferFailure("Повреждённый файл в передаче") }
                bytes += data.count
                if item.kind == .image {
                    guard let source = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetStatus(source) == .statusComplete,
                          let identifier = CGImageSourceGetType(source) as String?, let actualType = UTType(identifier), actualType.conforms(to: .image),
                          let claimed = UTType(filenameExtension: (filename as NSString).pathExtension), claimed.conforms(to: actualType),
                          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                          let width = properties[kCGImagePropertyPixelWidth] as? Int, let height = properties[kCGImagePropertyPixelHeight] as? Int,
                          width > 0, height > 0, width <= 32768, height <= 32768, width * height <= 100_000_000 else {
                        throw TransferFailure("Формат или расширение изображения не совпадают")
                    }
                    guard (actualType != .png || completePNG(data)),
                          CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 16] as CFDictionary) != nil else {
                        throw TransferFailure("Изображение повреждено или обрезано")
                    }
                }
            }
            guard bytes <= totalBytes else { throw TransferFailure("Общий размер передачи больше 60 МБ") }
        }
    }
    static func encode(_ items: [TransferItem], key: Data) throws -> Data {
        try validate(items)
        guard key.count == 32 else { throw TransferFailure("Неверный ключ передачи") }
        let plaintext = try JSONEncoder().encode(Envelope(version: 1, items: items))
        try Task.checkCancellation()
        let box = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), authenticating: authenticated)
        guard let combined = box.combined, combined.count + magic.count <= wireBytes else { throw TransferFailure("Передача слишком большая") }
        return magic + combined
    }
    static func decode(_ encrypted: Data, key: Data) throws -> [TransferItem] {
        guard encrypted.count <= wireBytes, encrypted.count >= magic.count + 28, encrypted.starts(with: magic), key.count == 32 else { throw TransferFailure("Неверный формат передачи") }
        let box = try AES.GCM.SealedBox(combined: encrypted.dropFirst(magic.count))
        let plaintext = try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: authenticated)
        try Task.checkCancellation()
        let envelope = try JSONDecoder().decode(Envelope.self, from: plaintext)
        guard envelope.version == 1 else { throw TransferFailure("Обнови NotchHub для этой передачи") }
        try validate(envelope.items)
        return envelope.items
    }
    static func keyString(_ key: Data) -> String { key.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    static func parseKey(_ value: String) -> Data? {
        guard value.count == 43, value.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }),
              let key = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/") + "="), key.count == 32,
              keyString(key) == value else { return nil }
        return key
    }
    static func invitation(_ url: URL, endpoint: URL) throws -> (download: URL, key: Data) {
        var invitation = url
        if url.scheme?.lowercased() == "notchhub" {
            guard url.host == "receive", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.queryItems?.count == 1, let raw = components.queryItems?.first(where: { $0.name == "url" })?.value,
                  let nested = URL(string: raw, encodingInvalidCharacters: false) else { throw TransferFailure("Неверная ссылка NotchHub") }
            invitation = nested
        }
        guard let parts = URLComponents(url: invitation, resolvingAgainstBaseURL: false),
              parts.user == nil, parts.password == nil, parts.query == nil, let fragment = parts.fragment, let key = parseKey(fragment),
              let expected = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == expected.scheme?.lowercased(), parts.host?.lowercased() == expected.host?.lowercased(),
              (parts.port ?? (parts.scheme == "https" ? 443 : 80)) == (expected.port ?? (expected.scheme == "https" ? 443 : 80)) else {
            throw TransferFailure("Ссылка должна принадлежать настроенному серверу передачи")
        }
        let path = parts.path.components(separatedBy: "/")
        guard path.count == 3, path[0].isEmpty, path[1] == "s", validToken(path[2]), parts.percentEncodedPath == parts.path else { throw TransferFailure("Неверный адрес передачи") }
        return (endpoint.appendingPathComponent("transfers").appendingPathComponent(path[2]), key)
    }
    static func validToken(_ token: String) -> Bool {
        token.count == 43 && token.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }
    }
    static func items(from snapshots: [(Clip, URL?)]) throws -> [TransferItem] {
        guard !snapshots.isEmpty, snapshots.count <= itemLimit else { throw TransferFailure("Выбери от 1 до 20 элементов") }
        var items: [TransferItem] = [], bytes = 0
        for (clip, url) in snapshots {
            try Task.checkCancellation()
            if clip.kind == .text {
                guard let text = clip.text, text.utf8.count <= itemBytes else { throw TransferFailure("Текст недоступен или больше 30 МБ") }
                bytes += text.utf8.count
                items.append(TransferItem(kind: .text, title: clip.title, text: text))
            } else {
                guard let url, let asset = clip.asset, validFilename(asset),
                      url.lastPathComponent == asset else { throw TransferFailure("Файл недоступен") }
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard properties.isRegularFile == true, properties.isSymbolicLink != true, (properties.fileSize ?? itemBytes + 1) <= itemBytes else { throw TransferFailure("Файл недоступен или больше 30 МБ") }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: itemBytes + 1) ?? Data()
                guard data.count <= itemBytes else { throw TransferFailure("Файл больше 30 МБ") }
                bytes += data.count
                let ext = url.pathExtension
                let filename = clip.kind == .image ? "image.\(ext)" : (validFilename(clip.title) ? clip.title : asset)
                items.append(TransferItem(kind: clip.kind, title: clip.title, data: data, filename: filename))
            }
            guard bytes <= totalBytes else { throw TransferFailure("Общий размер передачи больше 60 МБ") }
        }
        try validate(items)
        return items
    }
}

private final class TransferRequest: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let limit: Int
    private let origin: URL
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var completion: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private let lock = NSLock()
    private var cancelled = false
    init(limit: Int, origin: URL) { self.limit = limit; self.origin = origin }
    static func perform(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        guard let origin = request.url else { throw TransferFailure("Неверный адрес сервера") }
        let loader = TransferRequest(limit: limit, origin: origin)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { loader.start(request, continuation: $0) }
        } onCancel: { loader.cancel() }
    }
    private func start(_ request: URLRequest, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        guard !cancelled else { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
        completion = continuation
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 30
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: config, delegate: self, delegateQueue: queue)
        self.session = session
        let task = session.dataTask(with: request)
        self.task = task
        lock.unlock()
        task.resume()
    }
    private func cancel() {
        lock.lock(); cancelled = true; let task = task; lock.unlock()
        task?.cancel()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward upload credentials, invitations or bodies to another endpoint.
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.url?.scheme == origin.scheme, http.url?.host == origin.host, http.url?.port == origin.port,
              http.expectedContentLength <= Int64(limit) else {
            failure = TransferFailure("Ответ сервера слишком большой или недоступен"); completionHandler(.cancel); return
        }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard buffer.count <= limit - data.count else { failure = TransferFailure("Ответ сервера превышает лимит"); dataTask.cancel(); return }
        buffer.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = completion, wasCancelled = cancelled
        completion = nil; self.session = nil; self.task = nil
        lock.unlock()
        if wasCancelled { continuation?.resume(throwing: CancellationError()) }
        else if let error = failure ?? error { continuation?.resume(throwing: error) }
        else if let response { continuation?.resume(returning: (buffer, response)) }
        else { continuation?.resume(throwing: TransferFailure("Нет ответа сервера")) }
        session.finishTasksAndInvalidate()
    }
}

@MainActor final class ClipboardTransfer: ObservableObject {
    typealias Transport = (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    let settings: TransferSettings
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var shareURL: URL?
    @Published private(set) var incoming: [TransferItem] = []
    @Published var selectedClips: [Clip] = []
    private var generation = UUID()
    private var airDropService: NSSharingService?
    private let transport: Transport
    private var operation: Task<Void, Never>?
    init(settings: TransferSettings = TransferSettings(), transport: Transport? = nil) {
        self.settings = settings
        self.transport = transport ?? { request, limit in try await TransferRequest.perform(request, limit: limit) }
    }
    func prepare(clips: [Clip]) { if !clips.isEmpty { selectedClips = clips } }
    func send(clips: [Clip], store: HubStore) {
        guard !busy else { return }
        guard store.preferences.isEnabled(.sharing) else { message = "Передача выключена в настройках"; return }
        guard let endpoint = settings.endpointURL, !settings.uploadKey.isEmpty else { message = "Сохрани адрес сервера и ключ отправки в настройках"; return }
        let token = UUID(); generation = token
        let snapshots = clips.map { ($0, store.assetURL($0)) }, uploadKey = settings.uploadKey
        busy = true; message = "Шифрую выбранные элементы…"; shareURL = nil
        operation = Task {
            defer { if generation == token { busy = false; operation = nil } }
            do {
                let worker = Task.detached(priority: .utility) {
                    let items = try TransferCodec.items(from: snapshots)
                    let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                    return (try TransferCodec.encode(items, key: key), key)
                }
                let prepared = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard generation == token else { return }
                message = "Отправляю зашифрованную передачу…"
                var request = URLRequest(url: endpoint.appendingPathComponent("transfers"))
                request.httpMethod = "POST"; request.httpBody = prepared.0
                request.setValue("Bearer " + uploadKey, forHTTPHeaderField: "Authorization")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                let (body, response) = try await transport(request, 4096)
                try Task.checkCancellation()
                guard response.statusCode == 201 else { throw TransferFailure(Self.serverMessage(response.statusCode)) }
                struct Created: Decodable { let id: String }
                let created = try JSONDecoder().decode(Created.self, from: body)
                guard TransferCodec.validToken(created.id) else { throw TransferFailure("Сервер вернул неверный адрес передачи") }
                guard generation == token else { return }
                var link = URLComponents(url: endpoint.appendingPathComponent("s").appendingPathComponent(created.id), resolvingAgainstBaseURL: false)!
                link.fragment = TransferCodec.keyString(prepared.1)
                shareURL = link.url
                message = "Готово: \(clips.count) отдельных элементов. Получатель откроет ссылку в браузере или NotchHub. Ссылка действует один час."
            } catch { if generation == token { message = "Не удалось отправить: \(error.localizedDescription)" } }
        }
    }
    func receive(url: URL) {
        guard !busy else { message = "Дождись завершения текущей передачи и открой ссылку ещё раз"; return }
        guard incoming.isEmpty else { message = "Сначала прими или отклони уже полученную передачу"; return }
        guard let endpoint = settings.endpointURL else { message = "Настрой адрес сервера передачи"; return }
        let invitation: (download: URL, key: Data)
        do { invitation = try TransferCodec.invitation(url, endpoint: endpoint) }
        catch { message = error.localizedDescription; return }
        let token = UUID(); generation = token; busy = true; message = "Загружаю зашифрованную передачу…"
        operation = Task {
            defer { if generation == token { busy = false; operation = nil } }
            do {
                let (data, response) = try await transport(URLRequest(url: invitation.download), TransferCodec.wireBytes)
                try Task.checkCancellation()
                guard generation == token else { return }
                guard response.statusCode == 200 else { throw TransferFailure(Self.serverMessage(response.statusCode)) }
                let worker = Task.detached(priority: .utility) { try TransferCodec.decode(data, key: invitation.key) }
                let items = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                try Task.checkCancellation()
                guard generation == token else { return }
                incoming = items; message = "Получено \(items.count) элементов. Проверь содержимое и подтверди добавление."
            } catch { if generation == token { message = "Не удалось получить: \(error.localizedDescription)" } }
        }
    }
    func cancel() {
        generation = UUID()
        operation?.cancel(); operation = nil
        busy = false; incoming = []; shareURL = nil; selectedClips = []; message = nil
    }
    func dismissIncoming() { incoming = []; message = nil }
    func copyLink() {
        guard let shareURL else { return }
        let board = NSPasteboard.general
        board.clearContents(); board.setString(shareURL.absoluteString, forType: .string)
        board.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        message = "Ссылка скопирована. Доступ к ней даёт доступ к передаче."
    }
    func airDrop() {
        guard let shareURL, let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: [shareURL]) else { message = "AirDrop недоступен на этом Mac"; return }
        airDropService = service; service.perform(withItems: [shareURL])
    }
    private static func serverMessage(_ status: Int) -> String {
        switch status {
        case 401, 403: return "Проверь ключ отправки"
        case 404, 410: return "Ссылка истекла или передача удалена"
        case 413: return "Передача превышает лимит сервера"
        case 507: return "Временное хранилище заполнено. Повтори позже"
        default: return "Сервер недоступен (\(status))"
        }
    }
}

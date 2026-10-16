import XCTest
import AppKit
import CryptoKit
@testable import NotchHub

final class ClipboardTransferTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)
    private func png() throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 3, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }
    func testThreeImagesRemainThreeIndependentItemsAfterAuthenticatedRoundtrip() throws {
        let data = try png()
        let items = (1...3).map { TransferItem(kind: .image, title: "Screen \($0)", data: data, filename: "screen-\($0).png") }
        let encrypted = try TransferCodec.encode(items, key: key)
        XCTAssertFalse(encrypted.range(of: Data("Screen 1".utf8)) != nil)
        let decoded = try TransferCodec.decode(encrypted, key: key)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded.map(\.id), items.map(\.id))
        XCTAssertEqual(decoded.map(\.title), ["Screen 1", "Screen 2", "Screen 3"])
        XCTAssertTrue(decoded.allSatisfy { $0.kind == .image && $0.data == data && $0.text == nil })
    }
    func testTamperingWrongKeyAndTruncationNeverProduceItems() throws {
        let item = TransferItem(kind: .text, title: "Private", text: "secret text")
        let encoded = try TransferCodec.encode([item], key: key)
        XCTAssertThrowsError(try TransferCodec.decode(encoded, key: Data(repeating: 8, count: 32)))
        var changed = encoded
        changed[changed.count - 1] ^= 1
        XCTAssertThrowsError(try TransferCodec.decode(changed, key: key))
        XCTAssertThrowsError(try TransferCodec.decode(encoded.dropLast(), key: key))
        XCTAssertThrowsError(try TransferCodec.decode(Data("NHTRANS1".utf8), key: key))
    }
    func testRejectsAmbiguousKindsBadImageExtensionsTraversalAndDuplicateIDs() throws {
        let data = try png()
        XCTAssertThrowsError(try TransferCodec.validate([TransferItem(kind: .image, title: "Fake", data: data, filename: "fake.jpg")]))
        XCTAssertThrowsError(try TransferCodec.validate([TransferItem(kind: .image, title: "Fake", data: Data("not an image".utf8), filename: "fake.png")]))
        XCTAssertThrowsError(try TransferCodec.validate([TransferItem(kind: .image, title: "Truncated", data: data.dropLast(16), filename: "fake.png")]))
        XCTAssertThrowsError(try TransferCodec.validate([TransferItem(kind: .file, title: "File", data: Data([1]), filename: "../private.txt")]))
        XCTAssertThrowsError(try TransferCodec.validate([TransferItem(kind: .text, title: "Text", text: "ok", data: data)]))
        let text = TransferItem(kind: .text, title: "Text", text: "ok")
        XCTAssertThrowsError(try TransferCodec.validate([text, text]))
        XCTAssertThrowsError(try TransferCodec.validate([]))
    }
    func testItemAndTotalLimitsAreEnforcedBeforeEncryption() throws {
        let many = (0...20).map { TransferItem(kind: .text, title: "\($0)", text: "x") }
        XCTAssertThrowsError(try TransferCodec.validate(many))
        let data = Data(repeating: 0, count: TransferCodec.itemBytes)
        let allowed = [TransferItem(kind: .file, title: "a", data: data, filename: "a.bin"), TransferItem(kind: .file, title: "b", data: data, filename: "b.bin")]
        XCTAssertNoThrow(try TransferCodec.validate(allowed))
        XCTAssertThrowsError(try TransferCodec.validate(allowed + [TransferItem(kind: .text, title: "overflow", text: "x")]))
        XCTAssertThrowsError(try TransferCodec.validate([TransferItem(kind: .file, title: "a", data: data + Data([1]), filename: "a.bin")]))
    }
    func testInvitationKeepsKeyOutOfDownloadAndRejectsForeignOriginAndTraversal() throws {
        let endpoint = try XCTUnwrap(URL(string: "https://example.com:9443"))
        let token = String(repeating: "a", count: 43)
        let fragment = TransferCodec.keyString(key)
        let url = try XCTUnwrap(URL(string: "https://example.com:9443/s/\(token)#\(fragment)"))
        let invitation = try TransferCodec.invitation(url, endpoint: endpoint)
        XCTAssertEqual(invitation.key, key)
        XCTAssertNil(invitation.download.fragment)
        XCTAssertEqual(invitation.download.absoluteString, "https://example.com:9443/transfers/\(token)")
        var deep = URLComponents(); deep.scheme = "notchhub"; deep.host = "receive"; deep.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        XCTAssertEqual(try TransferCodec.invitation(XCTUnwrap(deep.url), endpoint: endpoint).key, key)
        for raw in ["https://evil.example:9443/s/\(token)#\(fragment)", "https://example.com/s/\(token)#\(fragment)", "http://example.com:9443/s/\(token)#\(fragment)", "https://user@example.com:9443/s/\(token)#\(fragment)", "https://example.com:9443/s/../\(token)#\(fragment)", "https://example.com:9443/s/\(token)?extra=x#\(fragment)", "https://example.com:9443/s/\(token)#short"] {
            XCTAssertThrowsError(try TransferCodec.invitation(XCTUnwrap(URL(string: raw)), endpoint: endpoint))
        }
    }
    func testKeyRepresentationIsCanonicalAndEndpointMustBeHTTPSOrigin() throws {
        XCTAssertEqual(TransferCodec.parseKey(TransferCodec.keyString(key)), key)
        XCTAssertNil(TransferCodec.parseKey(String(repeating: "!", count: 43)))
        XCTAssertNil(TransferCodec.parseKey(key.base64EncodedString()))
        XCTAssertEqual(TransferSettings.validatedEndpoint("https://EXAMPLE.com:9443/")?.absoluteString, "https://example.com:9443")
        XCTAssertNotNil(TransferSettings.validatedEndpoint("http://127.0.0.1:9999"))
        for raw in ["http://example.com", "https://user:password@example.com", "https://example.com/path", "https://example.com?key=x", "https://example.com#key"] {
            XCTAssertNil(TransferSettings.validatedEndpoint(raw))
        }
    }
    func testUploadCredentialNeverEntersDefaultsAndFailedKeychainWriteRollsBackEndpoint() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var keys: [String: String] = [:], fail = false
        let settings = TransferSettings(defaults: defaults, readKey: { keys[$0] }, writeKey: { account, value in
            if fail { throw TransferFailure("test failure") }
            keys[account] = value
        })
        let secret = String(repeating: "s", count: 43)
        XCTAssertTrue(settings.save(endpoint: "https://example.com:9443", key: secret))
        XCTAssertEqual(keys["https://example.com:9443"], secret)
        XCTAssertEqual(defaults.string(forKey: TransferSettings.preferenceKey), "https://example.com:9443")
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == secret })
        fail = true
        XCTAssertFalse(settings.save(endpoint: "https://other.example", key: secret))
        XCTAssertEqual(settings.endpointURL?.absoluteString, "https://example.com:9443")
        XCTAssertEqual(defaults.string(forKey: TransferSettings.preferenceKey), "https://example.com:9443")
    }

    @MainActor func testCancelRejectsLateDownloadAndNeverSendsUploadCredentialOnReceive() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TransferSettings(defaults: defaults, readKey: { _ in String(repeating: "s", count: 43) }, writeKey: { _, _ in })
        let endpoint = try XCTUnwrap(settings.endpointURL)
        let encoded = try TransferCodec.encode([TransferItem(kind: .text, title: "Private", text: "late result")], key: key)
        let started = expectation(description: "download started")
        var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        let service = ClipboardTransfer(settings: settings, transport: { request, _ in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        })
        let url = try XCTUnwrap(URL(string: endpoint.absoluteString + "/s/" + String(repeating: "a", count: 43) + "#" + TransferCodec.keyString(key)))
        service.receive(url: url)
        await fulfillment(of: [started], timeout: 2)
        service.cancel()
        let response = try XCTUnwrap(HTTPURLResponse(url: endpoint, statusCode: 200, httpVersion: nil, headerFields: nil))
        pending?.resume(returning: (encoded, response))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(service.busy)
        XCTAssertTrue(service.incoming.isEmpty)
        XCTAssertNil(service.shareURL)
        XCTAssertNil(service.message)
    }

    @MainActor func testCancelBeforeEncodeCompletesNeverStartsUpload() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = TransferSettings(defaults: defaults, readKey: { _ in String(repeating: "s", count: 43) }, writeKey: { _, _ in })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = NSPasteboard.withUniqueName()
        defer { try? FileManager.default.removeItem(at: root); board.releaseGlobally() }
        let store = HubStore(root: root, monitor: false, pasteboard: board, preferences: HubPreferences(defaults: defaults))
        var requests = 0
        let service = ClipboardTransfer(settings: settings, transport: { _, _ in requests += 1; throw TransferFailure("Unexpected request") })
        let clip = Clip(kind: .text, title: "Secret", text: "private", fingerprint: "test")
        service.send(clips: [clip], store: store)
        service.cancel()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(service.busy)
        XCTAssertNil(service.shareURL)
    }
}

import XCTest
import AppKit
import Carbon
@testable import NotchHub

/// All checks use an injected transport: no live network, no real pasteboard writes.
final class TextCorrectionTests: XCTestCase {
    private let okBody = Data(#"{"text":"Привет, мир","model":"gpt-6-luna","effort":"none"}"#.utf8)
    private func makeSettings(_ defaults: UserDefaults, key: String? = String(repeating: "k", count: 40)) -> TransferSettings {
        TransferSettings(defaults: defaults, readKey: { _ in key }, writeKey: { _, _ in })
    }
    private func makeResponse(_ settings: TransferSettings, status: Int = 200) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: try XCTUnwrap(settings.endpointURL), statusCode: status, httpVersion: nil, headerFields: nil))
    }
    @MainActor private func waitUntilIdle(_ controller: TextCorrectionController) async {
        for _ in 0..<400 where controller.busy { await Task.yield(); try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    func testLocalSpellingEngineChangesOnlyUnprotectedWordRangesAndKeepsUnicodeLayout() {
        let source = "😀 Превет\nсеводня https://site.example/wrongurl wrongmail@example.com `wrongcode` /tmp/wrongpath C:\\Users\\wrongwin recieve/file foo_bar fooBar gpt-6-luna 2026\n```swift\nlet tick = \"`\"; let value = fencedword\n```"
        let ns = source as NSString
        func issue(_ word: String, correction: String?) -> LocalSpellingIssue {
            LocalSpellingIssue(range: ns.range(of: word), correction: correction)
        }
        let result = LocalSpellingEngine.apply([
            issue("Превет", correction: "Привет"), issue("севодня", correction: "сегодня"),
            issue("wrongurl", correction: "fixedurl"), issue("wrongmail", correction: "fixedmail"),
            issue("wrongcode", correction: "fixedcode"), issue("wrongpath", correction: "fixedpath"),
            issue("wrongwin", correction: "fixedwin"), issue("recieve", correction: "receive"), issue("foo_bar", correction: "foobar"),
            issue("fooBar", correction: "foobar"), issue("gpt-6-luna", correction: "GPT 6 luna"),
            issue("2026", correction: "2027"), issue("fencedword", correction: "fixedword")
        ], to: source)
        XCTAssertEqual(result.text, "😀 Привет\nсегодня https://site.example/wrongurl wrongmail@example.com `wrongcode` /tmp/wrongpath C:\\Users\\wrongwin recieve/file foo_bar fooBar gpt-6-luna 2026\n```swift\nlet tick = \"`\"; let value = fencedword\n```")
        XCTAssertEqual(result.correctedCount, 2)
        XCTAssertEqual(result.unresolvedCount, 0)
    }

    func testLocalSpellingEngineLeavesUncertainWordsUnchanged() {
        let source = "😀 qzxv\nnext line"
        let range = (source as NSString).range(of: "qzxv")
        let result = LocalSpellingEngine.apply([LocalSpellingIssue(range: range, correction: nil)], to: source)
        XCTAssertEqual(result.text, source)
        XCTAssertEqual(result.misspellingCount, 1)
        XCTAssertEqual(result.correctedCount, 0)
        XCTAssertEqual(result.unresolvedCount, 1)
    }

    func testLocalSpellingEngineProtectsUnclosedFencedCodeThroughEndOfInput() {
        let source = "Превет\n```swift\nlet value = севодня"
        let ns = source as NSString
        let result = LocalSpellingEngine.apply([
            LocalSpellingIssue(range: ns.range(of: "Превет"), correction: "Привет"),
            LocalSpellingIssue(range: ns.range(of: "севодня"), correction: "сегодня")
        ], to: source)
        XCTAssertEqual(result.text, "Привет\n```swift\nlet value = севодня")
        XCTAssertEqual(result.correctedCount, 1)
    }

    @MainActor func testLocalCorrectionWorksWithoutGatewayKeyOrConsentAndNeverUsesNetwork() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = makeSettings(defaults, key: nil), consent = TextCorrectionConsent(defaults: defaults)
        var networkRequests = 0, copies: [String] = [], applied: [TextCorrectionResult] = []
        let controller = TextCorrectionController(settings: settings, consent: consent, transport: { _, _ in
            networkRequests += 1; throw TextCorrectionFailure("unexpected network")
        }, changeCount: { 3 }, copy: { copies.append($0) }, localCorrector: { text in
            XCTAssertEqual(text, "Превет\nсеводня 😀")
            return LocalSpellingOutcome(text: "Привет\nсегодня 😀", misspellingCount: 2, correctedCount: 2, unresolvedCount: 0)
        })
        controller.correctLocally(text: "Превет\nсеводня 😀") { applied.append($0); return true }
        await waitUntilIdle(controller)
        XCTAssertEqual(networkRequests, 0)
        XCTAssertFalse(consent.isGranted(for: try XCTUnwrap(settings.endpointURL)))
        XCTAssertEqual(applied.map(\.text), ["Привет\nсегодня 😀"])
        XCTAssertEqual(applied.first?.provider, "Словарь macOS")
        XCTAssertEqual(copies, ["Привет\nсегодня 😀"])
        XCTAssertTrue(controller.message?.contains("локально") == true)
    }

    @MainActor func testNativeMacDictionaryCorrectsKnownRussianErrorsWhenAvailable() async throws {
        guard NSSpellChecker.shared.availableLanguages.contains(where: { $0.lowercased().hasPrefix("ru") }) else {
            throw XCTSkip("Russian spelling dictionary is unavailable")
        }
        let result = try await MacSpellingCorrector.correct("превет севодня")
        XCTAssertEqual(result.text, "привет сегодня")
        XCTAssertEqual(result.correctedCount, 2)
    }

    @MainActor func testNativeMacDictionaryFindsRussianTyposInFullSentenceAndMixedEnglish() async throws {
        guard NSSpellChecker.shared.availableLanguages.contains(where: { $0.lowercased().hasPrefix("ru") }),
              NSSpellChecker.shared.availableLanguages.contains(where: { $0.lowercased().hasPrefix("en") }) else {
            throw XCTSkip("Russian and English macOS spelling dictionaries are required")
        }
        let sentence = "превет севодня я работаю над программой и проверяю текст."
        let russian = try await MacSpellingCorrector.correct(sentence)
        XCTAssertEqual(russian.text, "привет сегодня я работаю над программой и проверяю текст.")
        XCTAssertEqual(russian.correctedCount, 2)

        let mixed = try await MacSpellingCorrector.correct("Превет teh recieved 😀")
        XCTAssertEqual(mixed.text, "Привет the received 😀")
        XCTAssertEqual(mixed.correctedCount, 3)
    }

    @MainActor func testLocalCorrectionCancellationCannotApplyOrCopyLateResult() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = makeSettings(defaults, key: nil), consent = TextCorrectionConsent(defaults: defaults)
        let started = expectation(description: "local spelling started")
        var pending: CheckedContinuation<LocalSpellingOutcome, Error>?
        var copies: [String] = [], applied = 0
        let controller = TextCorrectionController(settings: settings, consent: consent, changeCount: { 1 }, copy: { copies.append($0) }, localCorrector: { _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        })
        controller.correctLocally(text: "Превет") { _ in applied += 1; return true }
        await fulfillment(of: [started], timeout: 2)
        controller.cancel()
        pending?.resume(returning: LocalSpellingOutcome(text: "Привет", misspellingCount: 1, correctedCount: 1, unresolvedCount: 0))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(applied, 0)
        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(controller.result)
        XCTAssertFalse(controller.busy)
    }

    @MainActor func testLocalCorrectionDoesNotCopyOverClipboardChangedDuringCheck() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var count = 1, copies: [String] = [], applied: [TextCorrectionResult] = []
        let controller = TextCorrectionController(settings: makeSettings(defaults, key: nil), consent: TextCorrectionConsent(defaults: defaults),
            changeCount: { count }, copy: { copies.append($0) }, localCorrector: { _ in
                try await Task.sleep(nanoseconds: 10_000_000)
                count = 2
                return LocalSpellingOutcome(text: "Привет", misspellingCount: 1, correctedCount: 1, unresolvedCount: 0)
            })
        controller.correctLocally(text: "Превет") { applied.append($0); return true }
        await waitUntilIdle(controller)
        XCTAssertEqual(applied.map(\.text), ["Привет"])
        XCTAssertTrue(copies.isEmpty)
        XCTAssertFalse(controller.copied)
        XCTAssertTrue(controller.message?.contains("Буфер изменился") == true)
    }

    func testRequestCarriesGatewayKeyAndJSONBodyWithinLimits() throws {
        let endpoint = TransferSettings.defaultEndpoint
        let request = try TextCorrectionClient.request(text: "Превет мир", endpoint: endpoint, key: "secret-key")
        XCTAssertEqual(request.url?.absoluteString, "https://augreality.online:9443/correct")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, TextCorrectionLimits.timeout)
        let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String]
        XCTAssertEqual(body, ["text": "Превет мир"])
        XCTAssertThrowsError(try TextCorrectionClient.request(text: "   \n", endpoint: endpoint, key: "k"))
        XCTAssertThrowsError(try TextCorrectionClient.request(text: "a", endpoint: endpoint, key: ""))
        XCTAssertNoThrow(try TextCorrectionLimits.validate(String(repeating: "ы", count: 6000)))
        XCTAssertThrowsError(try TextCorrectionLimits.validate(String(repeating: "a", count: 6001)))
        // 1000 grapheme clusters but 25 000 bytes: the byte limit applies independently.
        XCTAssertThrowsError(try TextCorrectionLimits.validate(String(repeating: "👨‍👩‍👧‍👦", count: 1000)))
    }

    func testResponseDecodingAndStatusMessages() throws {
        XCTAssertEqual(try TextCorrectionClient.result(from: okBody, status: 200), TextCorrectionResult(text: "Привет, мир", model: "gpt-6-luna", effort: "none"))
        XCTAssertNil(try TextCorrectionClient.result(from: Data(#"{"text":"x"}"#.utf8), status: 200).model)
        XCTAssertThrowsError(try TextCorrectionClient.result(from: Data(#"{"text":""}"#.utf8), status: 200))
        XCTAssertThrowsError(try TextCorrectionClient.result(from: Data("<html>".utf8), status: 200))
        let huge = try JSONSerialization.data(withJSONObject: ["text": String(repeating: "a", count: TextCorrectionLimits.maxResultBytes + 1)])
        XCTAssertThrowsError(try TextCorrectionClient.result(from: huge, status: 200))
        for (status, fragment) in [(400, "отклонил"), (401, "ключ"), (413, "лимит"), (429, "минуту"), (502, "502"), (503, "недоступен"), (504, "504"), (500, "500")] {
            XCTAssertThrowsError(try TextCorrectionClient.result(from: okBody, status: status)) {
                XCTAssertTrue($0.localizedDescription.localizedCaseInsensitiveContains(fragment), "\(status): \($0.localizedDescription)")
            }
        }
    }

    @MainActor func testFirstUseRequiresConsentThenSendsOnceAndCopiesWhenClipboardUnchanged() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        // Sharing is off: proofreading only shares the gateway address and key.
        HubPreferences(defaults: defaults).setFeature(.sharing, enabled: false)
        let settings = makeSettings(defaults), consent = TextCorrectionConsent(defaults: defaults)
        let endpoint = try XCTUnwrap(settings.endpointURL), response = try makeResponse(settings)
        var requests: [URLRequest] = [], copies: [String] = [], applied: [String] = []
        let body = okBody
        let controller = TextCorrectionController(settings: settings, consent: consent, transport: { request, limit in
            requests.append(request); XCTAssertEqual(limit, TextCorrectionLimits.responseBytes)
            return (body, response)
        }, changeCount: { 7 }, copy: { copies.append($0) })
        controller.request(text: "Превет мир") { applied.append($0.text); return true }
        XCTAssertTrue(controller.pendingConsent?.contains("OpenAI") == true)
        XCTAssertTrue(requests.isEmpty); XCTAssertFalse(controller.busy)
        controller.declineConsent()
        XCTAssertNil(controller.pendingConsent); XCTAssertFalse(consent.isGranted(for: endpoint)); XCTAssertTrue(requests.isEmpty)
        controller.request(text: "Превет мир") { applied.append($0.text); return true }
        controller.confirmConsent()
        XCTAssertTrue(consent.isGranted(for: endpoint))
        XCTAssertTrue(controller.busy)
        await waitUntilIdle(controller)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer " + settings.uploadKey)
        XCTAssertEqual(applied, ["Привет, мир"])
        XCTAssertEqual(copies, ["Привет, мир"])
        XCTAssertTrue(controller.copied)
        XCTAssertEqual(controller.result?.model, "gpt-6-luna")
        controller.request(text: "Ещё текст") { _ in false }
        XCTAssertNil(controller.pendingConsent); XCTAssertTrue(controller.busy)
        await waitUntilIdle(controller)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(copies.count, 2)
        XCTAssertTrue(controller.message?.contains("скопировано") == true)
    }

    @MainActor func testClipboardChangeDuringRequestKeepsResultInlineWithoutCopying() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = makeSettings(defaults), consent = TextCorrectionConsent(defaults: defaults)
        consent.grant(for: try XCTUnwrap(settings.endpointURL))
        let response = try makeResponse(settings)
        let started = expectation(description: "request started")
        var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var count = 1, copies: [String] = []
        let controller = TextCorrectionController(settings: settings, consent: consent, transport: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }, changeCount: { count }, copy: { copies.append($0) })
        controller.request(text: "Превет мир") { _ in false }
        await fulfillment(of: [started], timeout: 2)
        count = 2
        pending?.resume(returning: (okBody, response))
        await waitUntilIdle(controller)
        XCTAssertTrue(copies.isEmpty); XCTAssertFalse(controller.copied)
        XCTAssertEqual(controller.result?.text, "Привет, мир")
        XCTAssertTrue(controller.message?.contains("изменился") == true)
        controller.copyResult()
        XCTAssertEqual(copies, ["Привет, мир"]); XCTAssertTrue(controller.copied)
    }

    @MainActor func testProtectedClipboardIsNeverAutomaticallyOverwritten() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = makeSettings(defaults), consent = TextCorrectionConsent(defaults: defaults)
        consent.grant(for: try XCTUnwrap(settings.endpointURL))
        let response = try makeResponse(settings)
        var copies: [String] = [], applied = 0
        let controller = TextCorrectionController(settings: settings, consent: consent, transport: { _, _ in (self.okBody, response) },
            changeCount: { 4 }, hasProtectedClipboard: { true }, copy: { copies.append($0) })
        controller.request(text: "Превет мир") { _ in applied += 1; return true }
        await waitUntilIdle(controller)
        XCTAssertEqual(applied, 1)
        XCTAssertTrue(copies.isEmpty)
        XCTAssertFalse(controller.copied)
        XCTAssertEqual(controller.result?.text, "Привет, мир")
        XCTAssertTrue(controller.message?.contains("защищённые данные") == true)
    }

    @MainActor func testChangedEndpointInvalidatesPendingConsentInsteadOfSendingToNewServer() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = makeSettings(defaults), consent = TextCorrectionConsent(defaults: defaults)
        var requests = 0
        let controller = TextCorrectionController(settings: settings, consent: consent, transport: { _, _ in
            requests += 1; throw TextCorrectionFailure("unexpected request")
        }, changeCount: { 0 }, copy: { _ in })
        controller.request(text: "Секретный текст") { _ in true }
        XCTAssertNotNil(controller.pendingConsent)
        XCTAssertTrue(settings.save(endpoint: "https://new-server.example", key: String(repeating: "n", count: 40)))
        controller.confirmConsent()
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(consent.isGranted(for: try XCTUnwrap(settings.endpointURL)))
        XCTAssertNil(controller.pendingConsent)
        XCTAssertFalse(controller.busy)
        XCTAssertTrue(controller.message?.contains("Адрес сервера изменился") == true)
    }

    @MainActor func testRevokedConsentDiscardsLateCorrectionWithoutApplyingOrCopying() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = makeSettings(defaults), consent = TextCorrectionConsent(defaults: defaults)
        consent.grant(for: try XCTUnwrap(settings.endpointURL))
        let response = try makeResponse(settings), started = expectation(description: "request started")
        var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var copies: [String] = [], applied = 0
        let controller = TextCorrectionController(settings: settings, consent: consent, transport: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }, changeCount: { 1 }, copy: { copies.append($0) })
        controller.request(text: "Секретный текст") { _ in applied += 1; return true }
        await fulfillment(of: [started], timeout: 2)
        consent.revoke()
        pending?.resume(returning: (okBody, response))
        await waitUntilIdle(controller)
        XCTAssertEqual(applied, 0)
        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(controller.result)
        XCTAssertFalse(controller.copied)
        XCTAssertTrue(controller.message?.contains("согласие изменились") == true)
    }

    @MainActor func testChangedServerDuringRequestDiscardsLateCorrection() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = makeSettings(defaults), consent = TextCorrectionConsent(defaults: defaults)
        consent.grant(for: try XCTUnwrap(settings.endpointURL))
        let response = try makeResponse(settings), started = expectation(description: "request started")
        var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var copies: [String] = [], applied = 0
        let controller = TextCorrectionController(settings: settings, consent: consent, transport: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }, changeCount: { 1 }, copy: { copies.append($0) })
        controller.request(text: "Секретный текст") { _ in applied += 1; return true }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(settings.save(endpoint: "https://new-server.example", key: String(repeating: "n", count: 40)))
        pending?.resume(returning: (okBody, response))
        await waitUntilIdle(controller)
        XCTAssertEqual(applied, 0)
        XCTAssertTrue(copies.isEmpty)
        XCTAssertNil(controller.result)
        XCTAssertFalse(controller.copied)
        XCTAssertTrue(controller.message?.contains("Настройки сервера") == true)
    }

    @MainActor func testCancelledRequestNeverAppliesOrCopiesLateResultAndErrorsKeepSource() async throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = makeSettings(defaults), consent = TextCorrectionConsent(defaults: defaults)
        consent.grant(for: try XCTUnwrap(settings.endpointURL))
        let started = expectation(description: "request started")
        var pending: CheckedContinuation<(Data, HTTPURLResponse), Error>?
        var copies: [String] = [], applied = 0, status = 200
        let unavailable = try makeResponse(settings, status: 503), late = try makeResponse(settings), body = okBody
        let controller = TextCorrectionController(settings: settings, consent: consent, transport: { _, _ in
            if status != 200 { return (Data(#"{"error":"busy"}"#.utf8), unavailable) }
            return try await withCheckedThrowingContinuation { pending = $0; started.fulfill() }
        }, changeCount: { 1 }, copy: { copies.append($0) })
        controller.request(text: "Превет мир") { _ in applied += 1; return true }
        await fulfillment(of: [started], timeout: 2)
        controller.cancel()
        XCTAssertFalse(controller.busy)
        pending?.resume(returning: (body, late))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(applied, 0); XCTAssertTrue(copies.isEmpty); XCTAssertNil(controller.result); XCTAssertNil(controller.message)
        status = 503
        controller.request(text: "Превет мир") { _ in applied += 1; return true }
        await waitUntilIdle(controller)
        XCTAssertEqual(applied, 0); XCTAssertTrue(copies.isEmpty); XCTAssertNil(controller.result)
        XCTAssertTrue(controller.message?.contains("недоступен") == true)
    }

    @MainActor func testConsentIsScopedToGatewayOriginAndMissingKeyBlocksSending() throws {
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let consent = TextCorrectionConsent(defaults: defaults)
        let first = try XCTUnwrap(URL(string: "https://augreality.online:9443")), second = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertFalse(consent.isGranted(for: first))
        consent.grant(for: first)
        XCTAssertTrue(consent.isGranted(for: first)); XCTAssertFalse(consent.isGranted(for: second))
        XCTAssertTrue(TextCorrectionConsent(defaults: defaults).isGranted(for: first))
        consent.revoke()
        XCTAssertNil(TextCorrectionConsent(defaults: defaults).origin)
        var requests = 0
        let keyless = TextCorrectionController(settings: makeSettings(defaults, key: nil), consent: consent, transport: { _, _ in requests += 1; throw TextCorrectionFailure("unexpected") }, changeCount: { 0 }, copy: { _ in })
        keyless.request(text: "Превет") { _ in true }
        XCTAssertEqual(requests, 0); XCTAssertFalse(keyless.busy); XCTAssertNil(keyless.pendingConsent)
        XCTAssertTrue(keyless.message?.contains("ключ") == true)
    }

    func testCorrectTextCommandBelongsToTextToolsAndFollowsFeatureToggle() throws {
        _ = NSApplication.shared
        XCTAssertEqual(HubCommand.correctText.feature, .textTools)
        XCTAssertEqual(HubCommand(rawValue: "correctText"), .correctText)
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HubPreferences(defaults: defaults)
        preferences.setFeature(.textTools, enabled: false)
        var ids: [UInt32] = []
        let shortcuts = CommandShortcuts(preferences: preferences, defaults: defaults, register: { _, id, _ in ids.append(id); return noErr }, action: { _ in })
        XCTAssertTrue(shortcuts.apply(ClipboardShortcut(keyCode: UInt32(kVK_ANSI_E), modifiers: UInt32(cmdKey | controlKey)), for: .correctText))
        XCTAssertTrue(ids.isEmpty)
        preferences.setFeature(.textTools, enabled: true)
        XCTAssertEqual(ids.count, 1)
        let sections = SectionSettings(defaults: defaults)
        sections.setCommand(.correctText, enabled: true)
        XCTAssertEqual(sections.current.visibleCommands(enabledFeatures: Set(HubFeature.allCases)), [.correctText])
        XCTAssertTrue(sections.current.visibleCommands(enabledFeatures: Set(HubFeature.allCases).subtracting([.textTools])).isEmpty)
    }
}

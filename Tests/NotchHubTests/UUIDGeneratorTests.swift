import XCTest
import AppKit
import SwiftUI
@testable import NotchHub

final class UUIDGeneratorTests: XCTestCase {
    func testCanonicalLowercaseUUIDVersionFourAndRFCVariant() {
        let pattern = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        let values = UUIDBatch.generate(count: 100)
        XCTAssertEqual(values.count, 100)
        for value in values {
            XCTAssertNotNil(value.range(of: pattern, options: .regularExpression))
            XCTAssertNotNil(UUID(uuidString: value))
        }
    }
    func testBatchLimitsHandleExtremeCountsAndCopyIsExactNewlineSeparatedText() {
        XCTAssertEqual(UUIDBatch.generate(count: Int.min).count, 1)
        XCTAssertEqual(UUIDBatch.generate(count: 0).count, 1)
        XCTAssertEqual(UUIDBatch.generate(count: 3).count, 3)
        XCTAssertEqual(UUIDBatch.generate(count: Int.max).count, 100)
        let values = UUIDBatch.generate(count: 3)
        XCTAssertEqual(UUIDBatch.text(values).components(separatedBy: "\n"), values)
        XCTAssertFalse(UUIDBatch.text(values).hasSuffix("\n"))
        XCTAssertEqual(UUIDBatch.text([values[0]]), values[0])
    }
    @MainActor func testCommandOpensInlineWithoutTouchingClipboardOrHistoryAndRespectsFeature() throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let preferences = HubPreferences(defaults: defaults)
        let store = HubStore(root: root, monitor: false, pasteboard: board, preferences: preferences)
        store.addText("saved history")
        board.setString("existing clipboard", forType: .string)
        let originalChangeCount = board.changeCount
        let originalArchive = store.archive.clips
        let delegate = AppDelegate()
        delegate.preferences = preferences; delegate.store = store
        let state = HubState()
        delegate.windows.present = { state.surface = $0 }
        delegate.perform(.generateUUID)
        XCTAssertEqual(state.surface?.key, "uuidGenerator")
        XCTAssertEqual(state.panelWidth, state.previewWidth)
        XCTAssertEqual(board.changeCount, originalChangeCount)
        XCTAssertEqual(board.string(forType: .string), "existing clipboard")
        XCTAssertEqual(store.archive.clips, originalArchive)
        delegate.windows.closeAll()
        preferences.setFeature(.textTools, enabled: false)
        delegate.perform(.generateUUID)
        XCTAssertNil(state.surface)
    }
    func testUUIDPinPersistsWithoutEnablingDisabledFeaturesOrChangingOtherPins() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HubPreferences(defaults: defaults)
        preferences.setFeature(.privacy, enabled: false)
        let sections = SectionSettings(defaults: defaults)
        sections.setCommand(.share, enabled: true)
        sections.setCommand(.generateUUID, enabled: true)
        preferences.setFeature(.textTools, enabled: false)
        let restored = SectionSettings(defaults: defaults)
        XCTAssertEqual(restored.current.pinnedCommands, [.share, .generateUUID])
        XCTAssertFalse(restored.current.visibleCommands(enabledFeatures: preferences.current.enabled).contains(.generateUUID))
        preferences.setFeature(.textTools, enabled: true)
        XCTAssertTrue(restored.current.visibleCommands(enabledFeatures: preferences.current.enabled).contains(.generateUUID))
        XCTAssertFalse(HubPreferences(defaults: defaults).isEnabled(.privacy))
    }
}

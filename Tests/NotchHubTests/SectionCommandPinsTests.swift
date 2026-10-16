import XCTest
@testable import NotchHub

final class SectionCommandPinsTests: XCTestCase {
    private func withDefaults(_ action: (UserDefaults) -> Void) {
        let name = UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        action(defaults)
    }
    func testExistingPreferencesDefaultToNoCommandPinsAndIgnoreUnknownValues() {
        withDefaults { defaults in
            defaults.set(5, forKey: SectionVisibility.preferenceKey)
            defaults.set(false, forKey: SectionVisibility.screenshotButtonKey)
            let legacy = SectionSettings(defaults: defaults)
            XCTAssertTrue(legacy.current.pinnedCommands.isEmpty)
            XCTAssertEqual(legacy.current.mask, 5); XCTAssertFalse(legacy.current.showScreenshotButton)
            defaults.set(["futureCommand", HubCommand.share.rawValue, HubCommand.share.rawValue, HubCommand.openTimers.rawValue], forKey: SectionVisibility.pinnedCommandsKey)
            XCTAssertEqual(SectionSettings(defaults: defaults).current.pinnedCommands, [.share, .openTimers])
        }
    }
    func testPinsPersistAndSectionAndScreenshotChangesPreserveThem() {
        withDefaults { defaults in
            let settings = SectionSettings(defaults: defaults)
            settings.setCommand(.openFavorites, enabled: true)
            settings.setCommand(.share, enabled: true)
            settings.set(.clipboard, enabled: false)
            settings.setScreenshotButton(enabled: false)
            let restored = SectionSettings(defaults: defaults)
            XCTAssertEqual(restored.current.pinnedCommands, [.openFavorites, .share])
            XCTAssertFalse(restored.current.isEnabled(.clipboard)); XCTAssertFalse(restored.current.showScreenshotButton)
            restored.setCommand(.share, enabled: false)
            let unpinned = SectionSettings(defaults: defaults)
            XCTAssertEqual(unpinned.current.pinnedCommands, [.openFavorites])
            XCTAssertEqual(unpinned.current.mask, restored.current.mask)
            XCTAssertFalse(unpinned.current.showScreenshotButton)
        }
    }
    func testPinChangesNotifyOnceAndDoNotChangeExistingPreferences() {
        withDefaults { defaults in
            defaults.set(10, forKey: SectionVisibility.preferenceKey)
            defaults.set(false, forKey: SectionVisibility.screenshotButtonKey)
            var changes: [SectionVisibility] = []
            let settings = SectionSettings(defaults: defaults) { changes.append($0) }
            settings.setCommand(.recognizeImage, enabled: true)
            settings.setCommand(.recognizeImage, enabled: true)
            settings.setCommand(.openTimers, enabled: false)
            XCTAssertEqual(changes.count, 1)
            XCTAssertEqual(changes[0].pinnedCommands, [.recognizeImage])
            XCTAssertEqual(defaults.integer(forKey: SectionVisibility.preferenceKey), 10)
            XCTAssertFalse(defaults.bool(forKey: SectionVisibility.screenshotButtonKey))
            settings.setCommand(.recognizeImage, enabled: false)
            XCTAssertEqual(changes.count, 2)
            XCTAssertTrue(SectionSettings(defaults: defaults).current.pinnedCommands.isEmpty)
        }
    }
    func testDisabledFeatureHidesCommandWithoutForgettingItsPin() {
        withDefaults { defaults in
            let settings = SectionSettings(defaults: defaults)
            settings.setCommand(.share, enabled: true)
            settings.setCommand(.openFavorites, enabled: true)
            let all = Set(HubFeature.allCases)
            XCTAssertEqual(settings.current.visibleCommands(enabledFeatures: all), [.openFavorites, .share])
            XCTAssertEqual(settings.current.visibleCommands(enabledFeatures: all.subtracting([.favorites])), [.share])
            XCTAssertEqual(settings.current.pinnedCommands, [.openFavorites, .share])
            XCTAssertEqual(SectionSettings(defaults: defaults).current.visibleCommands(enabledFeatures: all), [.openFavorites, .share])
            var hiddenContent = settings.current; hiddenContent.mask = 0
            XCTAssertTrue(hiddenContent.isEmpty)
            XCTAssertEqual(hiddenContent.visibleCommands(enabledFeatures: all), [.openFavorites, .share])
        }
    }
}

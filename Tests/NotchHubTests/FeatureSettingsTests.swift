import XCTest
@testable import NotchHub

final class FeatureSettingsTests: XCTestCase {
    func testPreferencesRoundtripAndFeatureDisablePreserveSettings() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HubPreferences(defaults: defaults)
        XCTAssertEqual(preferences.current.enabled, Set(HubFeature.allCases))
        XCTAssertEqual(preferences.current.historyLimit, 20)
        preferences.update { $0.historyLimit = 100; $0.diskLimitMB = 750; $0.expiryHours = 24; $0.excludedAppIDs = ["com.apple.keychainaccess"] }
        preferences.setFeature(.privacy, enabled: false)
        let restored = HubPreferences(defaults: defaults)
        XCTAssertEqual(restored.current, preferences.current)
        XCTAssertFalse(restored.isEnabled(.privacy))
        XCTAssertEqual(restored.current.excludedAppIDs, ["com.apple.keychainaccess"])
    }
    func testPreferencesNormalizeUntrustedLimitsAndExcludedApps() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HubPreferences(defaults: defaults)
        preferences.update { $0.historyLimit = -1; $0.diskLimitMB = 9999; $0.expiryHours = 3; $0.excludedAppIDs = [" app.one ", "", "app.one", "app.two\n"] }
        XCTAssertEqual(preferences.current.historyLimit, 20)
        XCTAssertEqual(preferences.current.diskLimitMB, 2000)
        XCTAssertEqual(preferences.current.expiryHours, 0)
        XCTAssertEqual(preferences.current.excludedAppIDs, ["app.one", "app.two"])
        preferences.update { $0.diskLimitMB = -1 }
        XCTAssertEqual(preferences.current.diskLimitMB, 50)
    }
    func testCorruptPreferencesLoadDefaultsWithoutWritingOrDeleting() throws {
        let name = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let invalid = Data("invalid-json".utf8)
        defaults.set(invalid, forKey: HubPreferences.preferenceKey)
        XCTAssertEqual(HubPreferences(defaults: defaults).current, .defaults)
        XCTAssertEqual(defaults.data(forKey: HubPreferences.preferenceKey), invalid)
    }
}

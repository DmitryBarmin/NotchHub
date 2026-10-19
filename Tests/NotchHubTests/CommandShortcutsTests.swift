import XCTest
import AppKit
import Carbon
@testable import NotchHub

final class CommandShortcutsTests: XCTestCase {
    private func send(_ kind: UInt32, id: UInt32, expected: OSStatus = noErr) throws {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event), noErr)
        let value = try XCTUnwrap(event)
        defer { ReleaseEvent(value) }
        var key = EventHotKeyID(signature: 0x4E48434D, id: id)
        XCTAssertEqual(SetEventParameter(value, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &key), noErr)
        XCTAssertEqual(SendEventToEventTarget(value, GetApplicationEventTarget()), expected)
    }
    func testUnassignedDisabledAndRemovedCommandsNeverRegister() throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HubPreferences(defaults: defaults)
        var registrations = 0, removals = 0
        let shortcuts = CommandShortcuts(preferences: preferences, defaults: defaults, register: { _, id, ref in
            registrations += 1; ref = OpaquePointer(bitPattern: Int(id)); return noErr
        }, unregister: { _ in removals += 1 }, action: { _ in })
        XCTAssertEqual(registrations, 0)
        preferences.setFeature(.favorites, enabled: false)
        let key = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | controlKey))
        XCTAssertTrue(shortcuts.apply(key, for: .openFavorites))
        XCTAssertEqual(registrations, 0)
        preferences.setFeature(.favorites, enabled: true)
        XCTAssertEqual(registrations, 1)
        preferences.setFeature(.favorites, enabled: false)
        XCTAssertEqual(removals, 1)
        XCTAssertEqual(shortcuts.current[.openFavorites], key)
        XCTAssertTrue(shortcuts.apply(nil, for: .openFavorites))
        preferences.setFeature(.favorites, enabled: true)
        XCTAssertEqual(registrations, 1)
    }
    func testFailedRebindAndDuplicatePreserveOldRegistrationAndPersistedAssignment() throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HubPreferences(defaults: defaults)
        var ids: [UInt32] = [], fail = false, calls: [HubCommand] = []
        let shortcuts = CommandShortcuts(preferences: preferences, defaults: defaults, register: { _, id, _ in
            if fail { return OSStatus(eventHotKeyExistsErr) }; ids.append(id); return noErr
        }, action: { calls.append($0) })
        let key = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | controlKey))
        XCTAssertTrue(shortcuts.apply(key, for: .openFavorites))
        let saved = defaults.data(forKey: CommandShortcuts.preferenceKey)
        XCTAssertFalse(shortcuts.apply(key, for: .share))
        fail = true
        XCTAssertFalse(shortcuts.apply(ClipboardShortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: key.modifiers), for: .openFavorites))
        XCTAssertEqual(shortcuts.current[.openFavorites], key)
        XCTAssertEqual(defaults.data(forKey: CommandShortcuts.preferenceKey), saved)
        try send(UInt32(kEventHotKeyPressed), id: try XCTUnwrap(ids.first))
        XCTAssertEqual(calls, [.openFavorites])
    }
    func testNativeReleaseRepeatSuppressionAndStaleEventsAfterRebindAndDisable() throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HubPreferences(defaults: defaults)
        var ids: [UInt32] = [], calls = 0
        let shortcuts = CommandShortcuts(preferences: preferences, defaults: defaults, register: { _, id, _ in ids.append(id); return noErr }, action: { _ in calls += 1 })
        let key = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(cmdKey | controlKey))
        XCTAssertTrue(shortcuts.apply(key, for: .openFavorites))
        let first = try XCTUnwrap(ids.last)
        try send(UInt32(kEventHotKeyPressed), id: first)
        try send(UInt32(kEventHotKeyPressed), id: first)
        XCTAssertEqual(calls, 1)
        try send(UInt32(kEventHotKeyReleased), id: first)
        try send(UInt32(kEventHotKeyPressed), id: first)
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(shortcuts.apply(ClipboardShortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: key.modifiers), for: .openFavorites))
        let second = try XCTUnwrap(ids.last)
        try send(UInt32(kEventHotKeyPressed), id: second)
        try send(UInt32(kEventHotKeyReleased), id: first, expected: OSStatus(eventNotHandledErr))
        try send(UInt32(kEventHotKeyPressed), id: second)
        XCTAssertEqual(calls, 3)
        preferences.setFeature(.favorites, enabled: false)
        try send(UInt32(kEventHotKeyPressed), id: second, expected: OSStatus(eventNotHandledErr))
        XCTAssertEqual(calls, 3)
    }
    func testSavedAssignmentsRestoreOnlyEnabledFeatures() throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = HubPreferences(defaults: defaults)
        preferences.setFeature(.sharing, enabled: false)
        let key = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: UInt32(cmdKey | controlKey))
        defaults.set(try JSONEncoder().encode([HubCommand.share.rawValue: key]), forKey: CommandShortcuts.preferenceKey)
        var registered = 0
        let shortcuts = CommandShortcuts(preferences: preferences, defaults: defaults, register: { _, _, _ in registered += 1; return noErr }, action: { _ in })
        XCTAssertEqual(shortcuts.current[.share], key)
        XCTAssertEqual(registered, 0)
        preferences.setFeature(.sharing, enabled: true)
        XCTAssertEqual(registered, 1)
    }
    func testUUIDShortcutPersistsAndRegistersOnlyWhenTextToolsEnabled() throws {
        _ = NSApplication.shared
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HubPreferences(defaults: defaults)
        preferences.setFeature(.textTools, enabled: false)
        let key = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_U), modifiers: UInt32(cmdKey | controlKey))
        var ids: [UInt32] = []
        var commands: [HubCommand] = []
        let shortcuts = CommandShortcuts(preferences: preferences, defaults: defaults, register: { _, id, _ in ids.append(id); return noErr }, action: { commands.append($0) })
        XCTAssertTrue(shortcuts.apply(key, for: .generateUUID))
        XCTAssertTrue(ids.isEmpty)
        preferences.setFeature(.textTools, enabled: true)
        try send(UInt32(kEventHotKeyPressed), id: try XCTUnwrap(ids.last))
        XCTAssertEqual(commands, [.generateUUID])
        let saved = try XCTUnwrap(defaults.data(forKey: CommandShortcuts.preferenceKey))
        XCTAssertEqual(try JSONDecoder().decode([String: ClipboardShortcut].self, from: saved)[HubCommand.generateUUID.rawValue], key)
        preferences.setFeature(.textTools, enabled: false)
        XCTAssertEqual(shortcuts.current[.generateUUID], key)
        try send(UInt32(kEventHotKeyPressed), id: try XCTUnwrap(ids.last), expected: OSStatus(eventNotHandledErr))
    }

}

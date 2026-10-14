import XCTest
import AppKit
import Carbon
import UniformTypeIdentifiers
@testable import NotchHub

final class StoreTests: XCTestCase {
    func testFloatingIslandGapRemainsInsideHoverArea() {
        let screen = CGRect(x: 1470, y: 0, width: 1920, height: 1080)
        let panel = CGRect(x: screen.midX - 52, y: 1058, width: 104, height: 16)
        XCTAssertTrue(HubState.insideHub(CGPoint(x: screen.midX, y: 1077), panel: panel, screen: screen, notchWidth: 102))
        XCTAssertTrue(HubState.insideHub(CGPoint(x: screen.midX, y: 1080), panel: panel, screen: screen, notchWidth: 102))
        XCTAssertFalse(HubState.insideHub(CGPoint(x: screen.midX + 60, y: 1077), panel: panel, screen: screen, notchWidth: 102))
        XCTAssertFalse(HubState.insideHub(CGPoint(x: screen.midX, y: 1081), panel: panel, screen: screen, notchWidth: 102))
    }
    func testNativeHotKeyDispatchAdvancesAndCommitsOnlyAfterCommandRelease() throws {
        _ = NSApplication.shared
        var presses = 0, commits = 0
        var modifiers = UInt32(cmdKey)
        let hotKeys = ClipboardHotKeys(advance: { presses += 1 }, finish: { commits += 1 }, modifiers: { modifiers })
        XCTAssertNil(hotKeys.error)
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event), noErr)
        let hotKeyEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(hotKeyEvent); hotKeys.cancelSession() }
        var id = EventHotKeyID(signature: 0x4E484342, id: 1)
        XCTAssertEqual(SetEventParameter(hotKeyEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id), noErr)
        XCTAssertEqual(SendEventToEventTarget(hotKeyEvent, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(presses, 1)
        XCTAssertNil(hotKeys.error)
        id.id = 2
        XCTAssertEqual(SetEventParameter(hotKeyEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &id), noErr)
        XCTAssertEqual(SendEventToEventTarget(hotKeyEvent, GetApplicationEventTarget()), noErr)
        XCTAssertEqual(presses, 2)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(commits, 0)
        modifiers = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(commits, 1)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(commits, 1)
    }
    func testEachDisplayUsesItsOwnTopCenterTrigger() {
        let builtIn = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let external = CGRect(x: 1470, y: -124, width: 1920, height: 1080)
        let externalEdge = CGPoint(x: external.midX, y: external.maxY)
        XCTAssertTrue(HubState.atTrigger(externalEdge, screen: external, notchWidth: 158))
        XCTAssertFalse(HubState.atTrigger(externalEdge, screen: builtIn, notchWidth: 179))
        XCTAssertFalse(HubState.atTrigger(CGPoint(x: external.midX, y: external.maxY - 24), screen: external, notchWidth: 158))
        let above = CGRect(x: -300, y: 956, width: 1920, height: 1080)
        XCTAssertTrue(HubState.atTrigger(CGPoint(x: above.midX, y: above.maxY), screen: above, notchWidth: 158))
        XCTAssertFalse(HubState.atTrigger(CGPoint(x: above.midX, y: builtIn.maxY), screen: above, notchWidth: 158))
    }
    func testClipboardCycleWrapsAndResets() {
        let ids = [UUID(), UUID(), UUID()]
        var cycle = ClipboardCycle()
        cycle.begin(ids: ids)
        XCTAssertEqual(cycle.selectedID, ids[0])
        cycle.advance(); XCTAssertEqual(cycle.selectedID, ids[1])
        cycle.advance(); XCTAssertEqual(cycle.selectedID, ids[2])
        cycle.advance(); XCTAssertEqual(cycle.selectedID, ids[0])
        XCTAssertEqual(cycle.finish(), ids[0])
        XCTAssertNil(cycle.selectedID)
        cycle.begin(ids: []); cycle.advance()
        XCTAssertNil(cycle.finish())
        cycle.begin(ids: [ids[2]]); cycle.advance()
        XCTAssertEqual(cycle.finish(), ids[2])
    }
    func testKeyboardChoiceCopiesOnCommitWithoutReorderingHistory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: pb)
        store.addText("older"); store.addText("latest")
        pb.setString("original clipboard", forType: .string)
        let history = store.archive.clips
        var cycle = ClipboardCycle()
        cycle.begin(ids: history.map(\.id)); cycle.advance()
        XCTAssertEqual(pb.string(forType: .string), "original clipboard")
        let id = try XCTUnwrap(cycle.finish())
        store.copy(try XCTUnwrap(store.archive.clips.first(where: { $0.id == id })))
        store.capture()
        XCTAssertEqual(pb.string(forType: .string), "older")
        XCTAssertEqual(store.archive.clips, history)
    }
    func testTopEdgeDoesNotAlternateOpenAndClose() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let panel = CGRect(x: 562.5, y: 790, width: 345, height: 166)
        let edge = CGPoint(x: 735, y: 956)
        XCTAssertTrue(HubState.atTrigger(edge, screen: screen, notchWidth: 179))
        XCTAssertTrue(HubState.insideHub(edge, panel: panel, screen: screen, notchWidth: 179))
        XCTAssertFalse(HubState.insideHub(CGPoint(x: 735, y: 789), panel: panel, screen: screen, notchWidth: 179))
    }
    func testClearClipboardPreservesShelfAndNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: pb)
        store.addText("history"); store.addText("keep", shelf: true); store.setNote("note")
        pb.setString("system clipboard", forType: .string)
        store.clearClipboard(); store.capture()
        XCTAssertTrue(store.archive.clips.isEmpty)
        XCTAssertNil(pb.string(forType: .string))
        XCTAssertEqual(store.archive.shelf.first?.text, "keep")
        XCTAssertEqual(store.archive.note, "note")
        XCTAssertTrue(HubStore(root: root, monitor: false, pasteboard: pb).archive.clips.isEmpty)
    }
    func testTriggerRequiresTopEdgeAboveNotch() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        XCTAssertTrue(HubState.atTrigger(CGPoint(x: 735, y: 955.5), screen: screen, notchWidth: 179))
        for point in [CGPoint(x: 735, y: 924), CGPoint(x: 735, y: 950), CGPoint(x: 640, y: 955.5), CGPoint(x: 900, y: 955.5)] {
            XCTAssertFalse(HubState.atTrigger(point, screen: screen, notchWidth: 179))
        }
    }
    func withStore(_ body: (HubStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(HubStore(root: root, monitor: false), root)
    }
    func testLimitAndDedupAndPersistence() throws {
        try withStore { store, root in
            for i in 0..<25 { store.addText("item \(i)") }
            XCTAssertEqual(store.archive.clips.count, 20)
            XCTAssertEqual(store.archive.clips.last?.text, "item 5")
            store.addText("item 10")
            XCTAssertEqual(store.archive.clips.count, 20)
            XCTAssertEqual(store.archive.clips.first?.text, "item 10")
            store.setNote("сохрани мысль")
            store.flushPendingNote()
            let restored = HubStore(root: root, monitor: false)
            XCTAssertEqual(restored.archive.clips, store.archive.clips)
            XCTAssertEqual(restored.archive.note, "сохрани мысль")
        }
    }
    func testOwnedCopyEvictionAndSharedAsset() throws {
        try withStore { store, root in
            let original = root.appendingPathComponent("original.txt")
            try Data("fixture".utf8).write(to: original)
            store.addFile(original, shelf: false)
            let clip = try XCTUnwrap(store.archive.clips.first)
            let copy = try XCTUnwrap(store.assetURL(clip))
            XCTAssertNotEqual(copy, original)
            var shelfClip = clip; shelfClip.id = UUID(); store.insert(shelfClip, shelf: true)
            for i in 0..<20 { store.addText("text \(i)") }
            XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
            store.clear(shelf: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
            XCTAssertEqual(try String(contentsOf: original), "fixture")
        }
    }
    func testImageRoundTrip() throws {
        try withStore { store, root in
            let image = NSImage(size: NSSize(width: 24, height: 24))
            image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 24, height: 24).fill(); image.unlockFocus()
            store.addImage(try XCTUnwrap(image.tiffRepresentation))
            let clip = try XCTUnwrap(store.archive.clips.first)
            XCTAssertEqual(clip.kind, .image)
            XCTAssertNotNil(NSImage(contentsOf: try XCTUnwrap(store.assetURL(clip))))
            let dropped = root.appendingPathComponent("drop.png")
            try Data(contentsOf: try XCTUnwrap(store.assetURL(clip))).write(to: dropped)
            store.addFile(dropped)
            XCTAssertEqual(store.archive.shelf.first?.kind, .image)
        }
    }
    func testClockPauseResumeDeadline() {
        let clock = FocusClock(); let now = Date(timeIntervalSince1970: 10_000)
        clock.reset(minutes: 5); clock.start(now: now)
        clock.tick(now: now.addingTimeInterval(70))
        XCTAssertEqual(clock.remaining, 230, accuracy: 0.01)
        clock.pause(now: now.addingTimeInterval(75))
        XCTAssertEqual(clock.remaining, 225, accuracy: 0.01)
        clock.start(now: now.addingTimeInterval(90))
        clock.tick(now: now.addingTimeInterval(315))
        XCTAssertEqual(clock.remaining, 0); XCTAssertFalse(clock.running); XCTAssertTrue(clock.completed)
    }
    func testClipboardCapturePauseConcealedAndCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        pb.setString("before launch", forType: .string)
        let store = HubStore(root: root, monitor: false, pasteboard: pb)
        store.capture(); XCTAssertTrue(store.archive.clips.isEmpty)
        pb.clearContents(); pb.setString("hello", forType: .string)
        store.capture(); XCTAssertEqual(store.archive.clips.first?.text, "hello")
        store.paused = true
        pb.clearContents(); pb.setString("paused", forType: .string)
        store.capture(); store.paused = false; store.capture()
        XCTAssertEqual(store.archive.clips.count, 1)
        pb.clearContents(); pb.setString("secret", forType: .string)
        pb.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        store.capture(); XCTAssertEqual(store.archive.clips.count, 1)
        store.copy(try XCTUnwrap(store.archive.clips.first))
        XCTAssertEqual(pb.string(forType: .string), "hello")
        store.capture(); XCTAssertEqual(store.archive.clips.count, 1)
    }
    func testNoteAutosaveCoalescesAndFlushesLatestText() throws {
        try withStore { store, root in
            store.addText("seed")
            let saved = root.appendingPathComponent("history.json")
            let before = try Data(contentsOf: saved)
            for n in 0..<100 { store.setNote("note \(n)") }
            XCTAssertTrue(store.noteSavePending)
            XCTAssertEqual(try Data(contentsOf: saved), before)
            RunLoop.main.run(until: Date().addingTimeInterval(0.45))
            XCTAssertFalse(store.noteSavePending)
            XCTAssertEqual(HubStore(root: root, monitor: false).archive.note, "note 99")
            store.setNote("final edit before quit")
            store.finishImports()
            XCTAssertEqual(HubStore(root: root, monitor: false).archive.note, "final edit before quit")
        }
    }
    func testClockSchedulesOnlyWhileRunning() {
        let clock = FocusClock()
        XCTAssertFalse(clock.hasScheduledTick)
        clock.start(); XCTAssertTrue(clock.hasScheduledTick)
        clock.pause(); XCTAssertFalse(clock.hasScheduledTick)
        clock.start(); clock.reset(); XCTAssertFalse(clock.hasScheduledTick)
        let now = Date(); clock.start(now: now)
        clock.tick(now: now.addingTimeInterval(1501))
        XCTAssertFalse(clock.hasScheduledTick)
    }
    func testImageCacheDownsamplesAndReusesDecodedPixels() throws {
        try withStore { store, _ in
            let image = NSImage(size: NSSize(width: 1024, height: 512))
            image.lockFocus(); NSColor.red.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 512).fill(); image.unlockFocus()
            store.addImage(try XCTUnwrap(image.tiffRepresentation))
            let url = try XCTUnwrap(store.assetURL(try XCTUnwrap(store.archive.clips.first)))
            let cache = AssetImageCache()
            let first = try XCTUnwrap(cache.image(url: url, maxPixelSize: 64))
            XCTAssertLessThanOrEqual(max(first.size.width, first.size.height), 64)
            XCTAssertTrue(first === cache.image(url: url, maxPixelSize: 64))
            XCTAssertNil(cache.image(url: url.appendingPathExtension("missing"), maxPixelSize: 64))
        }
    }
    func testBackgroundImportsPreserveCopyOrderAndDoNotRestoreClearedHistory() throws {
        try withStore { store, root in
            let file = root.appendingPathComponent("file.txt")
            try Data("owned file".utf8).write(to: file)
            store.enqueueFile(file, shelf: false)
            store.addText("newer")
            store.setNote("keep latest note")
            store.finishImports()
            XCTAssertEqual(store.archive.clips.map(\.kind), [.text, .file])
            XCTAssertEqual(store.archive.note, "keep latest note")
            XCTAssertEqual(HubStore(root: root, monitor: false).archive.clips, store.archive.clips)
            store.enqueueFile(file, shelf: false)
            store.clear(shelf: false)
            store.finishImports()
            XCTAssertTrue(store.archive.clips.isEmpty)
            XCTAssertEqual(store.archive.note, "keep latest note")
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).contains { $0.lastPathComponent.hasPrefix(".import-") })
        }
    }

    func testBackgroundImageRetainsEncodedDataAndNativeClipboardType() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: pb)
        let image = NSImage(size: NSSize(width: 32, height: 16))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 32, height: 16).fill(); image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        store.enqueueImage(data)
        store.finishImports()
        let clip = try XCTUnwrap(store.archive.clips.first)
        let url = try XCTUnwrap(store.assetURL(clip))
        XCTAssertEqual(try Data(contentsOf: url), data)
        store.copy(clip)
        XCTAssertEqual(pb.data(forType: .tiff), data)
        store.capture()
        XCTAssertEqual(store.archive.clips.count, 1)
    }

    func testPendingClipboardImageCannotBeOverwrittenByHotKeyRelease() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: pb)
        store.addText("old clipboard text")
        let image = NSImage(size: NSSize(width: 32, height: 16))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 32, height: 16).fill(); image.unlockFocus()
        let data = try XCTUnwrap(image.tiffRepresentation)
        pb.clearContents(); pb.setData(data, forType: .tiff)
        let delegate = AppDelegate(); delegate.store = store
        delegate.advanceClipboard()
        XCTAssertEqual(store.pendingClipboardImports, 1)
        XCTAssertNil(delegate.cycle.selectedID)
        delegate.finishClipboard()
        XCTAssertEqual(pb.data(forType: .tiff), data)
        XCTAssertNil(pb.string(forType: .string))
        store.finishImports()
        XCTAssertEqual(store.pendingClipboardImports, 0)
        XCTAssertEqual(store.archive.clips.first?.kind, .image)
    }
    func testJPEGCopyPublishesOriginalBytesWithoutTIFFExpansion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let pb = NSPasteboard.withUniqueName()
        defer { pb.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: pb)
        let image = NSImage(size: NSSize(width: 512, height: 512))
        image.lockFocus(); NSColor.blue.setFill(); NSRect(x: 0, y: 0, width: 512, height: 512).fill(); image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        store.addImage(jpeg)
        store.copy(try XCTUnwrap(store.archive.clips.first))
        XCTAssertEqual(pb.data(forType: NSPasteboard.PasteboardType(UTType.jpeg.identifier)), jpeg)
        // pb.types includes system-convertible TIFF; item.types is what we publish.
        XCTAssertEqual(pb.pasteboardItems?.first?.types, [NSPasteboard.PasteboardType(UTType.jpeg.identifier)])
        XCTAssertTrue(pb.canReadObject(forClasses: [NSImage.self], options: nil))
        XCTAssertNotNil((pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage])?.first)
    }
    func testDecodeQueueIsSerialCoalescesRequestsAndSkipsCancelledWaiter() async throws {
        let started = expectation(description: "first decoder started")
        let gate = DispatchSemaphore(value: 0), statistics = NSLock()
        var active = 0, maxActive = 0, decoded: [String] = []
        let cache = AssetImageCache(decoder: { url, _ in
            statistics.lock(); active += 1; maxActive = max(maxActive, active); decoded.append(url.path); statistics.unlock()
            if url.path == "/first" { started.fulfill(); _ = gate.wait(timeout: .now() + 3) }
            let image = NSImage(size: NSSize(width: 32, height: 32))
            statistics.lock(); active -= 1; statistics.unlock()
            return image
        })
        let first = Task { await cache.load(url: URL(fileURLWithPath: "/first"), maxPixelSize: 1400) }
        await fulfillment(of: [started], timeout: 1)
        let duplicate = Task { await cache.load(url: URL(fileURLWithPath: "/first"), maxPixelSize: 1400) }
        let queued = Task { await cache.load(url: URL(fileURLWithPath: "/second"), maxPixelSize: 1400) }
        let cancelled = Task { await cache.load(url: URL(fileURLWithPath: "/cancelled"), maxPixelSize: 1400) }
        cancelled.cancel()
        let cancelledImage = await cancelled.value
        XCTAssertNil(cancelledImage)
        let deadline = Date().addingTimeInterval(1)
        while cache.pendingDecodeRequests < 3 && Date() < deadline { await Task.yield() }
        XCTAssertEqual(cache.pendingDecodeRequests, 3)
        gate.signal()
        let firstImage = await first.value, duplicateImage = await duplicate.value
        let secondImage = await queued.value
        XCTAssertNotNil(secondImage)
        XCTAssertTrue(firstImage === duplicateImage)
        XCTAssertEqual(maxActive, 1)
        XCTAssertEqual(decoded, ["/first", "/second"])
        XCTAssertEqual(cache.pendingDecodeRequests, 0)
    }

    func testShortcutPreferencePersistenceValidationAndConflictRollback() throws {
        let domain = "NotchHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        XCTAssertEqual(ClipboardShortcut.load(from: defaults), .standard)
        let candidate = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey))
        let conflict = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | shiftKey))
        var changed = 0, registrations = 0
        let hotKeys = ClipboardHotKeys(advance: {}, finish: {}, register: { shortcut, _, _ in
            registrations += 1
            return shortcut == conflict ? OSStatus(-9878) : noErr
        })
        let settings = ShortcutSettings(hotKeys: hotKeys, defaults: defaults) { _ in changed += 1 }
        XCTAssertTrue(settings.apply(candidate))
        XCTAssertEqual(ClipboardShortcut.load(from: defaults), candidate)
        XCTAssertEqual(hotKeys.shortcut, candidate)
        XCTAssertFalse(settings.apply(conflict))
        XCTAssertNotNil(settings.message)
        XCTAssertEqual(hotKeys.shortcut, candidate)
        XCTAssertEqual(settings.current, candidate)
        XCTAssertEqual(ClipboardShortcut.load(from: defaults), candidate)
        XCTAssertEqual(changed, 1)
        let calls = registrations
        XCTAssertFalse(settings.apply(ClipboardShortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(shiftKey))))
        XCTAssertEqual(registrations, calls)
        XCTAssertTrue(settings.apply(.standard))
        XCTAssertEqual(ClipboardShortcut.load(from: defaults), .standard)
        defaults.set(Data("broken".utf8), forKey: ClipboardShortcut.preferenceKey)
        XCTAssertEqual(ClipboardShortcut.load(from: defaults), .standard)
    }
    func testChosenPrimaryModifierControlsCommitAndRebindingCancelsSession() {
        let shortcut = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey | optionKey))
        var held = UInt32(controlKey), presses = 0, commits = 0
        var registered: [ClipboardShortcut] = []
        let hotKeys = ClipboardHotKeys(advance: { presses += 1 }, finish: { commits += 1 }, shortcut: shortcut, register: { value, _, _ in
            registered.append(value); return noErr
        }, modifiers: { held })
        hotKeys.pressed(); hotKeys.pressed()
        XCTAssertEqual(presses, 2)
        XCTAssertEqual(registered.last, ClipboardShortcut(keyCode: UInt32(kVK_ANSI_F), modifiers: UInt32(controlKey)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(commits, 0)
        held = UInt32(optionKey)
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(commits, 1)
        XCTAssertFalse(hotKeys.sessionActive)
        held = UInt32(controlKey); hotKeys.pressed()
        XCTAssertTrue(hotKeys.rebind(to: .standard))
        XCTAssertFalse(hotKeys.sessionActive)
        held = 0
        RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(commits, 1)
    }
    func testSingleModifierShortcutReusesInitialRegistrationForCycling() {
        let shortcut = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(optionKey))
        var registrations = 0, held = UInt32(optionKey), commits = 0
        let hotKeys = ClipboardHotKeys(advance: {}, finish: { commits += 1 }, shortcut: shortcut, register: { _, _, _ in registrations += 1; return noErr }, modifiers: { held })
        hotKeys.pressed(); hotKeys.pressed()
        XCTAssertEqual(registrations, 1)
        held = 0; RunLoop.main.run(until: Date().addingTimeInterval(0.06))
        XCTAssertEqual(commits, 1)
    }

    func testNormalPasteCannotBecomeGlobalCyclingShortcutAndStoredValueFallsBack() throws {
        let domain = "NotchHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        var registrations = 0
        let hotKeys = ClipboardHotKeys(advance: {}, finish: {}, register: { _, _, _ in registrations += 1; return noErr })
        let settings = ShortcutSettings(hotKeys: hotKeys, defaults: defaults)
        let paste = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey))
        XCTAssertFalse(paste.isValid)
        XCTAssertFalse(settings.apply(paste))
        XCTAssertEqual(registrations, 1)
        XCTAssertNil(defaults.data(forKey: ClipboardShortcut.preferenceKey))
        XCTAssertEqual(hotKeys.shortcut, .standard)
        XCTAssertTrue(settings.message?.contains("обычной вставки") == true)
        defaults.set(try JSONEncoder().encode(paste), forKey: ClipboardShortcut.preferenceKey)
        XCTAssertEqual(ClipboardShortcut.load(from: defaults), .standard)
    }
    func testRestoreDefaultResetsUnsavedChoicesWhenActiveShortcutAlreadyDefault() throws {
        let domain = "NotchHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let hotKeys = ClipboardHotKeys(advance: {}, finish: {}, register: { _, _, _ in noErr })
        let settings = ShortcutSettings(hotKeys: hotKeys, defaults: defaults)
        var draft = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(controlKey | shiftKey))
        XCTAssertEqual(settings.current, .standard)
        XCTAssertTrue(settings.restoreDefault(draft: &draft))
        XCTAssertEqual(draft, .standard)
        XCTAssertEqual(settings.current, .standard)
        XCTAssertEqual(ClipboardShortcut.load(from: defaults), .standard)
    }

    func testSectionVisibilityPersistsIndependentlyAndAllowsAllHidden() throws {
        let domain = "NotchHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        ClipboardShortcut.standard.save(to: defaults)
        let shortcut = defaults.data(forKey: ClipboardShortcut.preferenceKey)
        let settings = SectionSettings(defaults: defaults)
        XCTAssertEqual(settings.current, .all)
        for section in HubSection.allCases { settings.set(section, enabled: false) }
        XCTAssertTrue(settings.current.isEmpty)
        XCTAssertTrue(SectionSettings(defaults: defaults).current.isEmpty)
        XCTAssertEqual(defaults.data(forKey: ClipboardShortcut.preferenceKey), shortcut)
        settings.set(.note, enabled: true)
        XCTAssertEqual(SectionSettings(defaults: defaults).current.firstVisible, .note)
        defaults.set(-1, forKey: SectionVisibility.preferenceKey)
        XCTAssertEqual(SectionSettings(defaults: defaults).current, .all)
    }
    func testHiddenActiveSectionClearsPreviewSelectionAndRoutesBothDisplayStates() {
        let first = HubState(), second = HubState()
        for state in [first, second] {
            state.tab = 1; state.previewClip = Clip(kind: .text, title: "preview", fingerprint: "preview")
            state.keyboardSelecting = true; state.selectedClipboardID = UUID()
            XCTAssertTrue(state.applySectionVisibility(SectionVisibility(mask: 5)))
            XCTAssertEqual(state.tab, 0)
            XCTAssertNil(state.previewClip); XCTAssertFalse(state.keyboardSelecting); XCTAssertNil(state.selectedClipboardID)
            XCTAssertTrue(state.applySectionVisibility(SectionVisibility(mask: 0)))
            XCTAssertEqual(state.tab, -1)
            XCTAssertEqual(state.expandedHeight, state.notchHeight + 70)
            XCTAssertTrue(state.applySectionVisibility(SectionVisibility(mask: 4)))
            XCTAssertEqual(state.tab, 2)
            XCTAssertFalse(state.applySectionVisibility(SectionVisibility(mask: 12)))
            XCTAssertEqual(state.tab, 2)
        }
    }
    func testHidingTimerPausesItAndHiddenClipboardShortcutDoesNotTouchData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let domain = "NotchHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain)), pb = NSPasteboard.withUniqueName()
        defer { defaults.removePersistentDomain(forName: domain); pb.releaseGlobally(); try? FileManager.default.removeItem(at: root) }
        let store = HubStore(root: root, monitor: false, pasteboard: pb)
        store.addText("history"); store.addText("shelf", shelf: true); store.setNote("note"); store.flushPendingNote()
        let history = store.archive.clips, shelf = store.archive.shelf, note = store.archive.note
        let delegate = AppDelegate(); delegate.store = store; delegate.clock = FocusClock()
        delegate.sectionSettings = SectionSettings(defaults: defaults) { [weak delegate] in delegate?.applySectionVisibility($0) }
        delegate.clock.reset(minutes: 5); delegate.clock.start()
        delegate.sectionSettings.set(.timer, enabled: false)
        XCTAssertFalse(delegate.clock.running); XCTAssertFalse(delegate.clock.hasScheduledTick)
        XCTAssertGreaterThan(delegate.clock.remaining, 299)
        pb.clearContents(); pb.setString("keep system clipboard", forType: .string)
        delegate.cycle.begin(ids: history.map(\.id))
        delegate.sectionSettings.set(.clipboard, enabled: false)
        delegate.advanceClipboard(); delegate.finishClipboard()
        XCTAssertNil(delegate.cycle.selectedID)
        XCTAssertEqual(pb.string(forType: .string), "keep system clipboard")
        XCTAssertEqual(store.archive.clips, history); XCTAssertEqual(store.archive.shelf, shelf); XCTAssertEqual(store.archive.note, note)
    }
    func testLayoutDefaultsPreserveBothScreenTypesAndHardwareMinimums() {
        let notched = HubGeometry.resolve(.standard, screen: CGRect(x: 0, y: 0, width: 1470, height: 956), safeTop: 32, notchWidth: 179)
        XCTAssertEqual(notched.panelWidth, 345); XCTAssertEqual(notched.panelHeight, 166)
        XCTAssertEqual(notched.previewWidth, 680); XCTAssertEqual(notched.previewHeight, 432)
        XCTAssertEqual(notched.islandWidth, 179); XCTAssertEqual(notched.islandHeight, 33); XCTAssertEqual(notched.topOffset, 0)
        let external = HubGeometry.resolve(.standard, screen: CGRect(x: 1470, y: -124, width: 1920, height: 1080), safeTop: 0, notchWidth: nil)
        XCTAssertEqual(external.panelHeight, 162); XCTAssertEqual(external.previewHeight, 424)
        XCTAssertEqual(external.islandWidth, 104); XCTAssertEqual(external.islandHeight, 16); XCTAssertEqual(external.topOffset, 6)
        var small = HubLayoutPreferences.standard
        small.panelWidth = 240; small.previewWidth = 240; small.islandWidth = 80; small.islandHeight = 10; small.verticalOffset = -40
        let geometry = HubGeometry.resolve(small, screen: CGRect(x: 0, y: 0, width: 1470, height: 956), safeTop: 32, notchWidth: 179)
        XCTAssertEqual(geometry.islandWidth, 179); XCTAssertEqual(geometry.islandHeight, 33)
        XCTAssertGreaterThanOrEqual(geometry.panelWidth, 179 + 164)
        XCTAssertGreaterThanOrEqual(geometry.previewWidth, 179 + 164)
        XCTAssertEqual(geometry.topOffset, 0)
    }
    func testLayoutPersistenceResetAndFramesStayOnSmallOffsetDisplay() throws {
        let domain = "NotchHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = LayoutSettings(defaults: defaults)
        settings.set(\.panelWidth, to: 720); settings.set(\.panelHeight, to: 600)
        settings.set(\.previewWidth, to: 1200); settings.set(\.previewHeight, to: 900)
        settings.set(\.verticalOffset, to: 120); settings.set(\.islandWidth, to: 400)
        settings.set(\.islandHeight, to: 100); settings.set(\.panelOpacity, to: 0.4); settings.set(\.previewOpacity, to: 0.6)
        XCTAssertEqual(LayoutSettings(defaults: defaults).current, settings.current)
        for screen in [CGRect(x: -900, y: 300, width: 640, height: 480), CGRect(x: 100, y: -400, width: 200, height: 120)] {
            let geometry = HubGeometry.resolve(settings.current, screen: screen, safeTop: 0, notchWidth: nil)
            for size in [CGSize(width: geometry.panelWidth, height: geometry.panelHeight), CGSize(width: geometry.previewWidth, height: geometry.previewHeight), CGSize(width: geometry.islandWidth, height: geometry.islandHeight)] {
                XCTAssertTrue(screen.contains(geometry.frame(screen: screen, width: size.width, height: size.height)))
            }
        }
        settings.reset()
        XCTAssertEqual(LayoutSettings(defaults: defaults).current, .standard)
    }
    func testMovedWideIslandKeepsNarrowTopBridgeAndSafeHoverExit() {
        var layout = HubLayoutPreferences.standard; layout.islandWidth = 400; layout.verticalOffset = 100
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let geometry = HubGeometry.resolve(layout, screen: screen, safeTop: 32, notchWidth: 179)
        let panel = geometry.frame(screen: screen, width: geometry.panelWidth, height: geometry.panelHeight)
        XCTAssertEqual(geometry.triggerWidth, 177)
        XCTAssertTrue(HubState.atTrigger(CGPoint(x: screen.midX, y: screen.maxY), screen: screen, notchWidth: geometry.triggerWidth))
        XCTAssertTrue(HubState.insideHub(CGPoint(x: screen.midX, y: panel.maxY + 50), panel: panel, screen: screen, notchWidth: geometry.triggerWidth))
        XCTAssertFalse(HubState.insideHub(CGPoint(x: screen.midX + 150, y: panel.maxY + 50), panel: panel, screen: screen, notchWidth: geometry.triggerWidth))
        XCTAssertFalse(HubState.insideHub(CGPoint(x: screen.midX, y: panel.minY - 1), panel: panel, screen: screen, notchWidth: geometry.triggerWidth))
    }

    func testExpandedHoverIncludesWideAndTallCollapsedIslandWithoutWideningTopTrigger() {
        let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
        var layout = HubLayoutPreferences.standard; layout.islandWidth = 400; layout.panelWidth = 345
        let geometry = HubGeometry.resolve(layout, screen: screen, safeTop: 32, notchWidth: 179)
        let island = geometry.frame(screen: screen, width: geometry.islandWidth, height: geometry.islandHeight)
        let panel = geometry.frame(screen: screen, width: geometry.panelWidth, height: geometry.panelHeight)
        let tip = CGPoint(x: screen.midX + 190, y: island.midY)
        XCTAssertTrue(island.contains(tip)); XCTAssertFalse(panel.contains(tip))
        XCTAssertTrue(HubState.insideHub(tip, panel: panel, screen: screen, notchWidth: geometry.triggerWidth, island: island))
        XCTAssertTrue(HubState.insideHub(CGPoint(x: tip.x + 1, y: tip.y), panel: panel, screen: screen, notchWidth: geometry.triggerWidth, island: island))
        XCTAssertFalse(HubState.atTrigger(CGPoint(x: tip.x, y: screen.maxY), screen: screen, notchWidth: geometry.triggerWidth))
        layout.islandHeight = 100
        let external = HubGeometry.resolve(layout, screen: screen, safeTop: 0, notchWidth: nil)
        let externalIsland = external.frame(screen: screen, width: external.islandWidth, height: external.islandHeight)
        let emptyPanel = external.frame(screen: screen, width: external.panelWidth, height: min(external.panelHeight, external.notchHeight + 70))
        let lowerTip = CGPoint(x: screen.midX, y: externalIsland.minY + 1)
        XCTAssertFalse(emptyPanel.contains(lowerTip))
        XCTAssertTrue(HubState.insideHub(lowerTip, panel: emptyPanel, screen: screen, notchWidth: external.triggerWidth, island: externalIsland))
        XCTAssertFalse(HubState.insideHub(CGPoint(x: screen.midX, y: externalIsland.minY - 1), panel: emptyPanel, screen: screen, notchWidth: external.triggerWidth, island: externalIsland))
    }

}

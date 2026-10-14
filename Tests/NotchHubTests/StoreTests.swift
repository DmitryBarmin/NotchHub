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

}

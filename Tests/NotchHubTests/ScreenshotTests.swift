import XCTest
import AppKit
import Carbon
@testable import NotchHub

final class ScreenshotTests: XCTestCase {
    func testReverseDragAndScreenBounds() {
        XCTAssertEqual(ScreenshotGeometry.rect(CGPoint(x:80,y:60), CGPoint(x:-20,y:10), bounds:CGRect(x:0,y:0,width:100,height:100)), CGRect(x:0,y:10,width:80,height:50))
    }
    func testRetinaCropClampsAndRoundsOutwards() {
        let rect = ScreenshotGeometry.pixelRect(CGRect(x:10.25,y:20.25,width:50.5,height:30.5), points:CGSize(width:100,height:100),pixels:CGSize(width:200,height:200))
        XCTAssertEqual(rect,CGRect(x:20,y:40,width:102,height:62))
        XCTAssertEqual(ScreenshotGeometry.pixelRect(CGRect(x:90,y:90,width:40,height:40),points:CGSize(width:100,height:100),pixels:CGSize(width:200,height:200)),CGRect(x:180,y:180,width:20,height:20))
        XCTAssertEqual(ScreenshotGeometry.pixelRect(CGRect(x:300,y:300,width:20,height:20),points:CGSize(width:100,height:100),pixels:CGSize(width:200,height:200)),.zero)
    }
    func testCropKeepsOrientationAndRedactionExportsInCorrectPosition() throws {
        _ = NSApplication.shared
        let context = try XCTUnwrap(CGContext(data:nil,width:200,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:50,width:200,height:50))
        context.setFillColor(NSColor.blue.cgColor);context.fill(CGRect(x:0,y:0,width:200,height:50))
        let image=try XCTUnwrap(context.makeImage())
        let editor=ScreenshotEditor(image:image,size:CGSize(width:100,height:50));editor.selection=CGRect(x:0,y:0,width:100,height:25)
        var rep=NSBitmapImageRep(cgImage:try XCTUnwrap(editor.exportedImage()))
        XCTAssertEqual(rep.pixelsWide,200);XCTAssertEqual(rep.pixelsHigh,50)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:20,y:20)).usingColorSpace(.deviceRGB)!.redComponent,0.9)
        editor.annotations=[ScreenshotAnnotation(tool:.redact,points:[CGPoint(x:5,y:5),CGPoint(x:15,y:15)],color:.black,width:3)]
        rep=NSBitmapImageRep(cgImage:try XCTUnwrap(editor.exportedImage()))
        XCTAssertLessThan(try XCTUnwrap(rep.colorAt(x:20,y:20)).usingColorSpace(.deviceRGB)!.redComponent,0.1)
        XCTAssertGreaterThan(try XCTUnwrap(rep.colorAt(x:100,y:20)).usingColorSpace(.deviceRGB)!.redComponent,0.9)
    }
    func testScreenshotShortcutFailurePreservesPreference() throws {
        _ = NSApplication.shared
        let name=UUID().uuidString;let defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer { defaults.removePersistentDomain(forName:name) }
        var calls=0
        let settings=ScreenshotSettings(defaults:defaults,register:{ _,_ in calls += 1;return calls==1 ? noErr : OSStatus(eventHotKeyExistsErr) },action:{})
        let old=defaults.data(forKey:ScreenshotSettings.preferenceKey)
        XCTAssertFalse(settings.apply(ClipboardShortcut(keyCode:UInt32(kVK_ANSI_8),modifiers:UInt32(cmdKey|shiftKey))))
        XCTAssertEqual(settings.current,ScreenshotSettings.standard);XCTAssertEqual(defaults.data(forKey:ScreenshotSettings.preferenceKey),old)
        XCTAssertNotNil(settings.message)
    }
    private func sendHotKey(_ kind: UInt32, signature: OSType, id: UInt32 = 1, expectedStatus: OSStatus = noErr) throws {
        var event: EventRef?
        XCTAssertEqual(CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, EventAttributes(kEventAttributeNone), &event), noErr)
        let nativeEvent = try XCTUnwrap(event)
        defer { ReleaseEvent(nativeEvent) }
        var hotKeyID = EventHotKeyID(signature: signature, id: id)
        XCTAssertEqual(SetEventParameter(nativeEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &hotKeyID), noErr)
        XCTAssertEqual(SendEventToEventTarget(nativeEvent, GetApplicationEventTarget()), expectedStatus)
    }
    func testPreviewWaitsForNativeReleaseAndIgnoresRepeatedPresses() throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, signature: OSType = 0x54505256
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var shown = 0, hidden = 0
        let settings = ScreenshotSettings(defaults: defaults, signature: signature, register: { _, _ in noErr }, released: { hidden += 1 }, action: { shown += 1 })
        try sendHotKey(UInt32(kEventHotKeyPressed), signature: signature)
        try sendHotKey(UInt32(kEventHotKeyPressed), signature: signature)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertEqual(shown, 1)
        XCTAssertEqual(hidden, 0, "A held preview must not close when key-state polling cannot see the key")
        try sendHotKey(UInt32(kEventHotKeyReleased), signature: signature + 1, expectedStatus: OSStatus(eventNotHandledErr))
        try sendHotKey(UInt32(kEventHotKeyReleased), signature: signature, id: 2, expectedStatus: OSStatus(eventNotHandledErr))
        XCTAssertEqual(hidden, 0, "Another shortcut must not close the held preview")
        try sendHotKey(UInt32(kEventHotKeyReleased), signature: signature)
        try sendHotKey(UInt32(kEventHotKeyReleased), signature: signature)
        XCTAssertEqual(hidden, 1)
        try sendHotKey(UInt32(kEventHotKeyPressed), signature: signature)
        XCTAssertEqual(shown, 2)
        withExtendedLifetime(settings) {}
    }
    func testShortcutRebindOnlyEndsHeldPreviewAfterSuccessfulRegistration() throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, signature: OSType = 0x54524244
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var registrationSucceeds = true, hidden = 0, shown = 0
        let settings = ScreenshotSettings(defaults: defaults, signature: signature, register: { _, _ in registrationSucceeds ? noErr : OSStatus(eventHotKeyExistsErr) }, released: { hidden += 1 }, action: { shown += 1 })
        try sendHotKey(UInt32(kEventHotKeyPressed), signature: signature)
        let replacement = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_8), modifiers: UInt32(cmdKey | shiftKey))
        registrationSucceeds = false
        XCTAssertFalse(settings.apply(replacement))
        XCTAssertEqual(hidden, 0)
        registrationSucceeds = true
        XCTAssertTrue(settings.apply(replacement))
        XCTAssertEqual(hidden, 1)
        try sendHotKey(UInt32(kEventHotKeyReleased), signature: signature)
        XCTAssertEqual(hidden, 1)
        try sendHotKey(UInt32(kEventHotKeyPressed), signature: signature)
        XCTAssertEqual(shown, 2)
    }
    func testScreenshotIsSingleShotUntilNativeRelease() throws {
        _ = NSApplication.shared
        let name = UUID().uuidString, signature: OSType = 0x54535348
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var captures = 0
        let settings = ScreenshotSettings(defaults: defaults, signature: signature, register: { _, _ in noErr }, action: { captures += 1 })
        try sendHotKey(UInt32(kEventHotKeyPressed), signature: signature)
        try sendHotKey(UInt32(kEventHotKeyPressed), signature: signature)
        XCTAssertEqual(captures, 1)
        try sendHotKey(UInt32(kEventHotKeyReleased), signature: signature)
        try sendHotKey(UInt32(kEventHotKeyPressed), signature: signature)
        XCTAssertEqual(captures, 2)
        withExtendedLifetime(settings) {}
    }
    func testEditorShortcutsRejectDuplicatesAndDispatchCustomModifiers() throws {
        let name=UUID().uuidString;let defaults=try XCTUnwrap(UserDefaults(suiteName:name));defer { defaults.removePersistentDomain(forName:name) }
        let settings=EditorShortcutSettings(defaults:defaults)
        var draft=settings.current;draft[ScreenshotAction.save.rawValue]=draft[ScreenshotAction.copy.rawValue]
        XCTAssertFalse(settings.apply(draft))
        draft=settings.current;draft[ScreenshotAction.copy.rawValue]=ClipboardShortcut(keyCode:UInt32(kVK_ANSI_8),modifiers:UInt32(controlKey|shiftKey))
        XCTAssertTrue(settings.apply(draft))
        let event=try XCTUnwrap(NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.control,.shift],timestamp:0,windowNumber:0,context:nil,characters:"8",charactersIgnoringModifiers:"8",isARepeat:false,keyCode:UInt16(kVK_ANSI_8)))
        XCTAssertEqual(settings.action(for:event),.copy)
    }
    func testRecognitionUsesLocalImage() throws {
        _ = NSApplication.shared
        let bitmap=try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:800,pixelsHigh:160,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap)
        NSColor.white.setFill();CGRect(x:0,y:0,width:800,height:160).fill()
        ("NOTCH HUB 123" as NSString).draw(at:CGPoint(x:40,y:55),withAttributes:[.font:NSFont.systemFont(ofSize:52),.foregroundColor:NSColor.black])
        NSGraphicsContext.restoreGraphicsState()
        let text=try ScreenshotEditor.recognize(XCTUnwrap(bitmap.cgImage))
        XCTAssertTrue(text.contains("123"),text)
    }
    @MainActor func testCancelBeforeDisplayListReturnsDoesNotCaptureAndOldTaskCannotClearRestart() async {
        _ = NSApplication.shared
        let firstEntered = expectation(description: "old content requested")
        let nextEntered = expectation(description: "new content requested")
        let oldStopped = expectation(description: "old task unwound")
        let presented = expectation(description: "new session presented")
        var oldGate: CheckedContinuation<Void, Never>?, nextGate: CheckedContinuation<Void, Never>?
        var sessions = 0, captured: [Int] = [], presentations = 0
        let controller = ScreenshotController(capture: { isCurrent in
            sessions += 1
            let session = sessions
            do {
                _ = try await ScreenshotCaptureSequence.run(loadDisplays: {
                    if session == 1 {
                        firstEntered.fulfill()
                        await withCheckedContinuation { oldGate = $0 }
                    } else {
                        nextEntered.fulfill()
                        await withCheckedContinuation { nextGate = $0 }
                    }
                    return [session * 10, session * 10 + 1]
                }, capture: { display in captured.append(display); return display }, isCurrent: isCurrent)
                return []
            } catch {
                if session == 1 { oldStopped.fulfill() }
                throw error
            }
        }, present: { _ in presentations += 1; presented.fulfill() }, finished: {})
        controller.start(); await fulfillment(of: [firstEntered], timeout: 1)
        controller.finish(); XCTAssertFalse(controller.hasCaptureTask)
        controller.start(); await fulfillment(of: [nextEntered], timeout: 1)
        oldGate?.resume(); await fulfillment(of: [oldStopped], timeout: 1)
        XCTAssertTrue(controller.active); XCTAssertTrue(controller.hasCaptureTask)
        XCTAssertTrue(captured.isEmpty); XCTAssertEqual(presentations, 0)
        nextGate?.resume(); await fulfillment(of: [presented], timeout: 1)
        XCTAssertEqual(captured, [20, 21]); XCTAssertEqual(presentations, 1)
        XCTAssertTrue(controller.active); XCTAssertFalse(controller.hasCaptureTask)
        controller.finish()
    }
    @MainActor func testCancelDuringFirstCaptureSkipsRemainingDisplaysAndReleasesFrame() async {
        _ = NSApplication.shared
        final class Frame {}
        let entered = expectation(description: "first display in native capture")
        let stopped = expectation(description: "cancelled task unwound")
        var gate: CheckedContinuation<Void, Never>?
        var requested: [Int] = [], presentations = 0
        weak var capturedFrame: Frame?
        let controller = ScreenshotController(capture: { isCurrent in
            do {
                _ = try await ScreenshotCaptureSequence.run(loadDisplays: { [1, 2, 3] }, capture: { display in
                    requested.append(display)
                    let frame = Frame(); capturedFrame = frame
                    entered.fulfill()
                    await withCheckedContinuation { gate = $0 }
                    return frame
                }, isCurrent: isCurrent)
                return []
            } catch { stopped.fulfill(); throw error }
        }, present: { _ in presentations += 1 }, finished: {})
        controller.start(); await fulfillment(of: [entered], timeout: 1)
        controller.finish()
        XCTAssertFalse(controller.active); XCTAssertFalse(controller.hasCaptureTask)
        XCTAssertNotNil(capturedFrame) // The already-running native call may finish.
        gate?.resume(); await fulfillment(of: [stopped], timeout: 1)
        XCTAssertEqual(requested, [1]); XCTAssertEqual(presentations, 0)
        XCTAssertNil(capturedFrame)
    }

}

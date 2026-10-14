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
}

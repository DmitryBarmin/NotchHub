import AppKit
import Carbon

@main struct ScreenshotCheck {
 static func main() throws {
  _ = NSApplication.shared
  func check(_ passed: Bool, _ name: String) { precondition(passed,name);print("PASS",name) }
  check(ScreenshotGeometry.rect(CGPoint(x:80,y:60),CGPoint(x:-20,y:10),bounds:CGRect(x:0,y:0,width:100,height:100)) == CGRect(x:0,y:10,width:80,height:50),"reverse drag clamped")
  check(ScreenshotGeometry.pixelRect(CGRect(x:10.25,y:20.25,width:50.5,height:30.5),points:CGSize(width:100,height:100),pixels:CGSize(width:200,height:200)) == CGRect(x:20,y:40,width:102,height:62),"Retina outward crop")
  let context=CGContext(data:nil,width:200,height:100,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
  context.setFillColor(NSColor.red.cgColor);context.fill(CGRect(x:0,y:50,width:200,height:50));context.setFillColor(NSColor.blue.cgColor);context.fill(CGRect(x:0,y:0,width:200,height:50))
  let editor=ScreenshotEditor(image:context.makeImage()!,size:CGSize(width:100,height:50));editor.selection=CGRect(x:0,y:0,width:100,height:25)
  var rep=NSBitmapImageRep(cgImage:editor.exportedImage()!)
  check(rep.pixelsWide==200 && rep.pixelsHigh==50,"export keeps Retina")
  check(rep.colorAt(x:20,y:20)!.usingColorSpace(.deviceRGB)!.redComponent>0.9,"top-left crop orientation")
  editor.annotations=[ScreenshotAnnotation(tool:.redact,points:[CGPoint(x:5,y:5),CGPoint(x:15,y:15)],color:.black,width:3)]
  rep=NSBitmapImageRep(cgImage:editor.exportedImage()!)
  check(rep.colorAt(x:20,y:20)!.usingColorSpace(.deviceRGB)!.redComponent<0.1,"redaction position")
  check(rep.colorAt(x:100,y:20)!.usingColorSpace(.deviceRGB)!.redComponent>0.9,"redaction leaves rest untouched")
  let board=NSPasteboard.withUniqueName();defer { board.releaseGlobally() }
  editor.writeClipboard(to:board)
  let copied=board.data(forType:.png).flatMap(NSBitmapImageRep.init(data:))
  check(copied?.pixelsWide==200 && copied?.pixelsHigh==50,"automatic clipboard PNG")
  editor.selection=CGRect(x:0,y:0,width:50,height:25);editor.writeClipboard(to:board)
  check(board.data(forType:.png).flatMap(NSBitmapImageRep.init(data:))?.pixelsWide==100,"clipboard follows recrop")
  let name=UUID().uuidString;let defaults=UserDefaults(suiteName:name)!;defer { defaults.removePersistentDomain(forName:name) };var calls=0
  let settings=ScreenshotSettings(defaults:defaults,register:{_,_ in calls+=1;return calls==1 ? noErr : OSStatus(eventHotKeyExistsErr)},action:{})
  let old=defaults.data(forKey:ScreenshotSettings.preferenceKey)
  check(!settings.apply(ClipboardShortcut(keyCode:UInt32(kVK_ANSI_8),modifiers:UInt32(cmdKey|shiftKey))),"conflict rejected")
  check(settings.current==ScreenshotSettings.standard && defaults.data(forKey:ScreenshotSettings.preferenceKey)==old,"conflict preserves shortcut")
  let local=EditorShortcutSettings(defaults:defaults)
  var draft=local.current;draft[ScreenshotAction.save.rawValue]=draft[ScreenshotAction.copy.rawValue]
  check(!local.apply(draft),"duplicate editor shortcuts rejected")
  draft=local.current;draft[ScreenshotAction.copy.rawValue]=ClipboardShortcut(keyCode:UInt32(kVK_ANSI_8),modifiers:UInt32(controlKey|shiftKey))
  check(local.apply(draft),"independent editor shortcut saved")
  let event=NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:[.control,.shift],timestamp:0,windowNumber:0,context:nil,characters:"8",charactersIgnoringModifiers:"8",isARepeat:false,keyCode:UInt16(kVK_ANSI_8))!
  check(local.action(for:event) == .copy,"custom editor command dispatch")
  var shown=0,hidden=0
  let preview=ScreenshotSettings(defaults:defaults,preferenceKey:"testPreview",standard:ClipboardShortcut(keyCode:UInt32(kVK_Space),modifiers:UInt32(cmdKey|optionKey)),signature:0x54455354,register:{_,_ in noErr},released:{hidden+=1},action:{shown+=1})
  preview.pressed();check(shown==1,"preview opens on press")
  RunLoop.main.run(until:Date().addingTimeInterval(0.1))
  check(hidden>=1,"preview closes after release")
  let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:800,pixelsHigh:160,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
  NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:bitmap);NSColor.white.setFill();CGRect(x:0,y:0,width:800,height:160).fill()
  ("NOTCH HUB 123" as NSString).draw(at:CGPoint(x:40,y:55),withAttributes:[.font:NSFont.systemFont(ofSize:52),.foregroundColor:NSColor.black]);NSGraphicsContext.restoreGraphicsState()
  let text=try ScreenshotEditor.recognize(bitmap.cgImage!);check(text.contains("123"),"local OCR \(text)")
 }
}

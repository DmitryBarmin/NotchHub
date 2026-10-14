import AppKit
import SwiftUI
import ScreenCaptureKit
import Vision

struct ScreenshotGeometry {
    static func rect(_ a: CGPoint, _ b: CGPoint, bounds: CGRect) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)).intersection(bounds)
    }
    /// ScreenCaptureKit images and the editor both use top-left pixel coordinates.
    static func pixelRect(_ selection: CGRect, points: CGSize, pixels: CGSize) -> CGRect {
        guard points.width > 0, points.height > 0 else { return .zero }
        let r = selection.intersection(CGRect(origin: .zero, size: points))
        guard !r.isNull else { return .zero }
        return CGRect(x: r.minX * pixels.width / points.width, y: r.minY * pixels.height / points.height,
                      width: r.width * pixels.width / points.width, height: r.height * pixels.height / points.height).integral.intersection(CGRect(origin: .zero, size: pixels))
    }
}

enum ScreenshotTool: String, CaseIterable, Identifiable {
    case select, pen, line, arrow, rectangle, ellipse, marker, text, redact
    var id: String { rawValue }
    var title: String { switch self {
        case .select: return "Область / обрезка"
        case .pen: return "Карандаш"
        case .line: return "Линия"
        case .arrow: return "Стрелка"
        case .rectangle: return "Рамка"
        case .ellipse: return "Овал"
        case .marker: return "Маркер"
        case .text: return "Текст"
        case .redact: return "Скрыть область"
    } }
    var icon: String { switch self {
        case .select: return "crop"
        case .pen: return "pencil.tip"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .marker: return "highlighter"
        case .text: return "textformat"
        case .redact: return "rectangle.fill"
    } }
}
struct ScreenshotAnnotation {
    var tool: ScreenshotTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat
    var text = ""
    func draw() {
        guard let first = points.first, let last = points.last else { return }
        let r = ScreenshotGeometry.rect(first, last, bounds: CGRect(x: -100000, y: -100000, width: 200000, height: 200000))
        let path = NSBezierPath(); path.lineWidth = width; path.lineCapStyle = .round; path.lineJoinStyle = .round
        color.setStroke(); color.setFill()
        switch tool {
        case .pen, .line, .arrow:
            path.move(to: first)
            if tool == .pen { for p in points.dropFirst() { path.line(to: p) } } else { path.line(to: last) }
            path.stroke()
            if tool == .arrow {
                let angle = atan2(last.y - first.y, last.x - first.x), length = max(12, width * 4)
                let head = NSBezierPath(); head.lineWidth = width; head.lineCapStyle = .round
                head.move(to: CGPoint(x: last.x - length * cos(angle - .pi / 6), y: last.y - length * sin(angle - .pi / 6)))
                head.line(to: last)
                head.line(to: CGPoint(x: last.x - length * cos(angle + .pi / 6), y: last.y - length * sin(angle + .pi / 6)))
                head.stroke()
            }
        case .rectangle: NSBezierPath(rect: r).withWidth(width).stroke()
        case .ellipse: NSBezierPath(ovalIn: r).withWidth(width).stroke()
        case .marker: color.withAlphaComponent(0.30).setFill(); r.fill()
        case .redact: NSColor.black.setFill(); r.fill()
        case .text:
            (text as NSString).draw(at: first, withAttributes: [.font: NSFont.systemFont(ofSize: max(16, width * 6), weight: .semibold), .foregroundColor: color])
        case .select: break
        }
    }
}
private extension NSBezierPath { func withWidth(_ width: CGFloat) -> NSBezierPath { lineWidth = width; return self } }

final class ScreenshotEditor: ObservableObject {
    let image: CGImage
    let size: CGSize
    @Published var selection = CGRect.zero
    @Published var tool = ScreenshotTool.select
    @Published var color = Color.red
    @Published var width: CGFloat = 3
    @Published var annotations: [ScreenshotAnnotation] = []
    @Published var recognizing = false
    @Published var message: String?
    var close: (() -> Void)?
    var changed: (() -> Void)?
    var textWindow: NSWindow?
    init(image: CGImage, size: CGSize) { self.image = image; self.size = size }
    var valid: Bool { selection.width >= 3 && selection.height >= 3 }
    func exportedImage(annotated: Bool = true) -> CGImage? {
        guard valid else { return nil }
        let pixels = ScreenshotGeometry.pixelRect(selection, points: size, pixels: CGSize(width: image.width, height: image.height))
        guard let crop = image.cropping(to: pixels), annotated, !annotations.isEmpty else { return image.cropping(to: pixels) }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: crop.width, pixelsHigh: crop.height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.current = context
        context.cgContext.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        let sx = CGFloat(image.width) / size.width, sy = CGFloat(image.height) / size.height
        context.cgContext.translateBy(x: 0, y: CGFloat(crop.height))
        context.cgContext.scaleBy(x: sx, y: -sy)
        context.cgContext.translateBy(x: -pixels.minX / sx, y: -pixels.minY / sy)
        // Tell AppKit that text is being drawn in the editor's flipped coordinates.
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        annotations.forEach { $0.draw() }
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.cgImage
    }
    func writeClipboard(to pasteboard: NSPasteboard = .general) {
        guard let image = exportedImage() else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        pasteboard.clearContents(); pasteboard.setData(png, forType: .png)
    }
    func copy() {
        writeClipboard(); close?()
    }
    func undo() {
        guard !annotations.isEmpty else { return }
        annotations.removeLast(); changed?(); writeClipboard()
    }
    func save(in window: NSWindow?) {
        guard let image = exportedImage(), let window else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.png]; panel.nameFieldStringValue = "Скриншот-" + Date().formatted(.iso8601).replacingOccurrences(of: ":", with: "-") + ".png"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                try data.write(to: url, options: .atomic); self?.close?()
            } catch { self?.message = error.localizedDescription }
        }
    }
    static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true; request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["ru-RU", "en-US"].filter { supported.contains($0) }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
    func recognizeText() {
        guard !recognizing, let crop = exportedImage(annotated: false) else { return }
        recognizing = true; message = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try Self.recognize(crop) }
            DispatchQueue.main.async {
                guard let self else { return }; self.recognizing = false
                switch result {
                case .failure(let error): self.message = error.localizedDescription
                case .success(let text):
                    if text.isEmpty { self.message = "Текст не найден — выдели область крупнее"; return }
                    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
                    window.title = "Распознанный текст"; window.isReleasedWhenClosed = false; window.level = .screenSaver
                    window.contentView = NSHostingView(rootView: RecognizedScreenshotText(text: text))
                    self.textWindow?.close(); self.textWindow = window; window.center(); window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}
struct RecognizedScreenshotText: View {
    @State var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Выдели нужные строки или скопируй весь текст").foregroundStyle(.secondary)
            TextEditor(text: $text).font(.system(size: 15)).border(.secondary.opacity(0.2))
            HStack { Text("Распознано на Mac").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Копировать текст") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }.buttonStyle(.borderedProminent) }
        }.padding(20)
    }
}

final class ScreenshotCanvas: NSView {
    let editor: ScreenshotEditor
    private var anchor = CGPoint.zero
    private var original = CGRect.zero
    private var dragMode = 0 // 0 new selection, 1 move, 2 resize, 3 annotation
    private var opposite = CGPoint.zero
    private var pending: ScreenshotAnnotation?
    private var tools: NSHostingView<ScreenshotToolbar>!
    private var actions: NSHostingView<ScreenshotActions>!
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(editor: ScreenshotEditor) {
        self.editor = editor
        super.init(frame: CGRect(origin: .zero, size: editor.size))
        tools = NSHostingView(rootView: ScreenshotToolbar(editor: editor))
        actions = NSHostingView(rootView: ScreenshotActions(editor: editor, save: { [weak self] in self?.editor.save(in: self?.window) }))
        addSubview(tools); addSubview(actions); tools.isHidden = true; actions.isHidden = true
        editor.changed = { [weak self] in self?.needsDisplay = true }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: editor.image, size: editor.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
        let r = editor.selection
        NSColor.black.withAlphaComponent(0.48).setFill()
        if editor.valid {
            CGRect(x: 0, y: 0, width: bounds.width, height: r.minY).fill()
            CGRect(x: 0, y: r.maxY, width: bounds.width, height: max(0, bounds.height-r.maxY)).fill()
            CGRect(x: 0, y: r.minY, width: r.minX, height: r.height).fill()
            CGRect(x: r.maxX, y: r.minY, width: max(0,bounds.width-r.maxX), height: r.height).fill()
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: r).addClip()
            editor.annotations.forEach { $0.draw() }; pending?.draw()
            NSGraphicsContext.restoreGraphicsState()
            NSColor.white.setStroke(); NSBezierPath(rect: r).withWidth(1).stroke()
            let pixelRect=ScreenshotGeometry.pixelRect(r,points:editor.size,pixels:CGSize(width:editor.image.width,height:editor.image.height))
            let label="\(Int(pixelRect.width)) × \(Int(pixelRect.height))"
            let attributes: [NSAttributedString.Key:Any]=[.foregroundColor:NSColor.white,.font:NSFont.monospacedDigitSystemFont(ofSize:10,weight:.medium)]
            let labelSize=(label as NSString).size(withAttributes:attributes)
            let labelRect=CGRect(x:r.minX,y:max(3,r.minY-21),width:labelSize.width+10,height:17)
            NSColor.black.withAlphaComponent(0.65).setFill();NSBezierPath(roundedRect:labelRect,xRadius:4,yRadius:4).fill()
            (label as NSString).draw(at:CGPoint(x:labelRect.minX+5,y:labelRect.minY+2),withAttributes:attributes)
            for p in [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.minX,y:r.maxY),CGPoint(x:r.maxX,y:r.maxY)] { NSColor.white.setFill(); CGRect(x:p.x-3,y:p.y-3,width:6,height:6).fill() }
        } else {
            bounds.fill()
            ("Выдели область · двойной клик — весь экран · Esc — отмена" as NSString).draw(at: CGPoint(x: 30, y: 60), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.systemFont(ofSize: 17, weight: .medium)])
        }
    }
    func updateTools() {
        tools.isHidden = !editor.valid; actions.isHidden = !editor.valid
        guard editor.valid else { return }
        let r=editor.selection
        let w: CGFloat=28, h: CGFloat=160
        let right=r.maxX+6
        let x=right+w <= bounds.width-6 ? right : max(6,r.minX-w-6)
        let y=min(max(6,r.minY),max(6,bounds.height-h-6))
        tools.frame=CGRect(x:x,y:y,width:w,height:min(h,bounds.height-12))
        let aw: CGFloat=174, ah: CGFloat=28
        let ax=min(max(6,r.maxX-aw),max(6,bounds.width-aw-6))
        let ay=r.maxY+ah+12 <= bounds.height ? r.maxY+6 : max(6,r.minY-ah-6)
        actions.frame=CGRect(x:ax,y:ay,width:aw,height:ah)
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        anchor = convert(event.locationInWindow, from: nil); original = editor.selection
        if event.clickCount == 2, editor.tool == .select { editor.selection = bounds; updateTools(); return }
        if editor.tool == .select {
            let corners = [CGPoint(x:original.minX,y:original.minY),CGPoint(x:original.maxX,y:original.minY),CGPoint(x:original.minX,y:original.maxY),CGPoint(x:original.maxX,y:original.maxY)]
            if editor.valid, let i = corners.firstIndex(where: { hypot($0.x-anchor.x,$0.y-anchor.y)<12 }) { dragMode=2; opposite=corners[3-i] }
            else if editor.valid, original.contains(anchor) { dragMode=1 }
            else { dragMode=0; editor.selection = .zero }
        } else if editor.valid, original.contains(anchor) {
            dragMode=3
            if editor.tool == .text {
                let alert = NSAlert(); alert.messageText = "Текст на скриншоте"
                let field = NSTextField(frame: NSRect(x:0,y:0,width:320,height:28)); alert.accessoryView=field
                alert.addButton(withTitle:"Добавить"); alert.addButton(withTitle:"Отмена")
                alert.window.level = .screenSaver; alert.window.initialFirstResponder=field
                if alert.runModal() == .alertFirstButtonReturn, !field.stringValue.isEmpty {
                    editor.annotations.append(ScreenshotAnnotation(tool:.text,points:[anchor],color:NSColor(editor.color),width:editor.width,text:field.stringValue))
                }; needsDisplay=true; editor.writeClipboard(); return
            }
            pending=ScreenshotAnnotation(tool:editor.tool,points:[anchor,anchor],color:NSColor(editor.color),width:editor.width)
        } else { dragMode = -1 }
    }
    override func mouseDragged(with event: NSEvent) {
        let p = convert(event.locationInWindow,from:nil)
        switch dragMode {
        case 0: editor.selection = ScreenshotGeometry.rect(anchor,p,bounds:bounds)
        case 1:
            let x = min(max(0, original.minX+p.x-anchor.x),bounds.width-original.width)
            let y = min(max(0, original.minY+p.y-anchor.y),bounds.height-original.height)
            editor.selection = CGRect(x:x,y:y,width:original.width,height:original.height)
        case 2: editor.selection=ScreenshotGeometry.rect(opposite,p,bounds:bounds)
        case 3:
            if pending?.tool == .pen { pending?.points.append(p) } else if pending != nil { pending?.points[1]=p }
        default: break
        }
        tools.isHidden=true; actions.isHidden=true; needsDisplay=true
    }
    override func mouseUp(with event: NSEvent) {
        if let pending { editor.annotations.append(pending) }; pending=nil
        updateTools(); editor.writeClipboard()
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { editor.close?(); return }
        if let action=EditorShortcutSettings.shared.action(for:event) {
            switch action {
            case .copy: editor.copy()
            case .save: editor.save(in:window)
            case .undo: editor.undo()
            case .selectAll: editor.selection=bounds;updateTools();editor.writeClipboard()
            case .recognize: editor.recognizeText()
            }
        } else if event.keyCode == 36 { editor.copy() }
        else { super.keyDown(with:event) }
    }
}
struct ScreenshotGlassSurface: ViewModifier {
    func body(content: Content) -> some View {
        Group {
            if #available(macOS 26.0, *) {
                content.glassEffect(.clear.tint(.white.opacity(0.07)), in:RoundedRectangle(cornerRadius:12))
                    .overlay { RoundedRectangle(cornerRadius:12).stroke(LinearGradient(colors:[.white.opacity(0.55),.white.opacity(0.08),.white.opacity(0.22)],startPoint:.topLeading,endPoint:.bottomTrailing),lineWidth:0.65) }
                    .shadow(color:.black.opacity(0.18),radius:8,y:3)
            } else {
                content.background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:12))
                    .overlay { RoundedRectangle(cornerRadius:12).stroke(.white.opacity(0.18),lineWidth:0.5) }
            }
        }
    }
}
struct ScreenshotIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { ScreenshotIconButton(configuration:configuration) }
}
private struct ScreenshotIconButton: View {
    let configuration: ButtonStyle.Configuration
    @State private var hovered=false
    var body: some View {
        configuration.label
            .background(.white.opacity(configuration.isPressed ? 0.18 : hovered ? 0.10 : 0),in:RoundedRectangle(cornerRadius:7))
            .contentShape(RoundedRectangle(cornerRadius:7))
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration:0.12),value:configuration.isPressed)
            .onHover { hovered=$0 }
    }
}
struct ScreenshotToolbar: View {
    @ObservedObject var editor: ScreenshotEditor
    var body: some View {
        VStack(spacing:2) {
            ForEach([ScreenshotTool.pen, .line, .arrow, .rectangle, .marker, .text]) { tool in
                Button { editor.tool=tool } label: {
                    Image(systemName:tool.icon).frame(width:20,height:20)
                        .foregroundStyle(editor.tool == tool ? Color(red:0.45,green:0.77,blue:1) : .white.opacity(0.9))
                        .background(editor.tool==tool ? Color.white.opacity(0.16) : .clear,in:RoundedRectangle(cornerRadius:7))
                }.help(tool.title).accessibilityLabel(tool.title)
            }
            Menu {
                Button("Красный") { editor.color = .red }
                Button("Жёлтый") { editor.color = .yellow }
                Button("Зелёный") { editor.color = .green }
                Button("Синий") { editor.color = .blue }
                Button("Белый") { editor.color = .white }
                Button("Чёрный") { editor.color = .black }
            } label: { Circle().fill(editor.color).frame(width:14,height:14).frame(width:20,height:20) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Цвет").accessibilityLabel("Цвет рисунка")
        }.font(.system(size:11,weight:.medium)).padding(4)
        .modifier(ScreenshotGlassSurface())
        .preferredColorScheme(.dark).buttonStyle(ScreenshotIconButtonStyle())
    }
}
struct ScreenshotActions: View {
    @ObservedObject var editor: ScreenshotEditor
    let save: () -> Void
    var body: some View {
        HStack(spacing:2) {
            Button { editor.tool = .select } label: { Image(systemName:"crop").frame(width:22,height:20) }
                .help("Изменить область").accessibilityLabel("Изменить область")
            Button { editor.undo() } label: { Image(systemName:"arrow.uturn.backward").frame(width:22,height:20) }
                .help("Отменить").accessibilityLabel("Отменить рисунок").disabled(editor.annotations.isEmpty)
            Menu {
                Button("Овал") { editor.tool = .ellipse }
                Button("Скрыть область") { editor.tool = .redact }
                Divider()
                ForEach([CGFloat(2),3,6],id: \.self) { width in Button("Толщина \(Int(width))") { editor.width=width } }
            } label: { Image(systemName:"ellipsis").frame(width:22,height:20) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Дополнительные инструменты")
            Button { editor.recognizeText() } label: {
                Image(systemName:editor.recognizing ? "hourglass" : "text.viewfinder").frame(width:22,height:20)
            }.help(editor.message ?? "Распознать текст").accessibilityLabel("Распознать текст").disabled(editor.recognizing)
            Button { save() } label: { Image(systemName:"square.and.arrow.down").frame(width:22,height:20) }
                .help("Сохранить · " + EditorShortcutSettings.shared.shortcut(.save).label).accessibilityLabel("Сохранить скриншот")
            Button { editor.copy() } label: { Image(systemName:"doc.on.doc").frame(width:22,height:20) }
                .help("Копировать · " + EditorShortcutSettings.shared.shortcut(.copy).label).accessibilityLabel("Копировать скриншот")
            Button { editor.close?() } label: { Image(systemName:"xmark").frame(width:22,height:20) }.help("Отмена · Esc").accessibilityLabel("Отменить скриншот")
        }.font(.system(size:11,weight:.medium)).padding(4)
        .modifier(ScreenshotGlassSurface())
        .preferredColorScheme(.dark).buttonStyle(ScreenshotIconButtonStyle())
    }
}
final class ScreenshotWindow: NSWindow { override var canBecomeKey: Bool { true } }
final class ScreenshotController {
    private(set) var active=false
    private var windows: [NSWindow]=[]
    private var editors: [ScreenshotEditor]=[]
    private let finished: () -> Void
    init(finished: @escaping () -> Void) { self.finished=finished }
    func start() {
        guard !active else { return }; active=true
        Task { @MainActor [self] in
            do {
                let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
                var captures: [(NSScreen, CGImage)]=[]
                for screen in NSScreen.screens {
                    guard let id=screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32, let display=content.displays.first(where:{$0.displayID==id}) else { continue }
                    let filter=SCContentFilter(display:display,excludingWindows:[])
                    let config=SCStreamConfiguration(); config.width=Int(screen.frame.width*screen.backingScaleFactor);config.height=Int(screen.frame.height*screen.backingScaleFactor);config.showsCursor=false
                    captures.append((screen,try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:config)))
                }
                guard !captures.isEmpty else { throw NSError(domain:"NotchHub",code:1,userInfo:[NSLocalizedDescriptionKey:"Нет доступных экранов"]) }
                // Snapshot every display before showing any overlay, avoiding self-capture.
                for (screen,image) in captures {
                    let editor=ScreenshotEditor(image:image,size:screen.frame.size)
                    editor.close = { [weak self] in self?.finish() }; editors.append(editor)
                    let window=ScreenshotWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
                    window.title="NotchHub — скриншот"
                    window.isReleasedWhenClosed=false;window.level = NSWindow.Level(rawValue:NSWindow.Level.statusBar.rawValue+1);window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];window.isOpaque=true
                    window.contentView=ScreenshotCanvas(editor:editor);windows.append(window);window.orderFrontRegardless()
                }
                NSApp.activate(ignoringOtherApps:true)
                let target=windows.first(where:{$0.frame.contains(NSEvent.mouseLocation)}) ?? windows.first
                target?.makeKeyAndOrderFront(nil);target?.makeFirstResponder(target?.contentView)
            } catch {
                finish()
                let alert=NSAlert();alert.messageText="Не удалось сделать скриншот"
                alert.informativeText=CGPreflightScreenCaptureAccess() ? error.localizedDescription : "Разреши NotchHub в Системные настройки → Конфиденциальность и безопасность → Запись экрана, затем перезапусти приложение.\n\n" + error.localizedDescription
                alert.addButton(withTitle:"Понятно");alert.runModal()
            }
        }
    }
    func finish() {
        editors.forEach { $0.close=nil; $0.textWindow?.close() };windows.forEach { $0.orderOut(nil);$0.close() }
        editors.removeAll();windows.removeAll();active=false;finished()
    }
}

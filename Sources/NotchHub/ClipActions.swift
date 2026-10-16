import AppKit
import SwiftUI
import ImageIO
import CoreImage
import CoreImage.CIFilterBuiltins

final class DetachedPreviewController: NSObject, ObservableObject, NSWindowDelegate {
    private struct Item { let window: NSWindow; let directory: URL? }
    private var items: [Item] = []
    private let fm = FileManager.default
    @Published private(set) var message: String?
    var windowCount: Int { items.count }
    func open(clip: Clip, url: URL?) {
        var directory: URL?
        do {
            var copiedURL: URL?
            if clip.kind != .text {
                guard let url else { throw ClipActionFailure("Файл недоступен") }
                let properties = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard properties.isRegularFile == true, (properties.fileSize ?? Int.max) <= HubStore.maxBytes else { throw ClipActionFailure("Предпросмотр поддерживает файлы до 30 МБ") }
                let folder = fm.temporaryDirectory.appendingPathComponent("NotchHub-preview-" + UUID().uuidString)
                try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                directory = folder
                let copy = folder.appendingPathComponent(url.lastPathComponent)
                try fm.copyItem(at: url, to: copy)
                let copiedSize = try copy.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard copiedSize <= HubStore.maxBytes else { throw ClipActionFailure("Файл слишком большой") }
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path)
                copiedURL = copy
            }
            if items.count >= 5 { items.first?.window.close() }
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 680, height: 440), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = clip.title; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: ClipPreviewView(clip: clip, url: copiedURL))
            items.append(Item(window: window, directory: directory))
            window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            message = nil
        } catch { if let directory { try? fm.removeItem(at: directory) }; message = error.localizedDescription }
    }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let index = items.firstIndex(where: { $0.window === window }) else { return }
        let item = items.remove(at: index)
        // Removing the hosting tree dismantles AVPlayer/Quick Look immediately.
        item.window.contentView = nil
        if let directory = item.directory { try? fm.removeItem(at: directory) }
    }
    func closeAll() { let windows = items.map(\.window); windows.forEach { $0.close() } }
    deinit {
        for item in items { item.window.delegate = nil; item.window.contentView = nil; item.window.close(); if let directory = item.directory { try? fm.removeItem(at: directory) } }
    }
}

struct ClipActionFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

final class ImageOCRController: ObservableObject {
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    private let queue = OperationQueue()
    private var generation = UUID()
    private let recognizeImage: (CGImage) throws -> String
    init(recognizer: ((CGImage) throws -> String)? = nil) {
        recognizeImage = recognizer ?? ScreenshotEditor.recognize
        queue.maxConcurrentOperationCount = 1; queue.qualityOfService = .utility
    }
    func recognize(url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        cancel(); let token = UUID(); generation = token; busy = true; message = nil
        let recognizeImage = self.recognizeImage
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak self, weak operation] in
            guard operation?.isCancelled == false else { return }
            let result = Result<String, Error> {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 3000, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ClipActionFailure("Не удалось открыть изображение") }
                guard operation?.isCancelled == false else { throw CancellationError() }
                let text = try recognizeImage(image)
                guard !text.isEmpty else { throw ClipActionFailure("Текст не найден") }
                return text
            }
            guard operation?.isCancelled == false else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.busy = false
                if case .failure(let error) = result { self.message = error.localizedDescription }
                completion(result)
            }
        }
        queue.addOperation(operation)
    }
    func cancel() { generation = UUID(); queue.cancelAllOperations(); busy = false }
    deinit { queue.cancelAllOperations() }
}

final class QuickShareController: NSObject, ObservableObject, NSSharingServicePickerDelegate, NSWindowDelegate {
    private var picker: NSSharingServicePicker?
    private var qrWindows: [NSWindow] = []
    @Published private(set) var message: String?
    static func qrImage(text: String) throws -> NSImage {
        guard !text.isEmpty, text.utf8.count <= 2048 else { throw ClipActionFailure("QR поддерживает от 1 до 2048 байт текста") }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage, let image = CIContext().createCGImage(output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)), from: output.extent.applying(CGAffineTransform(scaleX: 6, y: 6))) else { throw ClipActionFailure("Не удалось создать QR-код") }
        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }
    func showQR(text: String) {
        do {
            let image = try Self.qrImage(text: text)
            if qrWindows.count >= 5 { qrWindows.first?.close() }
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 420, height: 450), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "QR-код"; window.isReleasedWhenClosed = false; window.delegate = self
            window.contentView = NSHostingView(rootView: VStack(spacing: 12) {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(20).background(.white)
                Text("Создан на Mac · без отправки в сеть").font(.caption).foregroundStyle(.secondary)
            }.padding(16))
            qrWindows.append(window); window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
            message = nil
        } catch { message = error.localizedDescription }
    }
    func share(items: [Any], from view: NSView) {
        guard !items.isEmpty else { message = "Нечем поделиться"; return }
        guard view.window != nil else { message = "Открой панель для отправки"; return }
        let picker = NSSharingServicePicker(items: items)
        self.picker = picker; picker.delegate = self
        picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }
    func sharingServicePicker(_ sharingServicePicker: NSSharingServicePicker, didChoose service: NSSharingService?) { if picker === sharingServicePicker { picker = nil } }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        qrWindows.removeAll { $0 === window }; window.contentView = nil
    }
    func closeAll() { let windows = qrWindows; windows.forEach { $0.close() }; picker?.delegate = nil; picker?.close(); picker = nil }
    deinit { for window in qrWindows { window.delegate = nil; window.close() }; picker?.delegate = nil; picker?.close() }
}

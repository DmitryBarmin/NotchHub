import AppKit
import SwiftUI

struct ScreenshotEntry: Identifiable, Codable, Equatable {
    struct Annotation: Codable, Equatable {
        var tool: String
        var points: [CGPoint]
        var rgba: [Double]
        var width: CGFloat
        var text: String
        init(_ annotation: ScreenshotAnnotation, origin: CGPoint) {
            tool = annotation.tool.rawValue
            points = annotation.points.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
            let color = annotation.color.usingColorSpace(.deviceRGB) ?? .red
            rgba = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
            width = annotation.width; text = annotation.text
        }
        var annotation: ScreenshotAnnotation? {
            guard let tool = ScreenshotTool(rawValue: tool), rgba.count == 4 else { return nil }
            return ScreenshotAnnotation(tool: tool, points: points, color: NSColor(red: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]), width: width, text: text)
        }
    }
    var id: UUID
    var title: String
    var date: Date
    var asset: String
    var byteCount: Int
    var size: CGSize
    var annotations: [Annotation]
}

final class ScreenshotLibrary: ObservableObject {
    @Published private(set) var entries: [ScreenshotEntry] = []
    @Published private(set) var message: String?
    let root: URL
    static let entryLimit = 20
    static let byteLimit = 200 * 1024 * 1024
    private let fm = FileManager.default
    private var writable = true
    private var manifest: URL { root.appendingPathComponent("history.json") }
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchHub/Screenshots", isDirectory: true)
        do {
            try fm.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
            if fm.fileExists(atPath: manifest.path) {
                let data = try Data(contentsOf: manifest)
                guard data.count <= 8 * 1024 * 1024 else { throw failure("История скриншотов повреждена") }
                let loaded = try JSONDecoder().decode([ScreenshotEntry].self, from: data)
                guard loaded.allSatisfy({ $0.asset == URL(fileURLWithPath: $0.asset).lastPathComponent && $0.asset.hasSuffix(".png") && $0.byteCount > 0 && $0.byteCount <= Self.byteLimit && $0.size.width > 0 && $0.size.height > 0 }) else { throw failure("История скриншотов повреждена") }
                entries = loaded
                let bounded = boundedEntries(loaded)
                if bounded != loaded { try persist(bounded); entries = bounded }
            }
            cleanAssets()
        } catch { writable = false; message = error.localizedDescription }
    }
    private func failure(_ text: String) -> NSError { NSError(domain: "NotchHub.Screenshots", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    func url(for entry: ScreenshotEntry) -> URL { root.appendingPathComponent(entry.asset) }
    @discardableResult func save(_ editor: ScreenshotEditor, id: UUID? = nil) throws -> ScreenshotEntry {
        guard writable else { throw failure(message ?? "История скриншотов недоступна") }
        guard editor.valid else { throw failure("Выдели область скриншота") }
        // Render only irreversible redactions into the cropped base. Other marks
        // remain editable and the surrounding desktop is never written to disk.
        let baseEditor = ScreenshotEditor(image: editor.image, size: editor.size)
        baseEditor.selection = editor.selection
        baseEditor.annotations = editor.annotations.filter { $0.tool == .redact }
        guard let image = baseEditor.exportedImage(), let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]), data.count <= Self.byteLimit else { throw failure("Скриншот слишком большой для истории") }
        let pixels = ScreenshotGeometry.pixelRect(editor.selection, points: editor.size, pixels: CGSize(width: editor.image.width, height: editor.image.height))
        let sx = CGFloat(editor.image.width) / editor.size.width, sy = CGFloat(editor.image.height) / editor.size.height
        let origin = CGPoint(x: pixels.minX / sx, y: pixels.minY / sy)
        let entry = ScreenshotEntry(id: id ?? editor.archiveID ?? UUID(), title: "Скриншот · \(image.width) × \(image.height)", date: Date(), asset: UUID().uuidString + ".png", byteCount: data.count, size: CGSize(width: CGFloat(image.width) / sx, height: CGFloat(image.height) / sy), annotations: editor.annotations.filter { $0.tool != .redact }.map { ScreenshotEntry.Annotation($0, origin: origin) })
        let next = boundedEntries([entry] + entries.filter { $0.id != entry.id })
        let destination = url(for: entry)
        do {
            try data.write(to: destination, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            try persist(next)
        } catch { try? fm.removeItem(at: destination); throw error }
        entries = next; editor.archiveID = entry.id; cleanAssets()
        return entry
    }
    func editor(for entry: ScreenshotEntry) throws -> ScreenshotEditor {
        guard entries.contains(where: { $0.id == entry.id && $0.asset == entry.asset }), let image = NSImage(contentsOf: url(for: entry))?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw failure("Скриншот недоступен") }
        let editor = ScreenshotEditor(image: image, size: entry.size)
        editor.selection = CGRect(origin: .zero, size: entry.size)
        editor.annotations = entry.annotations.compactMap(\.annotation)
        editor.archiveID = entry.id
        return editor
    }
    func remove(_ entry: ScreenshotEntry) {
        guard writable else { return }
        let next = entries.filter { $0.id != entry.id }
        do { try persist(next); entries = next; cleanAssets() }
        catch { message = error.localizedDescription }
    }
    private func boundedEntries(_ values: [ScreenshotEntry]) -> [ScreenshotEntry] {
        var bytes = 0
        return Array(values.prefix(Self.entryLimit)).filter { entry in
            guard entry.byteCount <= Self.byteLimit - bytes else { return false }
            bytes += entry.byteCount; return true
        }
    }
    private func persist(_ values: [ScreenshotEntry]) throws {
        let data = try JSONEncoder().encode(values)
        guard data.count <= 8 * 1024 * 1024 else { throw failure("Слишком много рисунков в истории") }
        try data.write(to: manifest, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    }
    private func cleanAssets() {
        let owned = Set(entries.map(\.asset))
        guard let files = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "png" && !owned.contains(file.lastPathComponent) { try? fm.removeItem(at: file) }
    }
}

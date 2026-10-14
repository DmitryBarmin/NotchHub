import AppKit
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers

struct Clip: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, image, file }
    var id: UUID = UUID()
    var kind: Kind
    var title: String
    var text: String?
    var asset: String?
    var fingerprint: String
    var date: Date = Date()
}

struct Archive: Codable {
    var clips: [Clip] = []
    var shelf: [Clip] = []
    var note: String = ""
}

final class HubStore: ObservableObject {
    @Published private(set) var archive = Archive()
    @Published var paused = false
    @Published var message: String?
    let root: URL
    private var changeCount: Int
    private var pollTimer: Timer?
    private let fm = FileManager.default
    private let pasteboard: NSPasteboard
    static let maxBytes = 30 * 1024 * 1024
    init(root: URL? = nil, monitor: Bool = true, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchHub")
        changeCount = pasteboard.changeCount
        do {
            try fm.createDirectory(at: self.root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            // History can contain private text: restrict this application's storage.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
            let saved = self.root.appendingPathComponent("history.json")
            if fm.fileExists(atPath: saved.path) { archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: saved)) }
            archive.clips = Array(archive.clips.prefix(20)); archive.shelf = Array(archive.shelf.prefix(20))
            cleanAssets()
        } catch { message = "Не удалось прочитать историю: \(error.localizedDescription)" }
        if monitor { pollTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in self?.capture() } }
    }
    deinit { pollTimer?.invalidate() }
    func assetURL(_ clip: Clip) -> URL? { clip.asset.map { root.appendingPathComponent("Assets").appendingPathComponent($0) } }
    func save() {
        do {
            let url = root.appendingPathComponent("history.json")
            try JSONEncoder().encode(archive).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { message = "Не удалось сохранить: \(error.localizedDescription)" }
    }
    func setNote(_ text: String) { archive.note = text; save() }
    func insert(_ clip: Clip, shelf: Bool = false) {
        if shelf {
            archive.shelf.removeAll { $0.fingerprint == clip.fingerprint }
            archive.shelf.insert(clip, at: 0); archive.shelf = Array(archive.shelf.prefix(20))
        } else {
            archive.clips.removeAll { $0.fingerprint == clip.fingerprint }
            archive.clips.insert(clip, at: 0); archive.clips = Array(archive.clips.prefix(20))
        }
        save(); cleanAssets()
    }
    func addText(_ text: String, shelf: Bool = false) {
        guard !text.isEmpty else { return }
        guard text.utf8.count <= Self.maxBytes else { message = "Текст слишком большой (лимит 30 МБ)"; return }
        insert(Clip(kind: .text, title: String(text.prefix(100)), text: text, fingerprint: digest(Data(text.utf8))), shelf: shelf)
    }
    func addImage(_ data: Data, shelf: Bool = false) {
        guard data.count <= Self.maxBytes, let image = NSImage(data: data), let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
            message = "Картинка недоступна или больше 30 МБ"; return
        }
        guard png.count <= Self.maxBytes else { message = "Картинка больше 30 МБ"; return }
        let hash = digest(png), name = hash + ".png"
        do {
            try png.write(to: root.appendingPathComponent("Assets").appendingPathComponent(name), options: .atomic)
            insert(Clip(kind: .image, title: "Изображение · \(Int(image.size.width)) × \(Int(image.size.height))", asset: name, fingerprint: "image:" + hash), shelf: shelf)
        } catch { message = "Не удалось сохранить картинку: \(error.localizedDescription)" }
    }
    func addFile(_ url: URL, shelf: Bool = true) {
        let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let props = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard props.isRegularFile == true else { message = "Положи файл, а не папку"; return }
            guard (props.fileSize ?? 0) <= Self.maxBytes else { message = "Файл больше 30 МБ"; return }
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image) {
                addImage(data, shelf: shelf); return
            }
            let hash = digest(data), name = hash + "-" + url.lastPathComponent
            let destination = root.appendingPathComponent("Assets").appendingPathComponent(name)
            if !fm.fileExists(atPath: destination.path) { try data.write(to: destination, options: .atomic) }
            insert(Clip(kind: .file, title: url.lastPathComponent, asset: name, fingerprint: "file:" + name), shelf: shelf)
        } catch { message = "Не удалось добавить файл: \(error.localizedDescription)" }
    }
    func capture() {
        let pb = pasteboard
        guard pb.changeCount != changeCount else { return }; changeCount = pb.changeCount
        guard !paused else { return }
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        let types = (pb.types ?? []) + (pb.pasteboardItems ?? []).flatMap { $0.types }
        guard !types.contains(where: { blocked.contains($0.rawValue) }) else { return }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls.prefix(20) { addFile(url, shelf: false) }; return
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { addImage(data); return }
        if let text = pb.string(forType: .string) { addText(text) }
    }
    func copy(_ clip: Clip) {
        let pb = pasteboard
        if let text = clip.text { pb.clearContents(); pb.setString(text, forType: .string) }
        else if let url = assetURL(clip), fm.fileExists(atPath: url.path) {
            pb.clearContents()
            if clip.kind == .image, let image = NSImage(contentsOf: url) { pb.writeObjects([image]) }
            else { pb.writeObjects([url as NSURL]) }
        } else { message = "Файл недоступен"; return }
        changeCount = pb.changeCount; message = "Скопировано — вставь через ⌘V"
    }
    func provider(_ clip: Clip) -> NSItemProvider {
        if let url = assetURL(clip) { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        return NSItemProvider(object: (clip.text ?? "") as NSString)
    }
    func remove(_ clip: Clip) { archive.clips.removeAll { $0.id == clip.id }; archive.shelf.removeAll { $0.id == clip.id }; save(); cleanAssets() }
    func clear(shelf: Bool) { if shelf { archive.shelf = [] } else { archive.clips = [] }; save(); cleanAssets() }
    func clearClipboard() {
        pasteboard.clearContents()
        changeCount = pasteboard.changeCount
        clear(shelf: false)
        message = "Буфер обмена очищен"
    }
    private func cleanAssets() {
        let owned = Set((archive.clips + archive.shelf).compactMap(\.asset))
        let dir = root.appendingPathComponent("Assets")
        do { for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where !owned.contains(url.lastPathComponent) { try fm.removeItem(at: url) } }
        catch { message = "Не удалось очистить старые файлы: \(error.localizedDescription)" }
    }
    private func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

final class FocusClock: ObservableObject {
    @Published var remaining: TimeInterval = 25 * 60
    @Published var running = false
    @Published var completed = false
    private var deadline: Date?
    private var timer: Timer?
    init() { timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() } }
    deinit { timer?.invalidate() }
    func start(now: Date = Date()) { guard remaining > 0 else { return }; completed = false; deadline = now.addingTimeInterval(remaining); running = true }
    func pause(now: Date = Date()) { tick(now: now); deadline = nil; running = false }
    func reset(minutes: Int = 25) { running = false; completed = false; deadline = nil; remaining = TimeInterval(minutes * 60) }
    func tick(now: Date = Date()) {
        guard running, let deadline else { return }; remaining = max(0, deadline.timeIntervalSince(now))
        if remaining == 0 { running = false; completed = true; self.deadline = nil; NSSound(named: "Glass")?.play() }
    }
    var label: String { let seconds = Int(ceil(remaining)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

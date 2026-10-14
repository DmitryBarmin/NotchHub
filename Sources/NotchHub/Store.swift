import AppKit
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import ImageIO

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
    private var noteSaveTimer: Timer?
    private(set) var noteSavePending = false
    private let importQueue = DispatchQueue(label: "local.notchhub.import", qos: .utility)
    private let importsLock = NSLock()
    private var readyImports: [(Clip, URL?, Bool, Int, String?)] = []
    private var importGeneration = [0, 0]
    private var pendingImageBytes = 0
    private var pendingImportCount = 0
    private(set) var pendingClipboardImports = 0
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
        if monitor {
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in self?.capture() }
            pollTimer?.tolerance = 0.1
        }
    }
    deinit { pollTimer?.invalidate(); noteSaveTimer?.invalidate(); if noteSavePending { save() } }
    func assetURL(_ clip: Clip) -> URL? { clip.asset.map { root.appendingPathComponent("Assets").appendingPathComponent($0) } }
    func save() {
        noteSaveTimer?.invalidate(); noteSaveTimer = nil
        do {
            let url = root.appendingPathComponent("history.json")
            try JSONEncoder().encode(archive).write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            noteSavePending = false
        } catch { message = "Не удалось сохранить: \(error.localizedDescription)" }
    }
    func setNote(_ text: String) {
        guard archive.note != text else { return }
        archive.note = text
        noteSavePending = true
        noteSaveTimer?.invalidate()
        noteSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in self?.save() }
    }
    func flushPendingNote() { if noteSavePending { save() } }
    func insert(_ clip: Clip, shelf: Bool = false, chronological: Bool = false) {
        let existing = (shelf ? archive.shelf : archive.clips).first { $0.fingerprint == clip.fingerprint }
        if chronological, let existing, existing.date > clip.date { return }
        if shelf {
            archive.shelf.removeAll { $0.fingerprint == clip.fingerprint }
            let index = chronological ? archive.shelf.firstIndex(where: { $0.date < clip.date }) ?? archive.shelf.count : 0
            archive.shelf.insert(clip, at: index); archive.shelf = Array(archive.shelf.prefix(20))
        } else {
            archive.clips.removeAll { $0.fingerprint == clip.fingerprint }
            let index = chronological ? archive.clips.firstIndex(where: { $0.date < clip.date }) ?? archive.clips.count : 0
            archive.clips.insert(clip, at: index); archive.clips = Array(archive.clips.prefix(20))
        }
        save(); cleanAssets()
    }
    func addText(_ text: String, shelf: Bool = false) {
        guard !text.isEmpty else { return }
        guard text.utf8.count <= Self.maxBytes else { message = "Текст слишком большой (лимит 30 МБ)"; return }
        insert(Clip(kind: .text, title: String(text.prefix(100)), text: text, fingerprint: digest(Data(text.utf8))), shelf: shelf)
    }
    func addImage(_ data: Data, shelf: Bool = false) {
        guard let prepared = Self.prepareImage(data) else { message = "Картинка недоступна или больше 30 МБ"; return }
        let encoded = prepared.data, imageSize = prepared.size
        let hash = digest(encoded), name = hash + "." + prepared.extensionName
        do {
            let destination = root.appendingPathComponent("Assets").appendingPathComponent(name)
            if !fm.fileExists(atPath: destination.path) { try encoded.write(to: destination, options: .atomic) }
            insert(Clip(kind: .image, title: "Изображение · \(Int(imageSize.width)) × \(Int(imageSize.height))", asset: name, fingerprint: "image:" + hash), shelf: shelf)
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
    // Pasteboard snapshots stay on main; metadata, hashing and file reads use one worker.
    func enqueueImage(_ data: Data, shelf: Bool = false) {
        guard data.count <= Self.maxBytes else { message = "Картинка больше 30 МБ"; return }
        importsLock.lock()
        let capacity = pendingImportCount < 40 && pendingImageBytes + data.count <= 2 * Self.maxBytes
        if capacity { pendingImageBytes += data.count; pendingImportCount += 1 }
        importsLock.unlock()
        guard capacity else { message = "Обработка картинок занята — попробуй ещё раз после завершения"; return }
        if !shelf { pendingClipboardImports += 1 }
        let generation = importGeneration[shelf ? 1 : 0]
        let date = Date(), staging = root.appendingPathComponent(".import-" + UUID().uuidString)
        importQueue.async { [weak self] in
            guard let self else { return }
            defer { self.importsLock.lock(); self.pendingImageBytes -= data.count; self.pendingImportCount -= 1; self.importsLock.unlock() }
            do {
                guard let image = Self.prepareImage(data) else { throw ImportError.invalidImage }
                let hash = self.digest(image.data), name = hash + "." + image.extensionName
                try image.data.write(to: staging, options: .atomic)
                let clip = Clip(kind: .image, title: "Изображение · \(Int(image.size.width)) × \(Int(image.size.height))", asset: name, fingerprint: "image:" + hash, date: date)
                self.completeImport(clip, staging: staging, shelf: shelf, generation: generation)
            } catch { self.completeImport(Clip(kind: .image, title: "", fingerprint: ""), staging: nil, shelf: shelf, generation: generation, error: error.localizedDescription) }
        }
    }
    func enqueueFile(_ url: URL, shelf: Bool = true) {
        importsLock.lock()
        let capacity = pendingImportCount < 40
        if capacity { pendingImportCount += 1 }
        importsLock.unlock()
        guard capacity else { message = "Обработка файлов занята — попробуй ещё раз после завершения"; return }
        if !shelf { pendingClipboardImports += 1 }
        let generation = importGeneration[shelf ? 1 : 0]
        let date = Date(), staging = root.appendingPathComponent(".import-" + UUID().uuidString)
        importQueue.async { [weak self] in
            guard let self else { return }
            defer { self.importsLock.lock(); self.pendingImportCount -= 1; self.importsLock.unlock() }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let props = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard props.isRegularFile == true, (props.fileSize ?? 0) <= Self.maxBytes else { throw ImportError.invalidFile }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= Self.maxBytes else { throw ImportError.invalidFile }
                let clip: Clip, assetData: Data
                if UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true {
                    guard let image = Self.prepareImage(data) else { throw ImportError.invalidImage }
                    let hash = self.digest(image.data)
                    assetData = image.data
                    clip = Clip(kind: .image, title: "Изображение · \(Int(image.size.width)) × \(Int(image.size.height))", asset: hash + "." + image.extensionName, fingerprint: "image:" + hash, date: date)
                } else {
                    let name = self.digest(data) + "-" + url.lastPathComponent
                    assetData = data
                    clip = Clip(kind: .file, title: url.lastPathComponent, asset: name, fingerprint: "file:" + name, date: date)
                }
                try assetData.write(to: staging, options: .atomic)
                self.completeImport(clip, staging: staging, shelf: shelf, generation: generation)
            } catch { self.completeImport(Clip(kind: .file, title: "", fingerprint: ""), staging: nil, shelf: shelf, generation: generation, error: error.localizedDescription) }
        }
    }
    private func completeImport(_ clip: Clip, staging: URL?, shelf: Bool, generation: Int, error: String? = nil) {
        importsLock.lock(); readyImports.append((clip, staging, shelf, generation, error)); importsLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.drainImports() }
    }
    func drainImports() {
        importsLock.lock(); let ready = readyImports; readyImports.removeAll(); importsLock.unlock()
        for (clip, staging, shelf, generation, error) in ready {
            if !shelf { pendingClipboardImports -= 1 }
            guard generation == importGeneration[shelf ? 1 : 0] else { if let staging { try? fm.removeItem(at: staging) }; continue }
            if let error { message = "Не удалось добавить: " + error; continue }
            guard let staging, let destination = assetURL(clip) else { continue }
            do {
                if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: staging) }
                else { try fm.moveItem(at: staging, to: destination) }
                insert(clip, shelf: shelf, chronological: true)
            } catch { try? fm.removeItem(at: staging); message = "Не удалось добавить: " + error.localizedDescription }
        }
    }
    func finishImports() { importQueue.sync {}; drainImports(); flushPendingNote() }
    private enum ImportError: LocalizedError {
        case invalidImage, invalidFile
        var errorDescription: String? { self == .invalidImage ? "Картинка недоступна или больше 30 МБ" : "Нужен файл размером не больше 30 МБ" }
    }
    private static func prepareImage(_ data: Data) -> (data: Data, size: CGSize, extensionName: String)? {
        guard data.count <= maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, height > 0,
              let identifier = CGImageSourceGetType(source),
              let extensionName = UTType(identifier as String)?.preferredFilenameExtension else { return nil }
        // Keep original encoded bytes and format. Even a huge compressed image never
        // becomes a full raster during import; previews independently downsample it.
        return (data, CGSize(width: width, height: height), extensionName)
    }
    func capture() {
        let pb = pasteboard
        guard pb.changeCount != changeCount else { return }; changeCount = pb.changeCount
        guard !paused else { return }
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        let types = (pb.types ?? []) + (pb.pasteboardItems ?? []).flatMap { $0.types }
        guard !types.contains(where: { blocked.contains($0.rawValue) }) else { return }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls.prefix(20) { enqueueFile(url, shelf: false) }; return
        }
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) { enqueueImage(data); return }
        if let text = pb.string(forType: .string) { addText(text) }
    }
    func copy(_ clip: Clip) {
        let pb = pasteboard
        if let text = clip.text { pb.clearContents(); pb.setString(text, forType: .string) }
        else if let url = assetURL(clip), fm.fileExists(atPath: url.path) {
            pb.clearContents()
            if clip.kind == .image, let data = try? Data(contentsOf: url, options: .mappedIfSafe) {
                let type = url.pathExtension.lowercased()
                if type == "png" { pb.setData(data, forType: .png) }
                else if type == "tiff" || type == "tif" { pb.setData(data, forType: .tiff) }
                else if let type = UTType(filenameExtension: url.pathExtension) { pb.setData(data, forType: NSPasteboard.PasteboardType(type.identifier)) }
            }
            else { pb.writeObjects([url as NSURL]) }
        } else { message = "Файл недоступен"; return }
        changeCount = pb.changeCount; message = "Скопировано — вставь через ⌘V"
    }
    func provider(_ clip: Clip) -> NSItemProvider {
        if let url = assetURL(clip) { return NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        return NSItemProvider(object: (clip.text ?? "") as NSString)
    }
    func remove(_ clip: Clip) { archive.clips.removeAll { $0.id == clip.id }; archive.shelf.removeAll { $0.id == clip.id }; save(); cleanAssets() }
    func clear(shelf: Bool) { importGeneration[shelf ? 1 : 0] += 1; if shelf { archive.shelf = [] } else { archive.clips = [] }; save(); cleanAssets() }
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
    var hasScheduledTick: Bool { timer?.isValid == true }
    init() { }
    private func scheduleTicks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.1
    }
    private func stopTicks() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
    func start(now: Date = Date()) { guard remaining > 0 else { return }; completed = false; deadline = now.addingTimeInterval(remaining); running = true; scheduleTicks() }
    func pause(now: Date = Date()) { tick(now: now); deadline = nil; running = false; stopTicks() }
    func reset(minutes: Int = 25) { stopTicks(); running = false; completed = false; deadline = nil; remaining = TimeInterval(minutes * 60) }
    func tick(now: Date = Date()) {
        guard running, let deadline else { return }; remaining = max(0, deadline.timeIntervalSince(now))
        if remaining == 0 { stopTicks(); running = false; completed = true; self.deadline = nil; NSSound(named: "Glass")?.play() }
    }
    var label: String { let seconds = Int(ceil(remaining)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

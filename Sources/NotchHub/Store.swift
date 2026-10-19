import AppKit
import SwiftUI
import CryptoKit
import UniformTypeIdentifiers
import ImageIO
import Combine

struct Clip: Identifiable, Codable, Equatable {
    enum Kind: String, Codable { case text, image, file }
    var id: UUID = UUID()
    var kind: Kind
    var title: String
    var text: String?
    var asset: String?
    var fingerprint: String
    var date: Date = Date()
    var workspaceID: UUID?
}

final class HubStore: ObservableObject {
    @Published private(set) var archive = Archive()
    @Published var paused = false
    @Published var message: String?
    let root: URL
    let preferences: HubPreferences
    private let frontmostApp: () -> String?
    private var lastFrontmostApp: String?
    private var activationObserver: NSObjectProtocol?
    private var preferencesObserver: AnyCancellable?
    private var expiryTimer: Timer?
    private var assetBytes: [String: Int] = [:]
    private var writable = true
    private var lastSaveSucceeded = true
    private var readOnlyMessage: String?
    private var changeCount: Int
    private var pollTimer: Timer?
    private var noteSaveTimer: Timer?
    private(set) var noteSavePending = false
    private let importQueue = DispatchQueue(label: "local.notchhub.import", qos: .utility)
    private let importsLock = NSLock()
    private var readyImports: [(Clip, URL?, Bool, Int, String?)] = []
    private var importGeneration = [0, 0]
    private var shelfGenerations: [UUID?: Int] = [:]
    private var pendingImageBytes = 0
    private var pendingImportCount = 0
    private(set) var pendingClipboardImports = 0
    private let fm = FileManager.default
    private let pasteboard: NSPasteboard
    static let maxBytes = 30 * 1024 * 1024
    init(root: URL? = nil, monitor: Bool = true, pasteboard: NSPasteboard = .general, preferences: HubPreferences = HubPreferences(), frontmostApp: @escaping () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }) {
        self.preferences = preferences
        self.frontmostApp = frontmostApp
        self.lastFrontmostApp = frontmostApp()
        self.pasteboard = pasteboard
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("NotchHub")
        changeCount = pasteboard.changeCount
        do {
            try fm.createDirectory(at: self.root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
            // History can contain private text: restrict this application's storage.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
            let saved = self.root.appendingPathComponent("history.json")
            if fm.fileExists(atPath: saved.path) { archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: saved)) }
            let previous = archive
            enforcePolicy()
            if previous.clips != archive.clips, !save() { archive = previous }
            cleanAssets()
        } catch {
            writable = false
            readOnlyMessage = "История недоступна: \(error.localizedDescription). Данные сохранены без изменений; запись отключена до восстановления файла истории."
            message = readOnlyMessage
        }
        preferencesObserver = preferences.$current.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.preferencesChanged() }
        }
        scheduleExpiry()
        if monitor && writable {
            activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
                guard let self else { return }
                let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                _ = self.discardExcludedTransition(to: application?.bundleIdentifier ?? self.frontmostApp())
            }
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in self?.capture() }
            pollTimer?.tolerance = 0.3  // let macOS coalesce wakeups with other timers
        }
    }
    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        expiryTimer?.invalidate(); pollTimer?.invalidate(); noteSaveTimer?.invalidate()
        if noteSavePending { save() }
    }
    func assetURL(_ clip: Clip) -> URL? { clip.asset.map { root.appendingPathComponent("Assets").appendingPathComponent($0) } }
    private func allowWrite() -> Bool {
        guard writable else { message = readOnlyMessage; return false }
        return true
    }
    @discardableResult private func commit(_ previous: Archive, clean: Bool = false) -> Bool {
        guard save() else { archive = previous; return false }
        if clean { cleanAssets() }
        return true
    }
    @discardableResult func save() -> Bool {
        guard allowWrite() else { return false }
        noteSaveTimer?.invalidate(); noteSaveTimer = nil
        do {
            let url = root.appendingPathComponent("history.json")
            try JSONEncoder().encode(archive).write(to: url, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            noteSavePending = false; lastSaveSucceeded = true
            return true
        } catch { lastSaveSucceeded = false; message = "Не удалось сохранить: \(error.localizedDescription)"; return false }
    }
    var activeWorkspaceID: UUID? {
        preferences.isEnabled(.workspaces) ? archive.activeWorkspaceID : nil
    }
    var activeShelf: [Clip] { archive.shelf.filter { $0.workspaceID == activeWorkspaceID } }
    var currentNote: String {
        if let id = activeWorkspaceID, let workspace = archive.workspaces.first(where: { $0.id == id }) { return workspace.note }
        return archive.note
    }
    func setNote(_ text: String) {
        guard allowWrite() else { return }
        guard currentNote != text else { return }
        let old = archive
        if let id = activeWorkspaceID, let index = archive.workspaces.firstIndex(where: { $0.id == id }) { archive.workspaces[index].note = text }
        else { archive.note = text }
        guard diskUsage(archive) <= diskBudget else { archive = old; message = "Недостаточно места: заметка превышает лимит хранилища"; return }
        noteSavePending = true
        noteSaveTimer?.invalidate()
        noteSaveTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: false) { [weak self] _ in self?.save() }
    }
    func flushPendingNote() { if noteSavePending { save() } }
    @discardableResult func insert(_ incoming: Clip, shelf: Bool = false, chronological: Bool = false, assignWorkspace: Bool = true) -> Bool {
        guard allowWrite() else { return false }
        var clip = incoming
        if shelf, assignWorkspace { clip.workspaceID = activeWorkspaceID }
        if let id = clip.workspaceID, !archive.workspaces.contains(where: { $0.id == id }) { clip.workspaceID = nil }
        let existing = (shelf ? archive.shelf : archive.clips).first { $0.fingerprint == clip.fingerprint && (!shelf || $0.workspaceID == clip.workspaceID) }
        if chronological, let existing, existing.date > clip.date { return false }
        let old = archive
        if shelf {
            archive.shelf.removeAll { $0.fingerprint == clip.fingerprint && $0.workspaceID == clip.workspaceID }
            let index = chronological ? archive.shelf.firstIndex(where: { $0.date < clip.date }) ?? archive.shelf.count : 0
            archive.shelf.insert(clip, at: index)
        } else {
            archive.clips.removeAll { $0.fingerprint == clip.fingerprint }
            let index = chronological ? archive.clips.firstIndex(where: { $0.date < clip.date }) ?? archive.clips.count : 0
            archive.clips.insert(clip, at: index)
        }
        enforcePolicy()
        guard diskUsage(archive) <= diskBudget, (shelf ? archive.shelf : archive.clips).contains(where: { $0.id == clip.id }) else {
            archive = old; message = "Недостаточно места: избранное, полка и шаблоны защищены. Освободи место или увеличь лимит."
            return false
        }
        return commit(old, clean: true)
    }
    @discardableResult func addText(_ text: String, shelf: Bool = false) -> Bool {
        guard !text.isEmpty else { return false }
        guard text.utf8.count <= Self.maxBytes else { message = "Текст слишком большой (лимит 30 МБ)"; return false }
        return insert(Clip(kind: .text, title: String(text.prefix(100)), text: text, fingerprint: digest(Data(text.utf8))), shelf: shelf)
    }
    func addImage(_ data: Data, shelf: Bool = false) {
        guard allowWrite() else { return }
        guard let prepared = Self.prepareImage(data) else { message = "Картинка недоступна или больше 30 МБ"; return }
        let encoded = prepared.data, imageSize = prepared.size
        let hash = digest(encoded), name = hash + "." + prepared.extensionName
        do {
            let destination = root.appendingPathComponent("Assets").appendingPathComponent(name)
            let created = !fm.fileExists(atPath: destination.path)
            if created { try encoded.write(to: destination, options: .atomic) }
            if !insert(Clip(kind: .image, title: "Изображение · \(Int(imageSize.width)) × \(Int(imageSize.height))", asset: name, fingerprint: "image:" + hash), shelf: shelf), created {
                try? fm.removeItem(at: destination); assetBytes.removeValue(forKey: name)
            }
        } catch { message = "Не удалось сохранить картинку: \(error.localizedDescription)" }
    }
    func addFile(_ url: URL, shelf: Bool = true) {
        guard allowWrite() else { return }
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
            let created = !fm.fileExists(atPath: destination.path)
            if created { try data.write(to: destination, options: .atomic) }
            if !insert(Clip(kind: .file, title: url.lastPathComponent, asset: name, fingerprint: "file:" + name), shelf: shelf), created {
                try? fm.removeItem(at: destination); assetBytes.removeValue(forKey: name)
            }
        } catch { message = "Не удалось добавить файл: \(error.localizedDescription)" }
    }
    // Pasteboard snapshots stay on main; metadata, hashing and file reads use one worker.
    func enqueueImage(_ data: Data, shelf: Bool = false) {
        guard allowWrite() else { return }
        guard data.count <= Self.maxBytes else { message = "Картинка больше 30 МБ"; return }
        importsLock.lock()
        let capacity = pendingImportCount < 40 && pendingImageBytes + data.count <= 2 * Self.maxBytes
        if capacity { pendingImageBytes += data.count; pendingImportCount += 1 }
        importsLock.unlock()
        guard capacity else { message = "Обработка картинок занята — попробуй ещё раз после завершения"; return }
        if !shelf { pendingClipboardImports += 1 }
        let workspaceID = shelf ? activeWorkspaceID : nil
        let generation = shelf ? shelfGenerations[workspaceID, default: 0] : importGeneration[0]
        let date = Date(), staging = root.appendingPathComponent(".import-" + UUID().uuidString)
        importQueue.async { [weak self] in
            guard let self else { return }
            defer { self.importsLock.lock(); self.pendingImageBytes -= data.count; self.pendingImportCount -= 1; self.importsLock.unlock() }
            do {
                guard let image = Self.prepareImage(data) else { throw ImportError.invalidImage }
                let hash = self.digest(image.data), name = hash + "." + image.extensionName
                try image.data.write(to: staging, options: .atomic)
                let clip = Clip(kind: .image, title: "Изображение · \(Int(image.size.width)) × \(Int(image.size.height))", asset: name, fingerprint: "image:" + hash, date: date, workspaceID: workspaceID)
                self.completeImport(clip, staging: staging, shelf: shelf, generation: generation)
            } catch { self.completeImport(Clip(kind: .image, title: "", fingerprint: ""), staging: nil, shelf: shelf, generation: generation, error: error.localizedDescription) }
        }
    }
    func enqueueFile(_ url: URL, shelf: Bool = true) {
        guard allowWrite() else { return }
        importsLock.lock()
        let capacity = pendingImportCount < 40
        if capacity { pendingImportCount += 1 }
        importsLock.unlock()
        guard capacity else { message = "Обработка файлов занята — попробуй ещё раз после завершения"; return }
        if !shelf { pendingClipboardImports += 1 }
        let workspaceID = shelf ? activeWorkspaceID : nil
        let generation = shelf ? shelfGenerations[workspaceID, default: 0] : importGeneration[0]
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
                    clip = Clip(kind: .image, title: "Изображение · \(Int(image.size.width)) × \(Int(image.size.height))", asset: hash + "." + image.extensionName, fingerprint: "image:" + hash, date: date, workspaceID: workspaceID)
                } else {
                    let name = self.digest(data) + "-" + url.lastPathComponent
                    assetData = data
                    clip = Clip(kind: .file, title: url.lastPathComponent, asset: name, fingerprint: "file:" + name, date: date, workspaceID: workspaceID)
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
            guard generation == (shelf ? shelfGenerations[clip.workspaceID, default: 0] : importGeneration[0]) else { if let staging { try? fm.removeItem(at: staging) }; continue }
            if let error { message = "Не удалось добавить: " + error; continue }
            guard let staging, let destination = assetURL(clip) else { continue }
            do {
                let created = !fm.fileExists(atPath: destination.path)
                if created { try fm.moveItem(at: staging, to: destination) }
                else { try fm.removeItem(at: staging) }
                if !insert(clip, shelf: shelf, chronological: true, assignWorkspace: false), created {
                    try? fm.removeItem(at: destination)
                    if let name = clip.asset { assetBytes.removeValue(forKey: name) }
                }
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
    private func discardExcludedTransition(to applicationID: String?) -> Bool {
        let previous = lastFrontmostApp
        lastFrontmostApp = applicationID
        guard previous != applicationID, preferences.isEnabled(.privacy) else { return false }
        let excluded = Set(preferences.current.excludedAppIDs)
        guard previous.map(excluded.contains) == true || applicationID.map(excluded.contains) == true,
              pasteboard.changeCount != changeCount else { return false }
        // A pending copy may belong to the app that just lost focus. Discard it
        // before polling so switching to an allowed app cannot expose that copy.
        changeCount = pasteboard.changeCount
        return true
    }
    /// Explicit formatter input: current pasteboard only, never clipboard history.
    func textForFormatting(sourceApplicationID: String? = nil, automatic: Bool = true, from input: NSPasteboard? = nil) throws -> String {
        let pasteboard = input ?? self.pasteboard
        guard !automatic || !paused else { throw ClipActionFailure("Запись буфера на паузе — вставь текст вручную или продолжи запись") }
        let applicationIDs = [sourceApplicationID, frontmostApp()].compactMap { $0 }
        if automatic, preferences.isEnabled(.privacy), applicationIDs.contains(where: preferences.current.excludedAppIDs.contains) {
            throw ClipActionFailure("Чтение буфера для этого приложения отключено в настройках приватности")
        }
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        let types = (pasteboard.types ?? []) + (pasteboard.pasteboardItems ?? []).flatMap { $0.types }
        guard !types.contains(where: { blocked.contains($0.rawValue) }) else { throw ClipActionFailure("Защищённый буфер не читается") }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { throw ClipActionFailure("В буфере нет текста. Скопируй текст и нажми «Из буфера» или вставь его в поле") }
        guard text.utf8.count <= Self.maxBytes else { throw ClipActionFailure("Текст в буфере превышает 30 МБ") }
        return text
    }
    func capture() {
        guard writable else { return }
        let pb = pasteboard
        let foreground = frontmostApp()
        if discardExcludedTransition(to: foreground) { return }
        guard pb.changeCount != changeCount else { return }; changeCount = pb.changeCount
        guard !paused else { return }
        if preferences.isEnabled(.privacy), let app = foreground, preferences.current.excludedAppIDs.contains(app) { return }
        let blocked = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        let types = (pb.types ?? []) + (pb.pasteboardItems ?? []).flatMap { $0.types }
        guard !types.contains(where: { blocked.contains($0.rawValue) }) else { return }
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            for url in urls.prefix(20) { enqueueFile(url, shelf: false) }; return
        }
        for item in pb.pasteboardItems ?? [] {
            if let type = item.types.first(where: { UTType($0.rawValue)?.conforms(to: .image) == true }), let data = item.data(forType: type) {
                enqueueImage(data); return
            }
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
    func remove(_ clip: Clip) {
        guard allowWrite() else { return }
        let old = archive
        archive.clips.removeAll { $0.id == clip.id }; archive.shelf.removeAll { $0.id == clip.id }; archive.favorites.removeAll { $0.id == clip.id }
        commit(old, clean: true)
    }
    @discardableResult func clear(shelf: Bool) -> Bool {
        guard allowWrite() else { return false }
        let old = archive
        let oldHistoryGeneration = importGeneration[0], oldShelfGenerations = shelfGenerations
        if shelf {
            let workspace = activeWorkspaceID
            shelfGenerations[workspace, default: 0] += 1
            archive.shelf.removeAll { $0.workspaceID == workspace }
        } else { importGeneration[0] += 1; archive.clips = [] }
        guard commit(old, clean: true) else {
            importGeneration[0] = oldHistoryGeneration; shelfGenerations = oldShelfGenerations
            return false
        }
        return true
    }
    func clearClipboard() {
        guard clear(shelf: false) else { return }
        pasteboard.clearContents()
        changeCount = pasteboard.changeCount
        message = "Буфер обмена очищен"
    }
    @discardableResult func receiveTransfer(_ items: [TransferItem]) -> Bool {
        guard allowWrite() else { return false }
        guard preferences.isEnabled(.sharing) else { message = "Включи обмен в настройках"; return false }
        guard !items.isEmpty, items.count <= 20 else { message = "Передавай от 1 до 20 элементов"; return false }
        let transaction = UUID().uuidString
        var imported: [Clip] = [], payloads: [String: Data] = [:], total = 0
        for (index, item) in items.enumerated() {
            let fingerprint = "transfer:" + transaction + ":" + String(index) + ":" + item.id.uuidString
            switch item.kind {
            case .text:
                guard let text = item.text, !text.isEmpty, item.data == nil, text.utf8.count <= Self.maxBytes else { message = "Недопустимый текст в передаче"; return false }
                total += text.utf8.count
                imported.append(Clip(kind: .text, title: item.title.isEmpty ? String(text.prefix(100)) : item.title, text: text, fingerprint: fingerprint))
            case .image:
                guard item.text == nil, let data = item.data, let image = Self.prepareImage(data) else { message = "Недопустимое изображение в передаче"; return false }
                total += data.count
                let name = digest(data) + "." + image.extensionName
                payloads[name] = data
                imported.append(Clip(kind: .image, title: item.title.isEmpty ? "Изображение" : item.title, asset: name, fingerprint: fingerprint))
            case .file:
                guard item.text == nil, let data = item.data, data.count <= Self.maxBytes else { message = "Недопустимый файл в передаче"; return false }
                total += data.count
                let filename = URL(fileURLWithPath: item.filename ?? "File").lastPathComponent
                let name = digest(data) + "-" + (filename.isEmpty ? "File" : filename)
                payloads[name] = data
                imported.append(Clip(kind: .file, title: item.title.isEmpty ? filename : item.title, asset: name, fingerprint: fingerprint))
            }
            guard total <= 2 * Self.maxBytes else { message = "Передача больше 60 МБ"; return false }
        }
        var next = archive
        next.clips = Array((imported + next.clips).prefix(preferences.current.historyLimit))
        let sizes = payloads.mapValues(\.count)
        while diskUsage(next, pendingSizes: sizes) > diskBudget, next.clips.count > imported.count { next.clips.removeLast() }
        guard diskUsage(next, pendingSizes: sizes) <= diskBudget else { message = "Недостаточно места для всей передачи. Избранное и полка сохранены."; return false }
        let staging = root.appendingPathComponent(".transfer-" + transaction, isDirectory: true)
        var installed: [URL] = []
        do {
            // Encode and stage the whole batch before altering history or existing assets.
            let encoded = try JSONEncoder().encode(next)
            try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? fm.removeItem(at: staging) }
            for (name, data) in payloads { try data.write(to: staging.appendingPathComponent(name), options: .atomic) }
            for name in payloads.keys {
                let destination = root.appendingPathComponent("Assets").appendingPathComponent(name)
                if !fm.fileExists(atPath: destination.path) {
                    try fm.moveItem(at: staging.appendingPathComponent(name), to: destination)
                    installed.append(destination)
                }
            }
            let history = root.appendingPathComponent("history.json")
            try encoded.write(to: history, options: .atomic)
            // Atomic replacement inherits the restricted directory; permissions are tightened too.
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: history.path)
            noteSaveTimer?.invalidate(); noteSaveTimer = nil; noteSavePending = false
            archive = next; lastSaveSucceeded = true
            for (name, bytes) in sizes { assetBytes[name] = bytes }
            cleanAssets(); message = "Получено элементов: " + String(imported.count)
            return true
        } catch {
            for url in installed { try? fm.removeItem(at: url) }
            message = "Не удалось принять всю передачу: " + error.localizedDescription
            return false
        }
    }
    private var diskBudget: Int { max(1, preferences.current.diskLimitMB) * 1024 * 1024 }
    private func diskUsage(_ value: Archive, pendingSizes: [String: Int] = [:]) -> Int {
        let clips = value.clips + value.shelf + value.favorites
        let assets = Set(clips.compactMap(\.asset))
        var total = 0
        for name in assets {
            if let bytes = pendingSizes[name] { total += bytes; continue }
            if assetBytes[name] == nil {
                let url = root.appendingPathComponent("Assets").appendingPathComponent(name)
                assetBytes[name] = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            }
            total += assetBytes[name, default: 0]
        }
        let texts = Set(clips.compactMap(\.text) + value.templates.map(\.text) + [value.note] + value.workspaces.map(\.note))
        return total + texts.reduce(0) { $0 + $1.utf8.count }
    }
    func enforcePolicy(now: Date = Date()) {
        guard allowWrite() else { return }
        if preferences.current.expiryHours > 0 {
            let oldest = now.addingTimeInterval(-Double(preferences.current.expiryHours) * 3600)
            archive.clips.removeAll { $0.date < oldest }
        }
        archive.clips = Array(archive.clips.prefix(preferences.current.historyLimit))
        while diskUsage(archive) > diskBudget, !archive.clips.isEmpty { archive.clips.removeLast() }
        if diskUsage(archive) > diskBudget { message = "Защищённые данные превышают лимит. Освободи место или увеличь лимит хранилища." }
    }
    private func preferencesChanged() {
        objectWillChange.send()
        guard allowWrite() else { return }
        let old = archive
        enforcePolicy(); commit(old, clean: true); scheduleExpiry()
    }
    private func scheduleExpiry() {
        expiryTimer?.invalidate(); expiryTimer = nil
        guard writable, preferences.current.expiryHours > 0 else { return }
        expiryTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self else { return }
            let previous = self.archive
            self.enforcePolicy()
            if previous.clips != self.archive.clips { self.commit(previous, clean: true) }
        }
        expiryTimer?.tolerance = 10
    }
    func isFavorite(_ clip: Clip) -> Bool { archive.favorites.contains { $0.fingerprint == clip.fingerprint } }
    func toggleFavorite(_ clip: Clip) {
        guard allowWrite() else { return }
        guard preferences.isEnabled(.favorites) else { return }
        let old = archive
        if isFavorite(clip) { archive.favorites.removeAll { $0.fingerprint == clip.fingerprint }; commit(old, clean: true); return }
        var copy = clip; copy.id = UUID()
        archive.favorites.insert(copy, at: 0)
        guard diskUsage(archive) <= diskBudget else { archive = old; message = "Недостаточно места для избранного"; return }
        commit(old)
    }
    @discardableResult func addTemplate(title: String, text: String) -> Bool {
        guard allowWrite() else { return false }
        guard !text.isEmpty, text.utf8.count <= Self.maxBytes else { message = "Шаблон пустой или больше 30 МБ"; return false }
        let old = archive
        archive.templates.append(TextTemplate(title: title, text: text))
        guard diskUsage(archive) <= diskBudget else { archive = old; message = "Недостаточно места для шаблона"; return false }
        guard save() else { archive = old; return false }
        message = nil; return true
    }
    @discardableResult func updateTemplate(_ template: TextTemplate) -> Bool {
        guard allowWrite() else { return false }
        guard !template.text.isEmpty, template.text.utf8.count <= Self.maxBytes else { message = "Шаблон пустой или больше 30 МБ"; return false }
        guard let index = archive.templates.firstIndex(where: { $0.id == template.id }) else { message = "Шаблон больше не существует"; return false }
        let old = archive; archive.templates[index] = template
        guard diskUsage(archive) <= diskBudget else { archive = old; message = "Недостаточно места для шаблона"; return false }
        guard save() else { archive = old; return false }
        message = nil; return true
    }
    func removeTemplate(_ template: TextTemplate) {
        guard allowWrite() else { return }
        let old = archive; archive.templates.removeAll { $0.id == template.id }; commit(old)
    }
    func createWorkspace(name: String) {
        guard allowWrite() else { return }
        let old = archive
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let workspace = Workspace(name: name)
        archive.workspaces.append(workspace); archive.activeWorkspaceID = workspace.id; commit(old)
    }
    func selectWorkspace(_ id: UUID?) {
        guard allowWrite() else { return }
        let old = archive
        guard id == nil || archive.workspaces.contains(where: { $0.id == id }) else { return }
        archive.activeWorkspaceID = id; commit(old)
    }
    func renameWorkspace(id: UUID, name: String) {
        guard allowWrite() else { return }
        let old = archive
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let index = archive.workspaces.firstIndex(where: { $0.id == id }) else { return }
        archive.workspaces[index].name = name; commit(old)
    }
    func removeWorkspace(_ id: UUID) {
        guard allowWrite() else { return }
        let old = archive
        guard let workspace = archive.workspaces.first(where: { $0.id == id }) else { return }
        // Keep the removed workspace's note as a named template rather than dropping it.
        if !workspace.note.isEmpty { archive.templates.append(TextTemplate(title: workspace.name, text: workspace.note)) }
        for index in archive.shelf.indices where archive.shelf[index].workspaceID == id { archive.shelf[index].workspaceID = nil }
        for index in archive.favorites.indices where archive.favorites[index].workspaceID == id { archive.favorites[index].workspaceID = nil }
        archive.workspaces.removeAll { $0.id == id }
        if archive.activeWorkspaceID == id { archive.activeWorkspaceID = nil }
        commit(old)
    }
    func moveToWorkspace(_ clip: Clip, id: UUID?) {
        guard allowWrite() else { return }
        let old = archive
        guard id == nil || archive.workspaces.contains(where: { $0.id == id }) else { return }
        if let index = archive.shelf.firstIndex(where: { $0.id == clip.id }) { archive.shelf[index].workspaceID = id; commit(old) }
        else { var copy = clip; copy.id = UUID(); copy.workspaceID = id; insert(copy, shelf: true, assignWorkspace: false) }
    }
    @discardableResult func copyBatch(_ clips: [Clip], separator: String = "\n") -> Bool {
        guard !clips.isEmpty else { message = "Выбери элементы для копирования"; return false }
        if clips.allSatisfy({ $0.kind == .text && $0.text != nil }) {
            let texts = clips.compactMap(\.text)
            let bytes = texts.reduce(0) { $0 + $1.utf8.count } + max(0, texts.count - 1) * separator.utf8.count
            guard bytes <= Self.maxBytes else { message = "Текст слишком большой (лимит 30 МБ)"; return false }
            let text = texts.joined(separator: separator)
            pasteboard.clearContents(); pasteboard.setString(text, forType: .string)
        } else if clips.allSatisfy({ $0.kind != .text }) {
            let urls = clips.compactMap(assetURL)
            guard urls.count == clips.count, urls.allSatisfy({ fm.fileExists(atPath: $0.path) }) else { message = "Файл недоступен"; return false }
            pasteboard.clearContents(); guard pasteboard.writeObjects(urls.map { $0 as NSURL }) else { message = "Не удалось скопировать файлы"; return false }
        } else { message = "Копируй отдельно текст и файлы"; return false }
        changeCount = pasteboard.changeCount; message = "Скопировано — вставь через ⌘V"; return true
    }
    func providers(_ clips: [Clip]) -> [NSItemProvider] { clips.map(provider) }
    private func cleanAssets() {
        guard writable, lastSaveSucceeded else { return }
        let owned = Set((archive.clips + archive.shelf + archive.favorites).compactMap(\.asset))
        let dir = root.appendingPathComponent("Assets")
        do { for url in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where !owned.contains(url.lastPathComponent) { try fm.removeItem(at: url); assetBytes.removeValue(forKey: url.lastPathComponent) } }
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
    private let defaults: UserDefaults?
    private struct Saved: Codable { var remaining: TimeInterval; var deadline: Date?; var completed: Bool }
    init(defaults: UserDefaults? = nil, now: Date = Date()) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: "focusClockV1"), let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.remaining.isFinite, saved.remaining >= 0 {
            remaining = saved.remaining; deadline = saved.deadline; completed = saved.completed; running = deadline != nil
            tick(now: now)
            if running { scheduleTicks() }
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(Saved(remaining: remaining, deadline: deadline, completed: completed)) { defaults?.set(data, forKey: "focusClockV1") }
    }
    private func scheduleTicks() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.1
    }
    private func stopTicks() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
    func start(now: Date = Date()) { guard remaining > 0 else { return }; completed = false; deadline = now.addingTimeInterval(remaining); running = true; scheduleTicks(); persist() }
    func pause(now: Date = Date()) { tick(now: now); deadline = nil; running = false; stopTicks(); persist() }
    func reset(minutes: Int = 25) { stopTicks(); running = false; completed = false; deadline = nil; remaining = TimeInterval(max(1, min(10080, minutes))) * 60; persist() }
    func tick(now: Date = Date()) {
        guard running, let deadline else { return }; remaining = max(0, deadline.timeIntervalSince(now))
        if remaining == 0 { stopTicks(); running = false; completed = true; self.deadline = nil; persist(); NSSound(named: "Glass")?.play() }
    }
    var label: String { let seconds = Int(ceil(remaining)); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

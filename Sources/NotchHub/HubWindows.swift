import AppKit
import SwiftUI

/// Owns auxiliary windows; closing a window releases its view and background tasks.
final class HubWindows: NSObject, NSWindowDelegate {
    private var windows: [String: NSWindow] = [:]
    private var closed: [String: () -> Void] = [:]
    func show<Content: View>(_ key: String, title: String, size: CGSize = CGSize(width: 640, height: 460), onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        if let old = windows[key] { old.close() }
        let visible = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: CGSize(width: min(size.width, visible.width - 40), height: min(size.height, visible.height - 60))), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = title; window.isReleasedWhenClosed = false; window.delegate = self
        window.contentView = NSHostingView(rootView: content())
        window.contentMinSize = CGSize(width: min(440, visible.width - 40), height: min(300, visible.height - 60))
        windows[key] = window
        closed[key] = onClose
        window.center(); NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
    }
    func close(_ key: String) { windows[key]?.close() }
    func closeAll() { Array(windows.values).forEach { $0.close() } }
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let key = windows.first { $0.value === window }?.key
        windows = windows.filter { $0.value !== window }
        window.contentView = nil
        if let key { closed.removeValue(forKey: key)?() }
    }
}

struct TextToolsView: View {
    @ObservedObject var store: HubStore
    @State var input: String
    @State private var transform = TextTransform.plainText
    @State private var result = ""
    @State private var error: String?
    private func convert() {
        do { result = try transform.apply(to: input); error = nil }
        catch { self.error = error.localizedDescription; result = "" }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Действие", selection: $transform) { ForEach(TextTransform.allCases) { Text($0.title).tag($0) } }
            HStack {
                VStack(alignment: .leading) { Text("Исходный текст").font(.caption).foregroundStyle(.secondary); TextEditor(text: $input).font(.system(.body, design: .monospaced)) }
                VStack(alignment: .leading) { Text("Результат").font(.caption).foregroundStyle(.secondary); TextEditor(text: .constant(result)).font(.system(.body, design: .monospaced)) }
            }
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Text("Обработка на Mac · исходник сохраняется").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Копировать результат") { if store.addText(result), let clip = store.archive.clips.first { store.copy(clip) } }.buttonStyle(.borderedProminent).disabled(result.isEmpty || error != nil)
            }
        }.padding(20).onAppear { convert() }.onChange(of: transform) { _, _ in convert() }.onChange(of: input) { _, _ in convert() }
    }
}

struct TemplatesView: View {
    @ObservedObject var store: HubStore
    let edit: (TextTemplate?) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Постоянные тексты и команды").foregroundStyle(.secondary); Spacer(); Button("Новый шаблон") { edit(nil) }.buttonStyle(.borderedProminent) }
            if store.archive.templates.isEmpty { ContentUnavailableView("Шаблонов пока нет", systemImage: "text.badge.plus", description: Text("Сохрани часто используемый ответ, команду или ссылку.")) }
            else { List(store.archive.templates) { template in
                HStack { VStack(alignment: .leading) { Text(template.title).fontWeight(.medium); Text(template.text).lineLimit(2).font(.caption).foregroundStyle(.secondary) }; Spacer()
                    Button { if store.addText(template.text), let clip = store.archive.clips.first { store.copy(clip) } } label: { Image(systemName: "doc.on.doc") }.help("Копировать шаблон")
                    Button { edit(template) } label: { Image(systemName: "pencil") }.help("Изменить")
                    Button(role: .destructive) { store.removeTemplate(template) } label: { Image(systemName: "trash") }.help("Удалить шаблон")
                }.padding(.vertical, 4).buttonStyle(.borderless).accessibilityElement(children: .contain)
            } }
        }.padding(20)
    }
}

struct FavoritesLibraryView: View {
    @ObservedObject var store: HubStore
    let edit: (TextTemplate?) -> Void
    let action: (HubCommand, Clip) -> Void
    @State private var tab = 0
    var body: some View {
        VStack(spacing: 12) {
            Picker("Раздел", selection: $tab) { Text("Избранное").tag(0); Text("Шаблоны").tag(1) }.pickerStyle(.segmented).padding(.horizontal, 20).padding(.top, 18)
            if tab == 1 { TemplatesView(store: store, edit: edit) }
            else if store.archive.favorites.isEmpty { ContentUnavailableView("В избранном пока пусто", systemImage: "star", description: Text("Открой меню элемента в буфере и выбери «В избранное».")) }
            else { List(store.archive.favorites) { clip in
                HStack(spacing: 12) {
                    Image(systemName: clip.kind == .text ? "text.alignleft" : "photo").foregroundStyle(.blue)
                    VStack(alignment: .leading) { Text(clip.title).lineLimit(2); if let text = clip.text { Text(text).font(.caption).lineLimit(2).foregroundStyle(.secondary) } }
                    Spacer(); Button { store.copy(clip) } label: { Image(systemName: "doc.on.doc") }.help("Копировать")
                    if store.preferences.isEnabled(.detachedPreview) { Button { action(.detachPreview, clip) } label: { Image(systemName: "macwindow") }.help("Предпросмотр") }
                    Button { store.toggleFavorite(clip) } label: { Image(systemName: "star.slash") }.help("Убрать из избранного")
                }.padding(.vertical, 5).buttonStyle(.borderless).accessibilityElement(children: .contain)
            } }
        }
    }
}

struct TemplateEditorView: View {
    @ObservedObject var store: HubStore
    let template: TextTemplate?
    let finished: () -> Void
    @State private var title: String
    @State private var text: String
    @State private var error: String?
    init(store: HubStore, template: TextTemplate?, finished: @escaping () -> Void) {
        self.store = store; self.template = template; self.finished = finished
        _title = State(initialValue: template?.title ?? ""); _text = State(initialValue: template?.text ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Название", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $text).font(.system(.body, design: .monospaced))
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Text("Шаблоны не вытесняются историей").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Сохранить") {
                let saved: Bool
                if var item = template { item.title = title; item.text = text; saved = store.updateTemplate(item) }
                else { saved = store.addTemplate(title: title, text: text) }
                if saved { finished() } else { error = store.message ?? "Не удалось сохранить шаблон" }
            }.buttonStyle(.borderedProminent).disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.isEmpty || text.utf8.count > HubStore.maxBytes) }
        }.padding(20)
    }
}

struct WorkspaceEditorView: View {
    @ObservedObject var store: HubStore
    let workspace: Workspace?
    let finished: () -> Void
    @State private var name: String
    init(store: HubStore, workspace: Workspace?, finished: @escaping () -> Void) { self.store = store; self.workspace = workspace; self.finished = finished; _name = State(initialValue: workspace?.name ?? "") }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Набор объединяет полку и заметку. Буфер обмена остаётся общим.").foregroundStyle(.secondary)
            TextField("Например: Рабочая задача", text: $name).textFieldStyle(.roundedBorder)
            HStack { Spacer(); Button("Сохранить") { if let workspace { store.renameWorkspace(id: workspace.id, name: name) } else { store.createWorkspace(name: name) }; finished() }.buttonStyle(.borderedProminent).disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(24)
    }
}

struct TimerLibraryView: View {
    @ObservedObject var library: TimerLibrary
    @State private var title = ""
    @State private var minutes = 25
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { TextField("Название таймера", text: $title); TextField("Минуты", value: $minutes, format: .number).frame(width: 65); Text("мин").foregroundStyle(.secondary); Button("Добавить") { library.add(title: title, minutes: minutes); title = "" }.disabled(minutes < 1 || minutes > 10080) }.textFieldStyle(.roundedBorder)
            if library.timers.isEmpty { ContentUnavailableView("Нет таймеров", systemImage: "timer", description: Text("Дедлайны сохраняются при закрытии приложения.")) }
            else { List(library.timers) { timer in
                HStack(spacing: 12) {
                    VStack(alignment: .leading) { Text(timer.title).fontWeight(.medium); ProgressView(value: max(0, min(timer.duration, timer.remaining)), total: timer.duration).frame(maxWidth: 200) }
                    Spacer(); Text(timer.label).monospacedDigit().font(.title2).foregroundStyle(timer.completed ? Color.green : Color.primary)
                    Button { if timer.running { library.pause(id: timer.id) } else { library.start(id: timer.id) } } label: { Image(systemName: timer.running ? "pause.fill" : "play.fill") }.disabled(timer.remaining == 0).help(timer.running ? "Пауза" : "Начать")
                    Button { library.reset(id: timer.id) } label: { Image(systemName: "arrow.counterclockwise") }.help("Сбросить")
                    Button(role: .destructive) { library.remove(id: timer.id) } label: { Image(systemName: "trash") }.help("Удалить таймер")
                }.padding(.vertical, 6).buttonStyle(.borderless).accessibilityElement(children: .contain)
            } }
            Text("Отсчёт сохраняется после перезапуска приложения").font(.caption).foregroundStyle(.secondary)
        }.padding(20)
    }
}

struct ScreenshotHistoryView: View {
    @ObservedObject var library: ScreenshotLibrary
    let reopen: (ScreenshotEntry) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Последние 20 фрагментов · до 200 МБ · скрытые области нельзя восстановить").font(.caption).foregroundStyle(.secondary)
            if library.entries.isEmpty { ContentUnavailableView("Пока нет скриншотов", systemImage: "photo.stack", description: Text("Выдели область скриншотером. После закрытия редактора она появится здесь.")) }
            else { List(library.entries) { entry in
                HStack(spacing: 14) {
                    AssetImageView(url: library.url(for: entry), maxPixelSize: 180, fill: false).frame(width: 110, height: 70)
                    VStack(alignment: .leading, spacing: 4) { Text(entry.title); Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary) }
                    Spacer(); Button("Редактировать") { reopen(entry) }
                    Button(role: .destructive) { library.remove(entry) } label: { Image(systemName: "trash") }.help("Удалить скриншот")
                }.padding(.vertical, 6).buttonStyle(.borderless).accessibilityElement(children: .contain)
            } }
        }.padding(20)
    }
}

struct QuickShareView: View {
    let clip: Clip
    let qr: () -> Void
    let share: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label(clip.title, systemImage: clip.kind == .text ? "text.alignleft" : "doc").font(.title3).lineLimit(3)
            Text("Выбери способ передачи. Ничего не отправляется автоматически.").foregroundStyle(.secondary)
            if let text = clip.text { Text(text).lineLimit(6).font(.system(.body, design: .monospaced)).textSelection(.enabled) }
            HStack { if clip.text != nil { Button("Показать QR-код", action: qr).disabled((clip.text?.utf8.count ?? 0) > 2048) }; Button("Поделиться через macOS…", action: share).buttonStyle(.borderedProminent) }
            if (clip.text?.utf8.count ?? 0) > 2048 { Text("Для QR-кода выбери текст до 2048 байт.").font(.caption).foregroundStyle(.secondary) }
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A native drag session represents each selected item separately, never as an archive.
struct BatchDragHandle: NSViewRepresentable {
    let clips: [Clip]
    let store: HubStore
    func makeNSView(context: Context) -> BatchDraggingView { BatchDraggingView() }
    func updateNSView(_ view: BatchDraggingView, context: Context) { view.clips = clips; view.store = store }
}
final class BatchDraggingView: NSView, NSDraggingSource {
    var clips: [Clip] = []
    weak var store: HubStore?
    override init(frame: NSRect) { super.init(frame: frame); setAccessibilityLabel("Перетащить выбранные элементы") }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { ("Перетащить" as NSString).draw(in: bounds, withAttributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor]) }
    override func mouseDown(with event: NSEvent) {
        guard let store else { return }
        let items = clips.compactMap { clip -> NSDraggingItem? in
            let writer: NSPasteboardWriting
            if let text = clip.text { writer = text as NSString }
            else if let url = store.assetURL(clip) { writer = url as NSURL }
            else { return nil }
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(CGRect(x: 0, y: 0, width: 28, height: 28), contents: NSImage(systemSymbolName: clip.kind == .text ? "text.alignleft" : "doc", accessibilityDescription: nil))
            return item
        }
        guard !items.isEmpty else { return }
        beginDraggingSession(with: items, event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

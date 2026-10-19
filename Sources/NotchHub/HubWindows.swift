import AppKit
import SwiftUI

/// A feature lives in the existing notch panel, including its cancellation lifetime.
final class HubSurface: Identifiable {
    let id = UUID()
    let key: String
    let title: String
    let content: AnyView
    init(key: String, title: String, content: AnyView) { self.key = key; self.title = title; self.content = content }
}

final class HubWindows {
    var present: ((HubSurface?) -> Void)?
    private var key: String?
    private var closed: (() -> Void)?
    func show<Content: View>(_ key: String, title: String, size: CGSize = CGSize(width: 640, height: 460), onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        closeAll()
        self.key = key; closed = onClose
        present?(HubSurface(key: key, title: title, content: AnyView(content())))
    }
    func close(_ key: String) { if self.key == key { closeAll() } }
    func closeAll() {
        let callback = closed
        key = nil; closed = nil
        present?(nil)
        callback?()
    }
}

struct FormattingInput {
    let text: String
    let externalSelection: ExternalTextSelection?
    let notice: String
    static func resolve(external: () throws -> FormattingInput, clipboard: () throws -> String) -> FormattingInput {
        do { return FormattingInput(text: try clipboard(), externalSelection: nil, notice: "Текст из буфера — результат можно скопировать") }
        catch {
            let clipboardError = error.localizedDescription
            do { return try external() }
            catch { return FormattingInput(text: "", externalSelection: nil, notice: error.localizedDescription + "\n" + clipboardError) }
        }
    }
}

struct TextToolsView: View {
    @ObservedObject var store: HubStore
    @State var input: String
    @State var externalSelection: ExternalTextSelection?
    @State var notice = ""
    var readClipboard: ((Bool) throws -> String)?
    @State private var selection = NSRange(location: 0, length: 0)
    @State private var showFormats = false
    @State private var error: String?
    @State private var editor: NSTextView?
    @State private var externalApplied = false
    private func convert(_ transform: TextTransform) {
        do {
            if let externalSelection {
                let result = try transform.apply(to: input)
                try externalSelection.replace(with: result)
                input = result; showFormats = false; externalApplied = true
                error = "Текст изменён в исходном приложении"
            } else if let editor {
                let range = selection.length > 0 ? selection : NSRange(location: 0, length: (input as NSString).length)
                let replacement = try TextSelectionTransform.apply(transform, to: input, range: range)
                guard editor.shouldChangeText(in: range, replacementString: replacement.text) else { return }
                editor.textStorage?.replaceCharacters(in: range, with: replacement.text)
                editor.didChangeText(); editor.setSelectedRange(replacement.selection)
                editor.window?.makeFirstResponder(editor)
                showFormats = false; error = nil
            }
        } catch { self.error = error.localizedDescription }
    }
    private func importClipboard() {
        do {
            input = try readClipboard?(false) ?? store.textForFormatting(automatic: false, from: .general)
            externalSelection = nil; externalApplied = false; error = nil
            selection = NSRange(location: 0, length: 0)
            editor?.setSelectedRange(selection)
            notice = "Текст из буфера — результат можно скопировать"
        } catch { self.error = error.localizedDescription }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(externalSelection == nil ? "Выдели текст и выбери формат" : "Формат применяется к выделению в исходном приложении").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Из буфера", action: importClipboard).help("Прочитать текущий текст из буфера")
                Button { showFormats.toggle() } label: { Label("Формат", systemImage: "textformat") }
                    .disabled(externalApplied || input.isEmpty)
                    .popover(isPresented: $showFormats, arrowEdge: .trailing) {
                        LazyVGrid(columns: Array(repeating: GridItem(.fixed(44), spacing: 4), count: 4), spacing: 4) {
                            ForEach(TextTransform.allCases) { transform in
                                Button { convert(transform) } label: {
                                    Group {
                                        if let example = transform.caseExample {
                                            Text(example).font(.system(size: 13, weight: .semibold, design: .monospaced))
                                        } else { Image(systemName: transform.symbol) }
                                    }.frame(width: 44, height: 32)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                                        .contentShape(Rectangle())
                                }.buttonStyle(.plain).help(transform.title).accessibilityLabel(transform.title)
                            }
                        }.padding(10)
                    }
            }
            if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            if input.isEmpty { Text("Вставь текст в поле или скопируй его и нажми «Из буфера»").font(.caption).foregroundStyle(.secondary) }
            SelectionTextEditor(text: $input, selection: $selection, editor: $editor, editable: externalSelection == nil)
                .frame(maxWidth: .infinity, minHeight: 80, maxHeight: .infinity)
                .layoutPriority(1)
                .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            if let error { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            HStack {
                Text("Обработка на Mac").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Копировать текст") {
                    guard input.utf8.count <= HubStore.maxBytes else { error = "Текст превышает 30 МБ"; return }
                    store.copy(Clip(kind: .text, title: String(input.prefix(100)), text: input, fingerprint: ""))
                }.disabled(input.isEmpty)
            }
        }.padding(12)
    }
}

struct SelectionTextEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    @Binding var editor: NSTextView?
    var editable = true
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isRichText = false; view.isEditable = editable; view.isSelectable = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular)
        view.backgroundColor = .clear; view.textColor = .labelColor
        view.textContainerInset = CGSize(width: 8, height: 8)
        view.allowsUndo = true; view.string = text; view.delegate = context.coordinator
        scroll.drawsBackground = false
        DispatchQueue.main.async { editor = view }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        if view.string != text { view.string = text }
        view.isEditable = editable
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectionTextEditor
        init(_ parent: SelectionTextEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.text = view.string }
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if let view = notification.object as? NSTextView { parent.selection = view.selectedRange() }
        }
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

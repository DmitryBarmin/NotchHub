import AppKit
import SwiftUI
import Carbon
import Combine

private let notchHubUpdateConfiguration = AppUpdater.Configuration(
    repository: "DmitryBarmin/NotchHub", appName: "NotchHub",
    bundleIdentifier: "local.notchhub.app", relaunchArguments: []
)

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var updater: AppUpdater!
    var status: NSStatusItem!
    var store: HubStore!
    var clock: FocusClock!
    var controllers: [PanelController] = []
    var hotKeys: ClipboardHotKeys!
    var screenObserver: NSObjectProtocol?
    var cycle = ClipboardCycle()
    var keyboardController: PanelController?
    var shortcutSettings: ShortcutSettings!
    var sectionSettings: SectionSettings!
    var layoutSettings: LayoutSettings!
    var screenshotSettings: ScreenshotSettings!
    var previewSettings: ScreenshotSettings!
    var editorSettings: EditorShortcutSettings!
    var screenshotController: ScreenshotController!
    var settingsWindow: NSWindow?
    var shortcutMenuItem: NSMenuItem?
    var preferences: HubPreferences!
    var commands: CommandShortcuts!
    var timerLibrary: TimerLibrary!
    var screenshotLibrary: ScreenshotLibrary!
    let windows = HubWindows()
    let externalSelection = ExternalSelectionCoordinator()
    let detached = DetachedPreviewController()
    let imageOCR = ImageOCRController()
    let quickShare = QuickShareController()
    var transfer: ClipboardTransfer!
    private var preferencesObserver: AnyCancellable?
    private var demoBoard: NSPasteboard?
    private var pendingOpenURLs: [URL] = []
    private var activeDefaults = UserDefaults.standard
    private var appliedSectionVisibility: SectionVisibility?
    func applicationDidFinishLaunching(_ notification: Notification) {
        externalSelection.start()
        updater = AppUpdater(configuration: notchHubUpdateConfiguration)
        let demo = CommandLine.arguments.contains("--demo")
        let defaults = demo ? UserDefaults(suiteName: "local.notchhub.demo")! : .standard
        activeDefaults = defaults
        if demo { defaults.removePersistentDomain(forName: "local.notchhub.demo") }
        preferences = HubPreferences(defaults: defaults)
        if demo {
            let board = NSPasteboard.withUniqueName(); demoBoard = board
            store = HubStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("NotchHub-Demo-" + UUID().uuidString), monitor: false, pasteboard: board, preferences: preferences)
        } else { store = HubStore(preferences: preferences) }
        clock = FocusClock(defaults: defaults); timerLibrary = TimerLibrary(defaults: defaults)
        screenshotLibrary = ScreenshotLibrary(root: store.root.appendingPathComponent("Screenshots"))
        let transferSettings = demo ? TransferSettings(defaults: defaults, writeKey: { _, _ in throw TransferFailure("В демо ключ отправки не изменяется") }) : TransferSettings(defaults: defaults)
        transfer = ClipboardTransfer(settings: transferSettings)
        screenshotController = ScreenshotController { [weak self] in self?.configureScreens() }
        editorSettings = EditorShortcutSettings(defaults: defaults)
        screenshotController.editorShortcuts = editorSettings
        screenshotController.recognizedText = { [weak self] text in
            guard let self, self.preferences.isEnabled(.imageOCR) else { return }
            self.showRecognizedText(text)
        }
        windows.present = { [weak self] surface in
            guard let self else { return }
            if let surface { self.currentController?.state.showSurface?(surface) }
            else { self.controllers.filter { $0.state.surface != nil }.forEach { $0.state.showSurface?(nil) } }
        }
        screenshotController.archiveEditor = { [weak self] editor in
            guard let self, self.preferences.isEnabled(.screenshotHistory) else { return }
            do { _ = try self.screenshotLibrary.save(editor, id: editor.archiveID) }
            catch { self.store.message = error.localizedDescription }
        }
        screenshotSettings = ScreenshotSettings(defaults: defaults) { [weak self] in self?.takeScreenshot() }
        previewSettings = ScreenshotSettings(defaults: defaults, preferenceKey: "previewShortcut", standard: ClipboardShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | optionKey)), signature: 0x4E485056,
            released: { [weak self] in self?.hideKeyboardPreview() }, action: { [weak self] in self?.showKeyboardPreview() })
        sectionSettings = SectionSettings(defaults: defaults) { [weak self] in self?.applySectionVisibility($0) }
        applySectionVisibility(sectionSettings.current)
        if !preferences.isEnabled(.multipleTimers) { timerLibrary.pauseAll() }
        layoutSettings = LayoutSettings(defaults: defaults) { [weak self] layout in self?.controllers.forEach { $0.applyLayout(layout) } }
        configureScreens()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in Task { @MainActor in self?.configureScreens() } }
        hotKeys = ClipboardHotKeys(advance: { [weak self] in self?.advanceClipboard() }, finish: { [weak self] in self?.finishClipboard() }, shortcut: ClipboardShortcut.load(from: defaults))
        controllers.forEach { $0.state.shortcut = hotKeys.shortcut }
        shortcutSettings = ShortcutSettings(hotKeys: hotKeys, defaults: defaults) { [weak self] shortcut in
            guard let self else { return }
            self.cancelClipboard()
            self.controllers.forEach { $0.state.shortcut = shortcut }
            self.shortcutMenuItem?.title = "Буфер: " + shortcut.instruction
            self.store.message = nil
        }
        if let error = hotKeys.error { store.message = error }
        commands = CommandShortcuts(preferences: preferences, defaults: defaults) { [weak self] command in self?.perform(command) }
        preferencesObserver = preferences.$current.dropFirst().receive(on: RunLoop.main).sink { [weak self] value in
            guard let self else { return }
            if !value.enabled.contains(.detachedPreview) { self.detached.closeAll() }
            if !value.enabled.contains(.imageOCR) { self.imageOCR.cancel(); self.windows.close("ocr") }
            if !value.enabled.contains(.multipleTimers) { self.timerLibrary.pauseAll(); self.windows.close("timers") }
            if !value.enabled.contains(.sharing) { self.quickShare.closeAll(); self.windows.close("share"); self.windows.close("transfer"); self.transfer.cancel() }
            if !value.enabled.contains(.screenshotHistory) { self.windows.close("screenshots") }
            if !value.enabled.contains(.favorites) { self.windows.close("favorites"); self.windows.close("template") }
            if !value.enabled.contains(.textTools) { self.windows.close("textTools"); self.windows.close("uuidGenerator") }
            if !value.enabled.contains(.workspaces) { self.windows.close("workspace") }
        }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "capsule.inset.filled", accessibilityDescription: "NotchHub")
        status.button?.toolTip = "NotchHub — буфер, полка, заметки и фокус"
        let menu = NSMenu()
        item("Открыть NotchHub", action: #selector(show), menu: menu)
        let shortcut = NSMenuItem(title: "Буфер: " + hotKeys.shortcut.instruction, action: nil, keyEquivalent: "")
        shortcutMenuItem = shortcut
        menu.addItem(shortcut)
        item("Сделать скриншот", action: #selector(takeScreenshot), menu: menu)
        item("Избранное и шаблоны…", action: #selector(showFavorites), menu: menu)
        item("История скриншотов…", action: #selector(showScreenshots), menu: menu)
        item("Таймеры…", action: #selector(showTimers), menu: menu)
        item("Генератор UUID…", action: #selector(showUUIDGenerator), menu: menu)
        item("Передать буфер…", action: #selector(showTransfer), menu: menu)
        item("Настройки…", action: #selector(showSettings), menu: menu)
        item("Пауза / продолжить запись буфера", action: #selector(pause), menu: menu)
        item("Открыть папку хранения", action: #selector(storage), menu: menu)
        menu.addItem(.separator())
        item("Выйти из NotchHub", action: #selector(quit), menu: menu, key: "q")
        status.menu = menu
        menu.delegate = self
        configureMainMenu()
        if demo {
            if CommandLine.arguments.contains("--uuid-demo") { showUUIDGenerator() }
            else if CommandLine.arguments.contains("--format-demo") {
                windows.show("textTools", title: "Преобразование текста") {
                    TextToolsView(store: store, input: "Привет, NotchHub!\nВыдели часть текста и нажми «Формат».\nStraße 😀 example")
                }
            } else { seedDemo(); show() }
            currentController?.state.pinned = true
        }
        else if CommandLine.arguments.contains("--show") { show(); currentController?.state.pinned = true }
        if !pendingOpenURLs.isEmpty { let urls = pendingOpenURLs; pendingOpenURLs = []; application(NSApplication.shared, open: urls) }
    }
    var currentController: PanelController? { controllers.first(where: { $0.contains(NSEvent.mouseLocation) }) ?? controllers.first }
    func configureScreens() {
        guard screenshotController?.active != true else { return }
        if keyboardController != nil { cancelClipboard() }
        controllers.forEach { $0.dispose() }
        controllers = NSScreen.screens.map {
            let state = HubState(); state.shortcut = hotKeys?.shortcut ?? ClipboardShortcut.load(from: activeDefaults)
            state.applySectionVisibility(sectionSettings?.current ?? .all)
            state.openSettings = { [weak self] in self?.showSettings() }
            state.takeScreenshot = { [weak self] in self?.takeScreenshot() }
            state.prepareExternalSelection = { [weak self] in self?.externalSelection.prepare() }
            state.runCommand = { [weak self] command, clip in self?.perform(command, clip: clip) }
            state.closeSurface = { [weak self] in self?.windows.closeAll() }
            state.editWorkspace = { [weak self] id in self?.editWorkspace(id) }
            return PanelController(store: store, clock: clock, state: state, screen: $0, layout: layoutSettings?.current ?? .standard)
        }
    }
    func applySectionVisibility(_ visibility: SectionVisibility) {
        let previous = appliedSectionVisibility
        appliedSectionVisibility = visibility
        if !visibility.isEnabled(.clipboard), previous?.isEnabled(.clipboard) != false { cancelClipboard() }
        if !visibility.isEnabled(.timer), previous?.isEnabled(.timer) != false {
            if clock.running { clock.pause() }
            timerLibrary?.pauseAll()
        }
        controllers.forEach { $0.applySectionVisibility(visibility) }
    }
    func advanceClipboard() {
        guard (sectionSettings?.current ?? .all).isEnabled(.clipboard) else {
            cancelClipboard(); store.message = "Буфер скрыт — включи раздел в настройках"; return
        }
        if keyboardController == nil {
            store.capture()
            guard store.pendingClipboardImports == 0 else {
                store.message = "Сохраняю новый буфер — повтори \(hotKeys?.shortcut.label ?? ClipboardShortcut.standard.label) через мгновение"
                return
            }
            guard let controller = currentController else { return }
            keyboardController = controller
            cycle.begin(ids: store.archive.clips.map(\.id))
            controller.state.keyboardSelecting = true
            controller.state.tab = 0
            controller.state.showPreview?(nil)
            controller.expand()
        } else { cycle.advance() }
        keyboardController?.state.selectedClipboardID = cycle.selectedID
        if keyboardController?.state.previewClip != nil { showKeyboardPreview() }
        store.message = cycle.selectedID == nil ? "Буфер пуст" : (hotKeys.error ?? "Отпусти \(hotKeys.shortcut.primaryLabel) — выбрать · затем ⌘V — вставить")
    }
    func showKeyboardPreview() {
        guard let controller = keyboardController, let id = cycle.selectedID, let clip = store.archive.clips.first(where: { $0.id == id }) else { return }
        controller.state.showPreview?(clip)
    }
    func hideKeyboardPreview() { keyboardController?.state.showPreview?(nil) }
    func finishClipboard() {
        let id = cycle.finish()
        if store.pendingClipboardImports == 0, let id, let clip = store.archive.clips.first(where: { $0.id == id }) { store.copy(clip) }
        endKeyboardSession()
    }
    func cancelClipboard() {
        _ = cycle.finish()
        hotKeys?.cancelSession()
        endKeyboardSession()
    }
    func endKeyboardSession() {
        hideKeyboardPreview()
        guard let controller = keyboardController else { return }
        controller.state.keyboardSelecting = false
        controller.state.selectedClipboardID = nil
        if !controller.state.pinned { controller.collapse() }
        keyboardController = nil
    }
    func item(_ title: String, action: Selector, menu: NSMenu, key: String = "") { let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item) }
    @objc func show() { currentController?.expand(); currentController?.panel.makeKeyAndOrderFront(nil) }
    func configureMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "NotchHub", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "NotchHub")
        item("Сделать скриншот", action: #selector(takeScreenshot), menu: appMenu)
        item("Избранное и шаблоны…", action: #selector(showFavorites), menu: appMenu)
        item("История скриншотов…", action: #selector(showScreenshots), menu: appMenu)
        item("Таймеры…", action: #selector(showTimers), menu: appMenu)
        item("Генератор UUID…", action: #selector(showUUIDGenerator), menu: appMenu)
        item("Передать буфер…", action: #selector(showTransfer), menu: appMenu)
        item("Настройки…", action: #selector(showSettings), menu: appMenu, key: ",")
        appMenu.addItem(.separator())
        item("Выйти из NotchHub", action: #selector(quit), menu: appMenu, key: "q")
        appMenu.delegate = self
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(title: "Правка", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Правка")
        for (title, action, key) in [("Отменить", "undo:", "z"), ("Повторить", "redo:", "Z"), ("Вырезать", "cut:", "x"), ("Копировать", "copy:", "c"), ("Вставить", "paste:", "v"), ("Выбрать всё", "selectAll:", "a")] {
            editMenu.addItem(NSMenuItem(title: title, action: Selector(action), keyEquivalent: key))
        }
        editItem.submenu = editMenu; main.addItem(editItem); NSApp.mainMenu = main
    }
    func menuWillOpen(_ menu: NSMenu) {
        let features: [(Selector, HubFeature)] = [(#selector(showUUIDGenerator), .textTools), (#selector(showFavorites), .favorites), (#selector(showScreenshots), .screenshotHistory), (#selector(showTimers), .multipleTimers), (#selector(showTransfer), .sharing)]
        for item in menu.items {
            if let feature = features.first(where: { item.action == $0.0 })?.1 { item.isHidden = !preferences.isEnabled(feature) }
        }
    }
    @objc func showSettings() {
        cancelClipboard()
        windows.show("settings", title: "Настройки NotchHub") {
            ShortcutSettingsView(settings: shortcutSettings, sections: sectionSettings, layout: layoutSettings, screenshots: screenshotSettings, previews: previewSettings, updater: updater, preferences: preferences, commands: commands, transferSettings: transfer.settings, editorSettings: editorSettings)
        }
    }
    @objc func takeScreenshot() {
        guard !screenshotController.active else { return }
        cancelClipboard()
        settingsWindow?.orderOut(nil)
        controllers.forEach { $0.dispose() }; controllers.removeAll()
        screenshotController.start()
    }
    @objc func pause() { store.paused.toggle() }
    @objc func storage() { NSWorkspace.shared.open(store.root) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { store?.finishImports(); transfer?.cancel(); detached.closeAll(); quickShare.closeAll(); windows.closeAll(); demoBoard?.releaseGlobally() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }

    func selectedClip(explicit: Clip? = nil) -> Clip? {
        if let explicit { return explicit }
        let state = (keyboardController ?? currentController)?.state
        if let clip = state?.previewClip { return clip }
        let id = state?.selectedClipboardID ?? state?.actionClipID
        return (store.archive.clips + store.archive.favorites + store.archive.shelf).first { $0.id == id } ?? store.archive.clips.first
    }
    func selectedBatch() -> [Clip] {
        guard let state = currentController?.state else { return [] }
        let source = state.tab == 1 ? store.activeShelf : (state.favoritesOnly ? store.archive.favorites : store.archive.clips)
        return source.filter { state.batchIDs.contains($0.id) }
    }
    func perform(_ command: HubCommand, clip explicit: Clip? = nil) {
        if let feature = command.feature, !preferences.isEnabled(feature) { return }
        let clip = selectedClip(explicit: explicit)
        switch command {
        case .openFavorites: showFavorites()
        case .openScreenshots: showScreenshots()
        case .openTimers: showTimers()
        case .generateUUID: showUUIDGenerator()
        case .openWorkspaces: windows.closeAll(); currentController?.state.showPreview?(nil); currentController?.state.tab = 1; show()
        case .toggleCapture: pause()
        case .transformText:
            if let text = explicit?.text {
                windows.show("textTools", title: "Преобразование текста") { TextToolsView(store: store, input: text) }
            } else {
                let input = FormattingInput.resolve(external: {
                    let selection = try externalSelection.selection()
                    return FormattingInput(text: selection.text, externalSelection: selection.canReplace ? selection : nil,
                        notice: selection.canReplace ? "Выделение в исходном приложении" : "Выделенный текст — результат можно скопировать")
                }, clipboard: { try store.textForFormatting(sourceApplicationID: externalSelection.sourceApplicationID, automatic: false, from: .general) })
                windows.show("textTools", title: "Формат текста") {
                    TextToolsView(store: store, input: input.text, externalSelection: input.externalSelection, notice: input.notice, readClipboard: { automatic in try self.store.textForFormatting(sourceApplicationID: self.externalSelection.sourceApplicationID, automatic: automatic, from: .general) })
                }
            }
        case .detachPreview:
            guard let clip else { store.message = "Выбери элемент для предпросмотра"; return }
            currentController?.state.showPreview?(clip); show()
        case .recognizeImage:
            guard let clip, clip.kind == .image, let url = store.assetURL(clip) else { store.message = "Выбери картинку для распознавания"; return }
            store.message = "Распознаю текст на Mac…"
            windows.show("ocr", title: "Распознавание текста", onClose: { [weak self] in self?.imageOCR.cancel() }) {
                ProgressView("Распознаю текст на Mac…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            imageOCR.recognize(url: url) { [weak self] result in
                guard let self, self.preferences.isEnabled(.imageOCR) else { return }
                switch result {
                case .success(let text):
                    self.store.message = text.isEmpty ? "Текст не найден" : "Текст распознан"
                    if !text.isEmpty { self.showRecognizedText(text) }
                    else { self.windows.show("ocr", title: "Распознавание текста") { Text("Текст не найден").padding(20) } }
                case .failure(let error):
                    self.store.message = error.localizedDescription
                    self.windows.show("ocr", title: "Распознавание текста") { Text(error.localizedDescription).padding(20) }
                }
            }
        case .batchCopy:
            let clips = selectedBatch()
            if clips.isEmpty {
                guard currentController?.state.beginBatchSelection() == true else { store.message = "Включи Буфер или Полку в настройках для выбора элементов"; return }
                store.message = nil; show()
            } else { _ = store.copyBatch(clips) }
        case .share:
            let clips = explicit.map { [$0] } ?? selectedBatch()
            openTransfer(clips.isEmpty ? clip.map { [$0] } ?? [] : clips)
        }
    }
    func showRecognizedText(_ text: String) {
        windows.show("ocr", title: "Распознанный текст") { TextToolsView(store: store, input: text) }
    }
    @objc func showUUIDGenerator() {
        guard preferences.isEnabled(.textTools) else { return }
        windows.show("uuidGenerator", title: "Генератор UUID") {
            UUIDGeneratorView { [weak self] text in
                self?.store.copy(Clip(kind: .text, title: "UUID", text: text, fingerprint: ""))
            }
        }
    }
    @objc func showFavorites() {
        guard preferences.isEnabled(.favorites) else { return }
        windows.show("favorites", title: "Избранное и шаблоны") { FavoritesLibraryView(store: store, edit: { [weak self] in self?.editTemplate($0) }, action: { [weak self] command, clip in self?.perform(command, clip: clip) }) }
    }
    func editTemplate(_ template: TextTemplate?) {
        windows.show("template", title: template == nil ? "Новый шаблон" : "Изменить шаблон") { TemplateEditorView(store: store, template: template) { [weak self] in self?.windows.close("template") } }
    }
    func editWorkspace(_ id: UUID?) {
        guard preferences.isEnabled(.workspaces) else { return }
        windows.show("workspace", title: "Рабочий набор", size: CGSize(width: 500, height: 260)) { WorkspaceEditorView(store: store, workspace: store.archive.workspaces.first { $0.id == id }) { [weak self] in self?.windows.close("workspace") } }
    }
    @objc func showScreenshots() {
        guard preferences.isEnabled(.screenshotHistory) else { return }
        windows.show("screenshots", title: "История скриншотов", size: CGSize(width: 740, height: 520)) { ScreenshotHistoryView(library: screenshotLibrary) { [weak self] entry in
            guard let self else { return }
            do {
                let editor = try self.screenshotLibrary.editor(for: entry)
                editor.shortcuts = self.editorSettings
                editor.recognizedText = { [weak self] text in self?.showRecognizedText(text) }
                editor.close = { [weak self] in self?.windows.close("screenshotEditor") }
                self.windows.show("screenshotEditor", title: "Редактировать скриншот", onClose: { [weak self, weak editor] in
                    guard let self, let editor else { return }
                    editor.cancelRecognition(); editor.closeColorPanel()
                    if self.preferences.isEnabled(.screenshotHistory) { self.screenshotController.archiveEditor?(editor) }
                }) { EmbeddedScreenshotEditor(editor: editor) }

            } catch { self.store.message = error.localizedDescription }
        } }
    }
    @objc func showTimers() {
        guard preferences.isEnabled(.multipleTimers) else { return }
        windows.show("timers", title: "Таймеры") { TimerLibraryView(library: timerLibrary) }
    }
    @objc func showTransfer() { openTransfer(selectedBatch()) }
    func openTransfer(_ clips: [Clip]) {
        guard preferences.isEnabled(.sharing) else { return }
        windows.show("transfer", title: "Передача буфера", size: CGSize(width: 680, height: 560), onClose: { [weak self] in self?.transfer.cancel() }) { TransferWindowView(service: transfer, store: store, accept: { [weak self] incoming in
            guard let self, self.preferences.isEnabled(.sharing) else { return }
            if self.store.receiveTransfer(incoming) { self.transfer.dismissIncoming() }
        }) }
        if !clips.isEmpty { transfer.prepare(clips: clips) }
    }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard preferences != nil else { pendingOpenURLs.append(contentsOf: urls); return }
        guard preferences.isEnabled(.sharing), let url = urls.first else { return }
        openTransfer([]); transfer.receive(url: url)
    }
    func showSystemShare(_ clip: Clip) {
        guard let view = NSApp.keyWindow?.contentView ?? currentController?.panel.contentView else { return }
        let items: [Any] = clip.text.map { [$0] } ?? store.assetURL(clip).map { [$0] } ?? []
        quickShare.share(items: items, from: view)
    }
    private func seedDemo() {
        store.addText("{\"app\":\"NotchHub\",\"version\":\"2.0\",\"local\":true}")
        store.addText("https://example.com/article?utm_source=demo&topic=mac")
        store.addText("Тестовая заметка — данные демонстрации")
        if let clip = store.archive.clips.first { store.toggleFavorite(clip) }
        store.addTemplate(title: "Ответ коллеге", text: "Принял задачу. Вернусь с результатом после проверки.")
        store.createWorkspace(name: "Рабочая задача"); store.setNote("Проверить макет, приложить скриншоты, отправить результат.")
        store.selectWorkspace(nil)
        timerLibrary.add(title: "Фокус", minutes: 25); timerLibrary.add(title: "Перерыв", minutes: 5)
        for (index, color) in [NSColor.systemIndigo, .systemTeal, .systemOrange].enumerated() {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 640, pixelsHigh: 360, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            color.setFill(); CGRect(x: 0, y: 0, width: 640, height: 360).fill()
            ("NOTCH HUB 2.0\nТестовый скриншот \(index + 1)" as NSString).draw(at: CGPoint(x: 40, y: 130), withAttributes: [.font: NSFont.systemFont(ofSize: 28, weight: .semibold), .foregroundColor: NSColor.white])
            NSGraphicsContext.restoreGraphicsState()
            if let png = bitmap.representation(using: .png, properties: [:]) { store.addImage(png) }
            if let image = bitmap.cgImage {
                let editor = ScreenshotEditor(image: image, size: CGSize(width: 640, height: 360)); editor.selection = CGRect(x: 0, y: 0, width: 640, height: 360)
                _ = try? screenshotLibrary.save(editor)
            }
        }
    }
}

@main struct NotchHubApp {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--diagnose-selection") { SelectionDiagnostics.run(); return }
        if AppUpdater.runHelperIfRequested(configuration: notchHubUpdateConfiguration) { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

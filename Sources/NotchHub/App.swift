import AppKit
import SwiftUI
import Carbon

private let notchHubUpdateConfiguration = AppUpdater.Configuration(
    repository: "DmitryBarmin/NotchHub", appName: "NotchHub",
    bundleIdentifier: "local.notchhub.app", relaunchArguments: []
)

final class AppDelegate: NSObject, NSApplicationDelegate {
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
    var screenshotController: ScreenshotController!
    var settingsWindow: NSWindow?
    var shortcutMenuItem: NSMenuItem?
    func applicationDidFinishLaunching(_ notification: Notification) {
        updater = AppUpdater(configuration: notchHubUpdateConfiguration)
        store = HubStore(); clock = FocusClock()
        screenshotController = ScreenshotController { [weak self] in self?.configureScreens() }
        screenshotSettings = ScreenshotSettings { [weak self] in self?.takeScreenshot() }
        previewSettings = ScreenshotSettings(preferenceKey: "previewShortcut", standard: ClipboardShortcut(keyCode: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey | optionKey)), signature: 0x4E485056,
            released: { [weak self] in self?.hideKeyboardPreview() }, action: { [weak self] in self?.showKeyboardPreview() })
        sectionSettings = SectionSettings { [weak self] in self?.applySectionVisibility($0) }
        layoutSettings = LayoutSettings { [weak self] layout in self?.controllers.forEach { $0.applyLayout(layout) } }
        configureScreens()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.configureScreens() }
        hotKeys = ClipboardHotKeys(advance: { [weak self] in self?.advanceClipboard() }, finish: { [weak self] in self?.finishClipboard() }, shortcut: ClipboardShortcut.load())
        controllers.forEach { $0.state.shortcut = hotKeys.shortcut }
        shortcutSettings = ShortcutSettings(hotKeys: hotKeys) { [weak self] shortcut in
            guard let self else { return }
            self.cancelClipboard()
            self.controllers.forEach { $0.state.shortcut = shortcut }
            self.shortcutMenuItem?.title = "Буфер: " + shortcut.instruction
            self.store.message = nil
        }
        if let error = hotKeys.error { store.message = error }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "capsule.inset.filled", accessibilityDescription: "NotchHub")
        status.button?.toolTip = "NotchHub — буфер, полка, заметки и фокус"
        let menu = NSMenu()
        item("Открыть NotchHub", action: #selector(show), menu: menu)
        let shortcut = NSMenuItem(title: "Буфер: " + hotKeys.shortcut.instruction, action: nil, keyEquivalent: "")
        shortcutMenuItem = shortcut
        menu.addItem(shortcut)
        item("Сделать скриншот", action: #selector(takeScreenshot), menu: menu)
        item("Настройки…", action: #selector(showSettings), menu: menu)
        item("Пауза / продолжить запись буфера", action: #selector(pause), menu: menu)
        item("Открыть папку хранения", action: #selector(storage), menu: menu)
        menu.addItem(.separator())
        item("Выйти из NotchHub", action: #selector(quit), menu: menu, key: "q")
        status.menu = menu
        configureMainMenu()
        if CommandLine.arguments.contains("--show") { show(); currentController?.state.pinned = true }
    }
    var currentController: PanelController? { controllers.first(where: { $0.contains(NSEvent.mouseLocation) }) ?? controllers.first }
    func configureScreens() {
        guard screenshotController?.active != true else { return }
        if keyboardController != nil { cancelClipboard() }
        controllers.forEach { $0.dispose() }
        controllers = NSScreen.screens.map {
            let state = HubState(); state.shortcut = hotKeys?.shortcut ?? ClipboardShortcut.load()
            state.applySectionVisibility(sectionSettings?.current ?? .all)
            state.openSettings = { [weak self] in self?.showSettings() }
            state.takeScreenshot = { [weak self] in self?.takeScreenshot() }
            return PanelController(store: store, clock: clock, state: state, screen: $0, layout: layoutSettings?.current ?? .standard)
        }
    }
    func applySectionVisibility(_ visibility: SectionVisibility) {
        if !visibility.isEnabled(.clipboard) { cancelClipboard() }
        if !visibility.isEnabled(.timer), clock.running { clock.pause() }
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
        item("Настройки…", action: #selector(showSettings), menu: appMenu, key: ",")
        appMenu.addItem(.separator())
        item("Выйти из NotchHub", action: #selector(quit), menu: appMenu, key: "q")
        appItem.submenu = appMenu; main.addItem(appItem); NSApp.mainMenu = main
    }
    @objc func showSettings() {
        cancelClipboard()
        if settingsWindow == nil {
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(640, max(1, visible.width - 40)), height: min(540, max(1, visible.height - 60))), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "NotchHub — настройки"; window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.contentMinSize = NSSize(width: min(500, max(1, visible.width - 40)), height: min(460, max(1, visible.height - 60)))
            window.contentView = NSHostingView(rootView: ShortcutSettingsView(settings: shortcutSettings, sections: sectionSettings, layout: layoutSettings, screenshots: screenshotSettings, previews: previewSettings, updater: updater))
            window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
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
    func applicationWillTerminate(_ notification: Notification) { store?.finishImports() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
}

@main struct NotchHubApp {
    @MainActor static func main() {
        if AppUpdater.runHelperIfRequested(configuration: notchHubUpdateConfiguration) { return }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

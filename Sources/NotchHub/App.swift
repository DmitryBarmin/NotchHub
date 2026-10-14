import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    var status: NSStatusItem!
    var store: HubStore!
    var clock: FocusClock!
    var controllers: [PanelController] = []
    var hotKeys: ClipboardHotKeys!
    var screenObserver: NSObjectProtocol?
    var cycle = ClipboardCycle()
    var keyboardController: PanelController?
    func applicationDidFinishLaunching(_ notification: Notification) {
        store = HubStore(); clock = FocusClock()
        configureScreens()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.configureScreens() }
        hotKeys = ClipboardHotKeys(advance: { [weak self] in self?.advanceClipboard() }, finish: { [weak self] in self?.finishClipboard() })
        if let error = hotKeys.error { store.message = error }
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "capsule.inset.filled", accessibilityDescription: "NotchHub")
        status.button?.toolTip = "NotchHub — буфер, полка, заметки и фокус"
        let menu = NSMenu()
        item("Открыть NotchHub", action: #selector(show), menu: menu)
        let shortcut = NSMenuItem(title: "Буфер: ⌘⌥V, затем держи ⌘ и нажимай V", action: nil, keyEquivalent: "")
        menu.addItem(shortcut)
        item("Пауза / продолжить запись буфера", action: #selector(pause), menu: menu)
        item("Открыть папку хранения", action: #selector(storage), menu: menu)
        menu.addItem(.separator())
        item("Выйти из NotchHub", action: #selector(quit), menu: menu, key: "q")
        status.menu = menu
        if CommandLine.arguments.contains("--show") { show(); currentController?.state.pinned = true }
    }
    var currentController: PanelController? { controllers.first(where: { $0.contains(NSEvent.mouseLocation) }) ?? controllers.first }
    func configureScreens() {
        if keyboardController != nil { cancelClipboard() }
        controllers.forEach { $0.dispose() }
        controllers = NSScreen.screens.map { PanelController(store: store, clock: clock, state: HubState(), screen: $0) }
    }
    func advanceClipboard() {
        if keyboardController == nil {
            store.capture()
            guard store.pendingClipboardImports == 0 else {
                store.message = "Сохраняю новый буфер — повтори ⌘⌥V через мгновение"
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
        store.message = cycle.selectedID == nil ? "Буфер пуст" : "Отпусти ⌘ — выбрать · затем ⌘V — вставить"
    }
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
        guard let controller = keyboardController else { return }
        controller.state.keyboardSelecting = false
        controller.state.selectedClipboardID = nil
        if !controller.state.pinned { controller.collapse() }
        keyboardController = nil
    }
    func item(_ title: String, action: Selector, menu: NSMenu, key: String = "") { let item = NSMenuItem(title: title, action: action, keyEquivalent: key); item.target = self; menu.addItem(item) }
    @objc func show() { currentController?.expand(); currentController?.panel.makeKeyAndOrderFront(nil) }
    @objc func pause() { store.paused.toggle() }
    @objc func storage() { NSWorkspace.shared.open(store.root) }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) { store?.finishImports() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { show(); return true }
}

@main struct NotchHubApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

import AppKit
import ApplicationServices

/// Recheck the actual OS grants after every update; a saved preference is not a grant.
@MainActor enum SelectionPermissionAccess {
    static var granted: Bool { AXIsProcessTrusted() && CGPreflightPostEventAccess() }

    static func request() {
        guard !granted else { return }
        let alert = NSAlert()
        alert.messageText = "Разрешите исправление выделенного текста"
        alert.informativeText = "Для сочетания клавиш NotchHub нужен доступ к управлению другими приложениями. Включите NotchHub в открывшихся настройках. В новых версиях macOS раздел называется «Управление устройством и доступ к данным», в прежних — «Универсальный доступ». После включения повторите сочетание на выделенном тексте."
        alert.addButton(withTitle: "Открыть настройки")
        alert.addButton(withTitle: "Позже")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}


/// A selection captured before NotchHub takes keyboard focus.
struct ExternalTextSelection {
    let text: String
    let canReplace: Bool
    private let element: AXUIElement
    private let application: NSRunningApplication
    private let range: CFRange?
    private let requiresForeground: Bool

    enum SelectionError: LocalizedError {
        case permissionRequired, unavailable, noSelection, readOnly, protectedField, selectionChanged, replacementFailed

        var errorDescription: String? {
            switch self {
            case .permissionRequired:
                return "Разрешите NotchHub доступ в Системных настройках → Конфиденциальность и безопасность → Универсальный доступ."
            case .unavailable:
                return "Приложение не предоставляет доступ к выделенному тексту."
            case .noSelection:
                return "Сначала выделите текст в другом приложении."
            case .protectedField:
                return "Защищённое поле пароля не читается и не исправляется."
            case .readOnly:
                return "Приложение не разрешает изменять выделенный текст."
            case .selectionChanged:
                return "Выделение изменилось. Выделите текст заново и повторите действие."
            case .replacementFailed:
                return "Не удалось заменить выделенный текст в приложении."
            }
        }
    }

    static func capture(application source: NSRunningApplication? = nil, requiresForeground: Bool = false) throws -> ExternalTextSelection {
        guard AXIsProcessTrusted() else { throw SelectionError.permissionRequired }
        guard let application = source ?? NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !application.isTerminated else { throw SelectionError.noSelection }

        if requiresForeground, NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier { throw SelectionError.selectionChanged }
        let focused = try requiresForeground ? SelectionAccessibility.focusedElement(in: application) : SelectionAccessibility.element(in: application)
        let element = focused.element
        guard !SelectionAccessibility.isProtected(element) else { throw SelectionError.protectedField }
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid == application.processIdentifier else { throw SelectionError.unavailable }
        let range = try? selectedRange(in: element)
        if requiresForeground {
            guard let range, range.location >= 0, range.length > 0 else { throw SelectionError.noSelection }
            guard focused.provenFocus, isWritableSelection(in: element) else { throw SelectionError.readOnly }
        }
        let text = try selectedText(in: element, range: range)
        guard !text.isEmpty, text.utf8.count <= HubStore.maxBytes else { throw SelectionError.noSelection }
        return ExternalTextSelection(text: text, canReplace: range != nil && focused.provenFocus && isWritableSelection(in: element), element: element, application: application, range: range, requiresForeground: requiresForeground)
    }

    func validate() throws {
        guard AXIsProcessTrusted() else { throw SelectionError.permissionRequired }
        var pid: pid_t = 0
        guard !application.isTerminated,
              let currentApplication = NSRunningApplication(processIdentifier: application.processIdentifier),
              currentApplication.launchDate == application.launchDate,
              AXUIElementGetPid(element, &pid) == .success,
              pid == application.processIdentifier else { throw SelectionError.selectionChanged }
        guard let foreground = NSWorkspace.shared.frontmostApplication,
              foreground.processIdentifier == application.processIdentifier || (!requiresForeground && foreground.processIdentifier == ProcessInfo.processInfo.processIdentifier) else {
            throw SelectionError.selectionChanged
        }
        let focused = try requiresForeground ? SelectionAccessibility.focusedElement(in: application) : SelectionAccessibility.element(in: application)
        guard CFEqual(focused.element, element), !canReplace || focused.provenFocus else { throw SelectionError.selectionChanged }
        guard !SelectionAccessibility.isProtected(element) else { throw SelectionError.protectedField }
        let currentRange = try? Self.selectedRange(in: element)
        guard currentRange?.location == range?.location, currentRange?.length == range?.length,
              try Self.selectedText(in: element, range: currentRange) == text else { throw SelectionError.selectionChanged }
    }

    func replace(with replacement: String) throws {
        try validate()
        guard canReplace, Self.isWritableSelection(in: element) else { throw SelectionError.readOnly }
        // Only replace the selected text. Never overwrite AXValue or simulate a paste.
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, replacement as CFString) == .success else {
            throw SelectionError.replacementFailed
        }
    }

    private static func selectedText(in element: AXUIElement, range: CFRange?) throws -> String {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
           let text = value as? String, !text.isEmpty { return text }
        // Some native/web editors expose only StringForRange; request just the selection.
        guard var requestedRange = range else { throw SelectionError.unavailable }
        guard let parameter = AXValueCreate(.cfRange, &requestedRange),
              AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let text = value as? String else { throw SelectionError.unavailable }
        return text
    }

    private static func selectedRange(in element: AXUIElement) throws -> CFRange {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { throw SelectionError.unavailable }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        var range = CFRange()
        guard AXValueGetType(axValue) == .cfRange, AXValueGetValue(axValue, .cfRange, &range) else {
            throw SelectionError.unavailable
        }
        return range
    }

    private static func isWritableSelection(in element: AXUIElement) -> Bool {
        var settable = DarwinBoolean(false)
        return AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success && settable.boolValue
    }
}

/// Retains the source application across a nonactivating panel's key-window change.
/// Captures only at user interaction boundaries; never polls or reads clipboard contents.
final class ExternalSelectionCoordinator {
    private var source: NSRunningApplication?
    private var prepared: Result<ExternalTextSelection, Error>?
    var sourceApplicationID: String? { source?.bundleIdentifier }
    private var activationObserver: NSObjectProtocol?
    private let frontmost: () -> NSRunningApplication?
    private let capture: (NSRunningApplication) throws -> ExternalTextSelection

    init(frontmost: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
         capture: @escaping (NSRunningApplication) throws -> ExternalTextSelection = { try ExternalTextSelection.capture(application: $0) }) {
        self.frontmost = frontmost; self.capture = capture
    }
    func start() {
        remember(frontmost())
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            self?.remember(notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
    }
    private func remember(_ application: NSRunningApplication?) {
        guard let application, application.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        source = application; prepared = nil
    }
    func prepare() {
        if let app = frontmost(), app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            source = app
        }
        guard let source, !source.isTerminated else { prepared = nil; return }
        let candidate = Result { try capture(source) }
        // Once the panel has focus the source may temporarily report no focused control.
        // Preserve its pre-click snapshot; selection() still validates it before use.
        if case .success = candidate { prepared = candidate }
        else if case .success? = prepared { /* Keep the pre-focus snapshot until validation. */ }
        else { prepared = candidate }
    }
    func selection() throws -> ExternalTextSelection {
        prepare()
        guard let prepared else { throw ExternalTextSelection.SelectionError.noSelection }
        self.prepared = nil
        let selection = try prepared.get()
        try selection.validate()
        return selection
    }
    deinit {
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}

/// Explicit, read-only troubleshooting in the real app process; never logs user text.
enum SelectionDiagnostics {
    static func run() {
        let application = NSWorkspace.shared.frontmostApplication
        var report: [String: Any] = ["trusted": AXIsProcessTrusted(), "process": ProcessInfo.processInfo.processIdentifier,
                                     "sourceBundle": application?.bundleIdentifier ?? "", "sourcePID": application?.processIdentifier ?? 0]
        if let application, AXIsProcessTrusted() {
            let app = AXUIElementCreateApplication(application.processIdentifier)
            var focused: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused)
            report["focusedError"] = error.rawValue
            if let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
                let element = unsafeBitCast(focused, to: AXUIElement.self)
                for (name, attribute) in [("role", kAXRoleAttribute), ("selectedText", kAXSelectedTextAttribute), ("range", kAXSelectedTextRangeAttribute)] {
                    var value: CFTypeRef?
                    let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
                    report[name + "Error"] = status.rawValue
                    if name == "role" { report["role"] = value as? String ?? "" }
                    if name == "selectedText" { report["selectedLength"] = (value as? String)?.utf16.count ?? 0 }
                }
                var settable = DarwinBoolean(false)
                report["writableError"] = AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable).rawValue
                report["writable"] = settable.boolValue
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), let output = String(data: data, encoding: .utf8) { print(output) }
    }
}

/// Access only the current source window, capped at 160 nodes and ten levels.
/// A selection without proven focus is useful for copying, never for source mutation.
enum SelectionAccessibility {
    private static var enabled: Set<pid_t> = []
    static func enableIfNeeded(_ application: NSRunningApplication) {
        guard AXIsProcessTrusted(), !enabled.contains(application.processIdentifier) else { return }
        enabled.insert(application.processIdentifier)
        let app = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 0.025)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
    }
    private static func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(element, 0.025)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success else { return nil }
        return result
    }
    private static func uiElement(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }
    static func isProtected(role: String?, subrole: String?, protectedContent: Bool) -> Bool {
        protectedContent || [role, subrole].compactMap { $0?.lowercased() }.contains { $0.contains("secure") || $0.contains("password") }
    }
    static func isProtected(_ element: AXUIElement) -> Bool {
        isProtected(role: value(element, kAXRoleAttribute) as? String,
                    subrole: value(element, kAXSubroleAttribute) as? String,
                    protectedContent: (value(element, "AXProtectedContent") as? Bool) == true)
    }
    /// Hotkeys never search cached/background selections or descendants of an unfocused control.
    static func focusedElement(in application: NSRunningApplication) throws -> (element: AXUIElement, provenFocus: Bool) {
        enableIfNeeded(application)
        let app = AXUIElementCreateApplication(application.processIdentifier)
        let focused = uiElement(value(app, kAXFocusedUIElementAttribute))
            ?? uiElement(value(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute))
        guard let focused else { throw ExternalTextSelection.SelectionError.unavailable }
        var pid: pid_t = 0
        guard AXUIElementGetPid(focused, &pid) == .success, pid == application.processIdentifier else {
            throw ExternalTextSelection.SelectionError.selectionChanged
        }
        guard !isProtected(focused) else { throw ExternalTextSelection.SelectionError.protectedField }
        return (focused, true)
    }
    private static func hasSelection(_ element: AXUIElement) -> Bool {
        guard !isProtected(element) else { return false }
        guard let rangeValue = value(element, kAXSelectedTextRangeAttribute), CFGetTypeID(rangeValue) == AXValueGetTypeID() else {
            return (value(element, kAXSelectedTextAttribute) as? String)?.isEmpty == false
        }
        var range = CFRange()
        let ax = unsafeBitCast(rangeValue, to: AXValue.self)
        return AXValueGetType(ax) == .cfRange && AXValueGetValue(ax, .cfRange, &range) && range.location >= 0 && range.length > 0
    }
    static func element(in application: NSRunningApplication) throws -> (element: AXUIElement, provenFocus: Bool) {
        let deadline = CFAbsoluteTimeGetCurrent() + 0.22
        enableIfNeeded(application)
        let app = AXUIElementCreateApplication(application.processIdentifier)
        let focused = uiElement(value(app, kAXFocusedUIElementAttribute))
        if let focused, hasSelection(focused) { return (focused, true) }
        let systemFocused = uiElement(value(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute))
        if let systemFocused {
            var pid: pid_t = 0
            if AXUIElementGetPid(systemFocused, &pid) == .success, pid == application.processIdentifier, hasSelection(systemFocused) { return (systemFocused, true) }
        }
        guard let root = focused ?? uiElement(value(app, kAXFocusedWindowAttribute)) else {
            throw ExternalTextSelection.SelectionError.unavailable
        }
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var cursor = 0
        var selected: AXUIElement?
        var multiple = false
        while cursor < queue.count && cursor < 160 && CFAbsoluteTimeGetCurrent() < deadline {
            let (node, depth) = queue[cursor]; cursor += 1
            if hasSelection(node) {
                if (value(node, kAXFocusedAttribute) as? Bool) == true { return (node, true) }
                if selected == nil { selected = node } else { multiple = true }
            }
            if depth < 10, let children = value(node, kAXChildrenAttribute) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(max(0, 160 - queue.count)).map { ($0, depth + 1) })
            }
        }
        guard let selected, !multiple else { throw ExternalTextSelection.SelectionError.noSelection }
        return (selected, false)
    }
}

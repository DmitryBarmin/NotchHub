import AppKit
import Carbon
import SwiftUI

/// A single-shot shortcut: never registers the clipboard cycling session key.
final class ScreenshotSettings: ObservableObject {
    static let standard = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_9), modifiers: UInt32(cmdKey | shiftKey))
    static let preferenceKey = "screenshotShortcut"
    @Published private(set) var current: ClipboardShortcut
    @Published private(set) var message: String?
    private var handler: EventHandlerRef?
    private var reference: EventHotKeyRef?
    private let action: () -> Void
    private let released: (() -> Void)?
    private var isPressed = false
    private let signature: OSType
    private let preferenceKey: String
    let defaultShortcut: ClipboardShortcut
    private let defaults: UserDefaults
    typealias Registration = (ClipboardShortcut, inout EventHotKeyRef?) -> OSStatus
    private let register: Registration
    init(defaults: UserDefaults = .standard, preferenceKey: String = ScreenshotSettings.preferenceKey,
         standard: ClipboardShortcut = ScreenshotSettings.standard, signature: OSType = 0x4E485353,
         register: Registration? = nil, released: (() -> Void)? = nil, action: @escaping () -> Void) {
        self.defaults = defaults; self.action = action; self.released = released
        self.signature = signature; self.preferenceKey = preferenceKey; self.defaultShortcut = standard
        self.register = register ?? { shortcut, ref in
            RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &ref)
        }
        if let data = defaults.data(forKey: preferenceKey), let saved = try? JSONDecoder().decode(ClipboardShortcut.self, from: data), saved.isValid { current = saved }
        else { current = standard }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr, id.id == 1 else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ScreenshotSettings>.fromOpaque(context).takeUnretainedValue()
            guard id.signature == owner.signature else { return OSStatus(eventNotHandledErr) }
            if GetEventKind(event) == UInt32(kEventHotKeyPressed) { owner.pressed() }
            else { owner.release() }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status == noErr { _ = apply(current) }
        else { message = "Не удалось зарегистрировать скриншотер (\(status))" }
    }
    @discardableResult func apply(_ candidate: ClipboardShortcut) -> Bool {
        guard candidate.isValid else { message = candidate.validationMessage; return false }
        if candidate == current, reference != nil { message = nil; return true }
        var replacement: EventHotKeyRef?
        let result = register(candidate, &replacement)
        guard result == noErr else { message = "\(candidate.label) занято или недоступно. Прежняя клавиша сохранена."; return false }
        if let reference { UnregisterEventHotKey(reference) }
        release()
        reference = replacement; current = candidate; message = nil
        if let data = try? JSONEncoder().encode(candidate) { defaults.set(data, forKey: preferenceKey) }
        return true
    }
    func pressed() {
        guard !isPressed else { return }
        isPressed = true
        action()
    }
    private func release() {
        guard isPressed else { return }
        isPressed = false
        released?()
    }
    deinit { if let reference { UnregisterEventHotKey(reference) }; if let handler { RemoveEventHandler(handler) } }
}

struct ScreenshotShortcutCard: View {
    @ObservedObject var settings: ScreenshotSettings
    @State private var draft: ClipboardShortcut
    let title: String
    let detail: String
    init(settings: ScreenshotSettings, title: String = "Скриншотер", detail: String = "Выдели область → обрежь, нарисуй или распознай текст. Esc — отмена.") {
        self.settings = settings; self.title = title; self.detail = detail; _draft = State(initialValue: settings.current)
    }
    func modifier(_ flag: UInt32) -> Binding<Bool> {
        Binding(get: { draft.modifiers & flag != 0 }, set: { if $0 { draft.modifiers |= flag } else { draft.modifiers &= ~flag } })
    }
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsHeading(title: title, icon: title == "Скриншотер" ? "viewfinder" : "eye")
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                HStack {
                    Text(draft.label).font(.title3.monospaced())
                    Spacer()
                    Toggle("⌘", isOn: modifier(UInt32(cmdKey)))
                    Toggle("⌥", isOn: modifier(UInt32(optionKey)))
                    Toggle("⌃", isOn: modifier(UInt32(controlKey)))
                    Toggle("⇧", isOn: modifier(UInt32(shiftKey)))
                    Picker("Клавиша", selection: $draft.keyCode) {
                        ForEach(ClipboardShortcut.keys, id: \.code) { Text($0.label).tag($0.code) }
                    }.labelsHidden().frame(width: 75)
                }.toggleStyle(.checkbox)
                if let message = settings.message ?? draft.validationMessage { Text(message).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("По умолчанию") { if settings.apply(settings.defaultShortcut) { draft = settings.current } }
                    Spacer()
                    Button("Применить") { _ = settings.apply(draft) }.buttonStyle(.borderedProminent).disabled(!draft.isValid || draft == settings.current)
                }
            }
        }.onChange(of: settings.current) { _, value in draft = value }
    }
}

// Editor shortcuts are local to the capture window and never take keys from other apps.
enum ScreenshotAction: String, CaseIterable, Identifiable {
    case copy, save, undo, selectAll, recognize
    var id: String { rawValue }
    var title: String { switch self {
        case .copy: return "Копировать скриншот"
        case .save: return "Сохранить скриншот"
        case .undo: return "Отменить рисунок"
        case .selectAll: return "Выделить весь экран"
        case .recognize: return "Распознать текст"
    } }
    var standard: ClipboardShortcut {
        let key: Int
        switch self { case .copy:key=kVK_ANSI_C;case .save:key=kVK_ANSI_S;case .undo:key=kVK_ANSI_Z;case .selectAll:key=kVK_ANSI_A;case .recognize:key=kVK_ANSI_T }
        return ClipboardShortcut(keyCode:UInt32(key),modifiers:UInt32(cmdKey))
    }
}
final class EditorShortcutSettings: ObservableObject {
    static let shared=EditorShortcutSettings()
    @Published private(set) var current: [String:ClipboardShortcut]
    @Published var message: String?
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults=defaults
        let saved=defaults.data(forKey:"screenshotEditorShortcuts").flatMap { try? JSONDecoder().decode([String:ClipboardShortcut].self,from:$0) } ?? [:]
        current=Dictionary(uniqueKeysWithValues:ScreenshotAction.allCases.map { action in
            (action.rawValue, saved[action.rawValue]?.isValid == true ? saved[action.rawValue]! : action.standard)
        })
    }
    func shortcut(_ action: ScreenshotAction) -> ClipboardShortcut { current[action.rawValue] ?? action.standard }
    func apply(_ values: [String:ClipboardShortcut]) -> Bool {
        let shortcuts=ScreenshotAction.allCases.map { values[$0.rawValue] ?? $0.standard }
        guard shortcuts.allSatisfy(\.isValid), Set(shortcuts.map { "\($0.keyCode)-\($0.modifiers)" }).count == shortcuts.count else {
            message="Выбери разные сочетания с ⌘, ⌥ или ⌃ для каждой функции";return false
        }
        current=Dictionary(uniqueKeysWithValues:zip(ScreenshotAction.allCases.map(\.rawValue),shortcuts));message=nil
        if let data=try? JSONEncoder().encode(current) { defaults.set(data,forKey:"screenshotEditorShortcuts") };return true
    }
    func action(for event: NSEvent) -> ScreenshotAction? {
        var flags: UInt32=0
        if event.modifierFlags.contains(.command) { flags |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.option) { flags |= UInt32(optionKey) }
        if event.modifierFlags.contains(.control) { flags |= UInt32(controlKey) }
        if event.modifierFlags.contains(.shift) { flags |= UInt32(shiftKey) }
        return ScreenshotAction.allCases.first { shortcut($0).keyCode == UInt32(event.keyCode) && shortcut($0).modifiers == flags }
    }
}
struct EditorShortcutCard: View {
    @ObservedObject var settings=EditorShortcutSettings.shared
    @State private var draft=EditorShortcutSettings.shared.current
    func binding(_ action: ScreenshotAction) -> Binding<ClipboardShortcut> {
        Binding(get:{draft[action.rawValue] ?? action.standard},set:{draft[action.rawValue]=$0})
    }
    func modifier(_ action: ScreenshotAction,_ flag: UInt32) -> Binding<Bool> {
        Binding(get:{binding(action).wrappedValue.modifiers & flag != 0},set:{value in
            var shortcut=binding(action).wrappedValue
            if value { shortcut.modifiers |= flag } else { shortcut.modifiers &= ~flag }
            draft[action.rawValue]=shortcut
        })
    }
    var body: some View {
        SettingsCard {
            VStack(alignment:.leading,spacing:14) {
                SettingsHeading(title:"Клавиши редактора скриншотов",icon:"keyboard")
                Text("Работают только во время захвата. Esc — закрыть, Enter — копировать.").font(.caption).foregroundStyle(.secondary)
                ForEach(ScreenshotAction.allCases) { action in
                    HStack {
                        Text(action.title).font(.caption).frame(maxWidth:.infinity,alignment:.leading)
                        Toggle("⌘",isOn:modifier(action,UInt32(cmdKey)))
                        Toggle("⌥",isOn:modifier(action,UInt32(optionKey)))
                        Toggle("⌃",isOn:modifier(action,UInt32(controlKey)))
                        Toggle("⇧",isOn:modifier(action,UInt32(shiftKey)))
                        Picker(action.title,selection:binding(action).keyCode) {
                            ForEach(ClipboardShortcut.keys,id:\.code) { Text($0.label).tag($0.code) }
                        }.labelsHidden().frame(width:65)
                    }.toggleStyle(.checkbox)
                }
                if let message=settings.message { Text(message).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("По умолчанию") { draft=Dictionary(uniqueKeysWithValues:ScreenshotAction.allCases.map{($0.rawValue,$0.standard)});_ = settings.apply(draft) }
                    Spacer();Button("Применить") { _ = settings.apply(draft) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

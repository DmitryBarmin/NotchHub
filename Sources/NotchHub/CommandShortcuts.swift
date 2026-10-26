import AppKit
import Carbon
import Combine
import SwiftUI

enum HubCommand: String, CaseIterable, Codable, Identifiable {
    case openFavorites, transformText, detachPreview, recognizeImage, recognizeTable, batchCopy, openWorkspaces, openScreenshots, openTimers, share, toggleCapture, generateUUID, correctText
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .openFavorites: return "star"
        case .transformText: return "textformat"
        case .detachPreview: return "eye"
        case .recognizeImage: return "text.viewfinder"
        case .recognizeTable: return "tablecells"
        case .batchCopy: return "square.on.square"
        case .openWorkspaces: return "square.stack.3d.up"
        case .openScreenshots: return "photo.stack"
        case .openTimers: return "timer"
        case .share: return "paperplane"
        case .toggleCapture: return "pause.circle"
        case .generateUUID: return "number.square"
        case .correctText: return "checkmark.seal"
        }
    }
    var feature: HubFeature? {
        switch self {
        case .openFavorites: return .favorites
        case .transformText, .generateUUID, .correctText: return .textTools
        case .detachPreview: return .detachedPreview
        case .recognizeImage, .recognizeTable: return .imageOCR
        case .batchCopy: return .batchActions
        case .openWorkspaces: return .workspaces
        case .openScreenshots: return .screenshotHistory
        case .openTimers: return .multipleTimers
        case .share: return .sharing
        case .toggleCapture: return .privacy
        }
    }
    var title: String {
        switch self {
        case .openFavorites: return "Открыть избранное"
        case .transformText: return "Преобразовать текст"
        case .generateUUID: return "Генератор UUID"
        case .correctText: return "Исправить ошибки"
        case .detachPreview: return "Предпросмотр в челке"
        case .recognizeImage: return "Распознать изображение"
        case .recognizeTable: return "Скриншот → таблица"
        case .batchCopy: return "Копировать выбранное"
        case .openWorkspaces: return "Рабочие наборы"
        case .openScreenshots: return "История скриншотов"
        case .openTimers: return "Таймеры"
        case .share: return "Поделиться"
        case .toggleCapture: return "Пауза / продолжение захвата"
        }
    }
}

final class CommandShortcuts: ObservableObject {
    typealias Registration = (ClipboardShortcut, UInt32, inout EventHotKeyRef?) -> OSStatus
    static let preferenceKey = "commandShortcutsV1"
    private static let signature: OSType = 0x4E48434D
    @Published private(set) var current: [HubCommand: ClipboardShortcut] = [:]
    @Published private(set) var message: String?
    let preferences: HubPreferences
    private let defaults: UserDefaults
    private let action: (HubCommand) -> Void
    private let register: Registration
    private let unregister: (EventHotKeyRef) -> Void
    private var handler: EventHandlerRef?
    private var registrations: [HubCommand: (reference: EventHotKeyRef?, id: UInt32)] = [:]
    private var pressed = Set<UInt32>()
    private var serial: UInt32 = 0
    private var observation: AnyCancellable?

    init(preferences: HubPreferences, defaults: UserDefaults = .standard, register: Registration? = nil,
         unregister: @escaping (EventHotKeyRef) -> Void = { _ = UnregisterEventHotKey($0) }, action: @escaping (HubCommand) -> Void) {
        self.preferences = preferences; self.defaults = defaults; self.action = action; self.unregister = unregister
        self.register = register ?? { shortcut, id, reference in
            RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &reference)
        }
        if let data = defaults.data(forKey: Self.preferenceKey), let saved = try? JSONDecoder().decode([String: ClipboardShortcut].self, from: data) {
            for command in HubCommand.allCases {
                if let shortcut = saved[command.rawValue], shortcut.isValid, !current.values.contains(shortcut) { current[command] = shortcut }
            }
        }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        let result = InstallEventHandler(GetApplicationEventTarget(), { _, event, pointer in
            guard let event, let pointer else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == CommandShortcuts.signature else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<CommandShortcuts>.fromOpaque(pointer).takeUnretainedValue()
            return owner.handle(id: id.id, released: GetEventKind(event) == UInt32(kEventHotKeyReleased)) ? noErr : OSStatus(eventNotHandledErr)
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &handler)
        if result == noErr { synchronize() } else { message = "Не удалось включить сочетания клавиш (\(result))" }
        observation = preferences.$current.dropFirst().sink { [weak self] value in self?.synchronize(enabled: value.enabled) }
    }

    private func active(_ command: HubCommand, enabled: Set<HubFeature>) -> Bool { command.feature.map { enabled.contains($0) } ?? true }
    private func remove(_ command: HubCommand) {
        guard let registration = registrations.removeValue(forKey: command) else { return }
        pressed.remove(registration.id)
        if let reference = registration.reference { unregister(reference) }
    }
    private func install(_ shortcut: ClipboardShortcut, for command: HubCommand) -> Bool {
        serial &+= 1
        var reference: EventHotKeyRef?
        let result = register(shortcut, serial, &reference)
        guard result == noErr else { message = "\(shortcut.label) занято или недоступно. Прежняя комбинация сохранена."; return false }
        remove(command)
        registrations[command] = (reference, serial)
        return true
    }
    @discardableResult func apply(_ shortcut: ClipboardShortcut?, for command: HubCommand) -> Bool {
        guard handler != nil else { message = "Обработчик сочетаний клавиш недоступен"; return false }
        if let shortcut {
            guard shortcut.isValid else { message = shortcut.validationMessage; return false }
            guard !current.contains(where: { $0.key != command && $0.value == shortcut }) else { message = "Это сочетание уже назначено другой команде"; return false }
            if active(command, enabled: preferences.current.enabled) {
                if current[command] != shortcut || registrations[command] == nil {
                    guard install(shortcut, for: command) else { return false }
                }
            } else { remove(command) }
            current[command] = shortcut
        } else {
            remove(command)
            current.removeValue(forKey: command)
        }
        let saved = Dictionary(uniqueKeysWithValues: current.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(saved) { defaults.set(data, forKey: Self.preferenceKey) }
        message = nil
        return true
    }
    func synchronize() { synchronize(enabled: preferences.current.enabled) }
    private func synchronize(enabled: Set<HubFeature>) {
        guard handler != nil else { return }
        var failed = false
        for command in HubCommand.allCases {
            guard active(command, enabled: enabled), let shortcut = current[command] else { remove(command); continue }
            if registrations[command] == nil, !install(shortcut, for: command) { failed = true }
        }
        if !failed { message = nil }
    }
    @discardableResult private func handle(id: UInt32, released: Bool) -> Bool {
        guard let command = registrations.first(where: { $0.value.id == id })?.key else { return false }
        if released { pressed.remove(id); return true }
        guard active(command, enabled: preferences.current.enabled), pressed.insert(id).inserted else { return true }
        action(command)
        return true
    }
    deinit {
        observation?.cancel()
        for registration in registrations.values { if let reference = registration.reference { unregister(reference) } }
        if let handler { RemoveEventHandler(handler) }
    }
}

struct CommandShortcutsView: View {
    @ObservedObject var settings: CommandShortcuts
    @ObservedObject private var preferences: HubPreferences
    init(settings: CommandShortcuts) { self.settings = settings; preferences = settings.preferences }
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsHeading(title: "Команды", icon: "keyboard")
                Text("Комбинации необязательны. Выбери команду и назначь удобные клавиши.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(HubCommand.allCases) { command in
                    if command.feature.map({ preferences.isEnabled($0) }) ?? true {
                        CommandShortcutRow(settings: settings, command: command)
                    }
                }
                if let message = settings.message { Text(message).font(.caption).foregroundStyle(.red) }
            }
        }
    }
}

private struct CommandShortcutRow: View {
    @ObservedObject var settings: CommandShortcuts
    let command: HubCommand
    @State private var draft = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(cmdKey | optionKey | controlKey))
    @State private var editing = false
    private func modifier(_ flag: UInt32) -> Binding<Bool> {
        Binding(get: { draft.modifiers & flag != 0 }, set: { if $0 { draft.modifiers |= flag } else { draft.modifiers &= ~flag } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(command.title, systemImage: command.icon).font(.system(size: 12))
                Spacer()
                Text(settings.current[command]?.label ?? "Не назначено").font(.caption.monospaced()).foregroundStyle(.secondary)
                Button(editing ? "Скрыть" : "Изменить") {
                    if !editing { draft = settings.current[command] ?? draft }
                    editing.toggle()
                }.controlSize(.small)
            }
            if command == .correctText {
                Text("Выдели текст → сочетание → исправлено на месте · словарь macOS")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if editing {
                HStack {
                    Toggle("⌘", isOn: modifier(UInt32(cmdKey)))
                    Toggle("⌥", isOn: modifier(UInt32(optionKey)))
                    Toggle("⌃", isOn: modifier(UInt32(controlKey)))
                    Toggle("⇧", isOn: modifier(UInt32(shiftKey)))
                    Picker("Клавиша", selection: $draft.keyCode) {
                        ForEach(ClipboardShortcut.keys, id: \.code) { Text($0.label).tag($0.code) }
                    }.labelsHidden().frame(width: 80)
                }.toggleStyle(.checkbox)
                HStack {
                    Button("Убрать") { if settings.apply(nil, for: command) { editing = false } }
                    Spacer()
                    Button("Применить") { if settings.apply(draft, for: command) { editing = false } }.disabled(!draft.isValid)
                }.controlSize(.small)
            }
        }
    }
}

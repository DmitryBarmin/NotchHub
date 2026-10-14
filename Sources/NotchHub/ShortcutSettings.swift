import AppKit
import Carbon
import SwiftUI

struct ClipboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    static let standard = ClipboardShortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | optionKey))
    static let preferenceKey = "clipboardShortcut"
    static let keys: [(code: UInt32, label: String)] = [
        (kVK_ANSI_A, "A"), (kVK_ANSI_B, "B"), (kVK_ANSI_C, "C"), (kVK_ANSI_D, "D"),
        (kVK_ANSI_E, "E"), (kVK_ANSI_F, "F"), (kVK_ANSI_G, "G"), (kVK_ANSI_H, "H"),
        (kVK_ANSI_I, "I"), (kVK_ANSI_J, "J"), (kVK_ANSI_K, "K"), (kVK_ANSI_L, "L"),
        (kVK_ANSI_M, "M"), (kVK_ANSI_N, "N"), (kVK_ANSI_O, "O"), (kVK_ANSI_P, "P"),
        (kVK_ANSI_Q, "Q"), (kVK_ANSI_R, "R"), (kVK_ANSI_S, "S"), (kVK_ANSI_T, "T"),
        (kVK_ANSI_U, "U"), (kVK_ANSI_V, "V"), (kVK_ANSI_W, "W"), (kVK_ANSI_X, "X"),
        (kVK_ANSI_Y, "Y"), (kVK_ANSI_Z, "Z"), (kVK_ANSI_0, "0"), (kVK_ANSI_1, "1"),
        (kVK_ANSI_2, "2"), (kVK_ANSI_3, "3"), (kVK_ANSI_4, "4"), (kVK_ANSI_5, "5"),
        (kVK_ANSI_6, "6"), (kVK_ANSI_7, "7"), (kVK_ANSI_8, "8"), (kVK_ANSI_9, "9"), (kVK_Space, "Пробел")
    ].map { (UInt32($0.0), $0.1) }
    var isValid: Bool {
        let allowed = UInt32(cmdKey | controlKey | optionKey | shiftKey)
        return Self.keys.contains { $0.code == keyCode } && modifiers & ~allowed == 0 && modifiers & UInt32(cmdKey | controlKey | optionKey) != 0 && !isPasteShortcut
    }
    private var isPasteShortcut: Bool { keyCode == UInt32(kVK_ANSI_V) && modifiers == UInt32(cmdKey) }
    var validationMessage: String? {
        if isPasteShortcut { return "⌘V оставлено для обычной вставки. Добавь ещё модификатор." }
        return isValid ? nil : "Выбери клавишу и хотя бы ⌘, ⌥ или ⌃"
    }
    var primaryModifier: UInt32 {
        if modifiers & UInt32(cmdKey) != 0 { return UInt32(cmdKey) }
        if modifiers & UInt32(controlKey) != 0 { return UInt32(controlKey) }
        return UInt32(optionKey)
    }
    static func symbols(_ modifiers: UInt32) -> String {
        [(UInt32(controlKey), "⌃"), (UInt32(optionKey), "⌥"), (UInt32(shiftKey), "⇧"), (UInt32(cmdKey), "⌘")]
            .filter { modifiers & $0.0 != 0 }.map(\.1).joined()
    }
    var keyLabel: String { Self.keys.first { $0.code == keyCode }?.label ?? "?" }
    var label: String { Self.symbols(modifiers) + keyLabel }
    var primaryLabel: String { Self.symbols(primaryModifier) }
    var instruction: String { "\(label), затем держи \(primaryLabel) и нажимай \(keyLabel)" }
    static func load(from defaults: UserDefaults = .standard) -> ClipboardShortcut {
        guard let data = defaults.data(forKey: preferenceKey), let saved = try? JSONDecoder().decode(Self.self, from: data), saved.isValid else { return standard }
        return saved
    }
    func save(to defaults: UserDefaults) { if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.preferenceKey) } }
}

final class ShortcutSettings: ObservableObject {
    @Published private(set) var current: ClipboardShortcut
    @Published private(set) var message: String?
    private let hotKeys: ClipboardHotKeys
    private let defaults: UserDefaults
    private let changed: (ClipboardShortcut) -> Void
    init(hotKeys: ClipboardHotKeys, defaults: UserDefaults = .standard, changed: @escaping (ClipboardShortcut) -> Void = { _ in }) {
        self.hotKeys = hotKeys; self.defaults = defaults; self.changed = changed; current = hotKeys.shortcut; message = hotKeys.error
    }
    @discardableResult func restoreDefault(draft: inout ClipboardShortcut) -> Bool {
        guard apply(.standard) else { return false }
        draft = current
        return true
    }
    @discardableResult func apply(_ shortcut: ClipboardShortcut) -> Bool {
        guard hotKeys.rebind(to: shortcut) else { message = hotKeys.error; return false }
        shortcut.save(to: defaults); current = shortcut; message = nil; changed(shortcut); return true
    }
}

struct ShortcutSettingsView: View {
    @ObservedObject var settings: ShortcutSettings
    @State private var draft: ClipboardShortcut
    init(settings: ShortcutSettings) { self.settings = settings; _draft = State(initialValue: settings.current) }
    private func modifier(_ flag: UInt32) -> Binding<Bool> {
        Binding(get: { draft.modifiers & flag != 0 }, set: { if $0 { draft.modifiers |= flag } else { draft.modifiers &= ~flag } })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Переключение буфера").font(.headline)
            HStack(spacing: 15) {
                Toggle("⌘", isOn: modifier(UInt32(cmdKey)))
                Toggle("⌥", isOn: modifier(UInt32(optionKey)))
                Toggle("⌃", isOn: modifier(UInt32(controlKey)))
                Toggle("⇧", isOn: modifier(UInt32(shiftKey)))
            }.toggleStyle(.checkbox)
            Picker("Клавиша", selection: $draft.keyCode) {
                ForEach(ClipboardShortcut.keys, id: \.code) { key in Text(key.label).tag(key.code) }
            }.frame(width: 200)
            Text(draft.isValid ? draft.instruction + ". Отпусти \(draft.primaryLabel), чтобы выбрать." : draft.validationMessage ?? "")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message = settings.message { Text(message).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("По умолчанию") { settings.restoreDefault(draft: &draft) }
                Spacer()
                Button("Применить") { settings.apply(draft) }.disabled(!draft.isValid || draft == settings.current)
            }
        }.padding(24).frame(width: 380)
        .onChange(of: settings.current) { _, value in draft = value }
    }
}

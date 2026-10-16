import SwiftUI

struct FeatureSettingsView: View {
    @ObservedObject var preferences: HubPreferences
    var body: some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 14) {
                SettingsHeading(title: "Возможности", icon: "switch.2")
                Text("Выключенные возможности скрываются вместе со своими сочетаниями клавиш.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(HubFeature.allCases) { feature in
                    Toggle(isOn: Binding(get: { preferences.isEnabled(feature) }, set: { preferences.setFeature(feature, enabled: $0) })) {
                        HStack(spacing: 10) {
                            Image(systemName: feature.icon).frame(width: 22).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(feature.title).font(.system(size: 13, weight: .medium))
                                Text(feature.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 16)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.toggleStyle(.switch)
                }
            }
        }
    }
}

struct StoragePrivacySettingsView: View {
    @ObservedObject var preferences: HubPreferences
    @State private var excludedApps = ""
    @State private var draft = HubPreferencesValue.defaults
    @State private var saved = false
    private func value<T>(_ keyPath: WritableKeyPath<HubPreferencesValue, T>) -> Binding<T> {
        Binding(get: { draft[keyPath: keyPath] }, set: { newValue in draft[keyPath: keyPath] = newValue; saved = false })
    }
    var body: some View {
        VStack(spacing: 16) {
            SettingsCard {
                VStack(alignment: .leading, spacing: 14) {
                    SettingsHeading(title: "Хранение истории", icon: "externaldrive")
                    Picker("Элементов в истории", selection: value(\.historyLimit)) {
                        ForEach([20, 50, 100], id: \.self) { Text("\($0)").tag($0) }
                    }
                    HStack {
                        Text("Буфер, полка и избранное")
                        Spacer()
                        Text("\(draft.diskLimitMB) МБ").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(get: { Double(draft.diskLimitMB) }, set: { draft.diskLimitMB = Int($0); saved = false }), in: 50...2000, step: 50)
                    Picker("Удалять через", selection: value(\.expiryHours)) {
                        Text("Никогда").tag(0)
                        Text("1 час").tag(1)
                        Text("1 день").tag(24)
                        Text("1 неделю").tag(168)
                    }
                    Text("Уменьшение лимита или срока удалит старые элементы обычной истории. Избранное, полка и шаблоны сохраняются. История скриншотов имеет отдельный лимит: 20 фрагментов / 200 МБ.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if preferences.isEnabled(.privacy) {
                SettingsCard {
                    VStack(alignment: .leading, spacing: 12) {
                        SettingsHeading(title: "Исключённые приложения", icon: "hand.raised")
                        Text("Буфер из этих приложений не сохраняется. По одному bundle ID на строку.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextEditor(text: $excludedApps)
                            .font(.system(size: 12, design: .monospaced)).frame(minHeight: 90)
                            .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                            .onChange(of: excludedApps) { _, text in draft.excludedAppIDs = text.components(separatedBy: .newlines); saved = false }
                        Text("Например: com.apple.keychainaccess · com.1password.1password")
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                }
            }
            HStack { Text(saved ? "Настройки сохранены" : "Изменения применятся после сохранения").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Применить") {
                preferences.update { current in
                    current.historyLimit = draft.historyLimit; current.diskLimitMB = draft.diskLimitMB
                    current.expiryHours = draft.expiryHours; current.excludedAppIDs = draft.excludedAppIDs
                }
                saved = true
            }.buttonStyle(.borderedProminent) }
        }.onAppear { draft = preferences.current; excludedApps = draft.excludedAppIDs.joined(separator: "\n") }
    }
}

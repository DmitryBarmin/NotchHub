import Foundation
import Combine

enum HubFeature: String, CaseIterable, Codable, Identifiable {
    case favorites, textTools, detachedPreview, imageOCR, batchActions, privacy, workspaces, screenshotHistory, multipleTimers, sharing
    var id: String { rawValue }
    var title: String {
        switch self {
        case .favorites: return "Избранное"
        case .textTools: return "Работа с текстом"
        case .detachedPreview: return "Предпросмотр в челке"
        case .imageOCR: return "Текст с изображения"
        case .batchActions: return "Несколько элементов"
        case .privacy: return "Приватность"
        case .workspaces: return "Рабочие наборы"
        case .screenshotHistory: return "История скриншотов"
        case .multipleTimers: return "Несколько таймеров"
        case .sharing: return "Передача и QR"
        }
    }
    var icon: String {
        switch self {
        case .favorites: return "star"
        case .textTools: return "textformat"
        case .detachedPreview: return "macwindow.on.rectangle"
        case .imageOCR: return "text.viewfinder"
        case .batchActions: return "checkmark.circle"
        case .privacy: return "hand.raised"
        case .workspaces: return "square.stack.3d.up"
        case .screenshotHistory: return "photo.stack"
        case .multipleTimers: return "timer"
        case .sharing: return "square.and.arrow.up"
        }
    }
    var detail: String {
        switch self {
        case .favorites: return "Закрепляй нужные элементы в истории"
        case .textTools: return "Меняй регистр, раскладку и формат текста, создавай UUID"
        case .detachedPreview: return "Открывай содержимое в расширенной панели челки"
        case .imageOCR: return "Распознавай текст локально на Mac"
        case .batchActions: return "Выбирай и копируй несколько элементов"
        case .privacy: return "Приостанавливай захват и исключай приложения"
        case .workspaces: return "Сохраняй наборы заметок и файлов"
        case .screenshotHistory: return "Возвращайся к сохранённым снимкам"
        case .multipleTimers: return "Запускай отдельные таймеры для задач"
        case .sharing: return "Передавай буфер ссылкой или через AirDrop, создавай QR"
        }
    }
}

struct HubPreferencesValue: Codable, Equatable {
    var enabled: Set<HubFeature> = Set(HubFeature.allCases)
    var historyLimit = 20
    var diskLimitMB = 500
    var expiryHours = 0
    var excludedAppIDs: [String] = []
    static let defaults = HubPreferencesValue()

    mutating func normalize() {
        if ![20, 50, 100].contains(historyLimit) { historyLimit = 20 }
        diskLimitMB = max(50, min(2000, diskLimitMB))
        if ![0, 1, 24, 168].contains(expiryHours) { expiryHours = 0 }
        var seen = Set<String>()
        excludedAppIDs = excludedAppIDs.compactMap {
            let value = $0.trimmingCharacters(in: .whitespacesAndNewlines)
            return !value.isEmpty && seen.insert(value).inserted ? value : nil
        }
    }
}

final class HubPreferences: ObservableObject {
    static let preferenceKey = "hubPreferencesV1"
    @Published private(set) var current: HubPreferencesValue
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var value = defaults.data(forKey: Self.preferenceKey).flatMap { try? JSONDecoder().decode(HubPreferencesValue.self, from: $0) } ?? .defaults
        value.normalize()
        current = value
    }
    func isEnabled(_ feature: HubFeature) -> Bool { current.enabled.contains(feature) }
    func setFeature(_ feature: HubFeature, enabled: Bool) {
        update { value in
            if enabled { value.enabled.insert(feature) } else { value.enabled.remove(feature) }
        }
    }
    func update(_ mutate: (inout HubPreferencesValue) -> Void) {
        var value = current
        mutate(&value)
        value.normalize()
        guard value != current else { return }
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: Self.preferenceKey)
        current = value
    }
}

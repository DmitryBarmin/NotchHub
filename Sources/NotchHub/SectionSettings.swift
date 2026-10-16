import Foundation
import SwiftUI

enum HubSection: Int, CaseIterable, Identifiable {
    case clipboard, shelf, note, timer
    var id: Int { rawValue }
    var icon: String {
        switch self {
        case .clipboard: return "doc.on.clipboard"
        case .shelf: return "tray"
        case .note: return "square.and.pencil"
        case .timer: return "timer"
        }
    }
    var detail: String {
        switch self {
        case .clipboard: return "История текста и изображений"
        case .shelf: return "Файлы и материалы под рукой"
        case .note: return "Быстрые заметки"
        case .timer: return "Фокус и короткие перерывы"
        }
    }
    var title: String {
        switch self {
        case .clipboard: return "Буфер обмена"
        case .shelf: return "Полка"
        case .note: return "Заметка"
        case .timer: return "Таймер"
        }
    }
}

struct SectionVisibility: Equatable {
    var mask: Int = 15
    var showScreenshotButton = true
    var pinnedCommands: Set<HubCommand> = []
    static let screenshotButtonKey = "showScreenshotButton"
    static let pinnedCommandsKey = "pinnedHubCommands"
    static let all = SectionVisibility()
    static let preferenceKey = "visibleHubSections"
    var firstVisible: HubSection? { HubSection.allCases.first { isEnabled($0) } }
    var isEmpty: Bool { firstVisible == nil }
    func isEnabled(_ section: HubSection) -> Bool { mask & (1 << section.rawValue) != 0 }
    func isEnabled(tab: Int) -> Bool { HubSection(rawValue: tab).map(isEnabled) ?? false }
    func visibleCommands(enabledFeatures: Set<HubFeature>) -> [HubCommand] {
        HubCommand.allCases.filter { command in
            pinnedCommands.contains(command) && (command.feature.map(enabledFeatures.contains) ?? true)
        }
    }
    static func load(from defaults: UserDefaults) -> SectionVisibility {
        let mask = defaults.object(forKey: preferenceKey) as? Int
        return SectionVisibility(mask: mask.map { (0...15).contains($0) ? $0 : 15 } ?? 15,
                                 showScreenshotButton: defaults.object(forKey: screenshotButtonKey) as? Bool ?? true,
                                 pinnedCommands: Set((defaults.stringArray(forKey: pinnedCommandsKey) ?? []).compactMap(HubCommand.init(rawValue:))))
    }
}

final class SectionSettings: ObservableObject {
    @Published private(set) var current: SectionVisibility
    private let defaults: UserDefaults
    private let changed: (SectionVisibility) -> Void
    init(defaults: UserDefaults = .standard, changed: @escaping (SectionVisibility) -> Void = { _ in }) {
        self.defaults = defaults; self.changed = changed; current = SectionVisibility.load(from: defaults)
    }
    func setScreenshotButton(enabled: Bool) {
        guard current.showScreenshotButton != enabled else { return }
        current.showScreenshotButton = enabled
        defaults.set(enabled, forKey: SectionVisibility.screenshotButtonKey)
        changed(current)
    }
    func setCommand(_ command: HubCommand, enabled: Bool) {
        var updated = current
        if enabled { updated.pinnedCommands.insert(command) }
        else { updated.pinnedCommands.remove(command) }
        guard updated != current else { return }
        current = updated
        defaults.set(updated.pinnedCommands.map(\.rawValue).sorted(), forKey: SectionVisibility.pinnedCommandsKey)
        changed(updated)
    }
    func set(_ section: HubSection, enabled: Bool) {
        var updated = current
        if enabled { updated.mask |= 1 << section.rawValue } else { updated.mask &= ~(1 << section.rawValue) }
        guard updated != current else { return }
        current = updated; defaults.set(updated.mask, forKey: SectionVisibility.preferenceKey); changed(updated)
    }
}

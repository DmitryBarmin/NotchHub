import AppKit
import SwiftUI

struct HubLayoutPreferences: Codable, Equatable {
    var panelWidth: Double = 345
    var panelHeight: Double = 0 // Automatic preserves the original per-screen height.
    var previewWidth: Double = 680
    var previewHeight: Double = 0
    var panelOpacity: Double = 1
    var previewOpacity: Double = 1
    var islandWidth: Double = 0
    var islandHeight: Double = 0
    var verticalOffset: Double = 0
    static let preferenceKey = "hubLayout"
    static let standard = HubLayoutPreferences()
    func normalized() -> Self {
        var value = self
        func bound(_ number: Double, _ range: ClosedRange<Double>, fallback: Double, automatic: Bool = false) -> Double {
            guard number.isFinite else { return fallback }
            if automatic && number == 0 { return 0 }
            return min(range.upperBound, max(range.lowerBound, number))
        }
        value.panelWidth = bound(panelWidth, 240...720, fallback: 345)
        value.panelHeight = bound(panelHeight, 110...600, fallback: 0, automatic: true)
        value.previewWidth = bound(previewWidth, 240...1200, fallback: 680)
        value.previewHeight = bound(previewHeight, 180...900, fallback: 0, automatic: true)
        value.panelOpacity = bound(panelOpacity, 0.2...1, fallback: 1)
        value.previewOpacity = bound(previewOpacity, 0.2...1, fallback: 1)
        value.islandWidth = bound(islandWidth, 80...400, fallback: 0, automatic: true)
        value.islandHeight = bound(islandHeight, 10...100, fallback: 0, automatic: true)
        value.verticalOffset = bound(verticalOffset, -40...120, fallback: 0)
        return value
    }
    static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: preferenceKey), let saved = try? JSONDecoder().decode(Self.self, from: data) else { return .standard }
        return saved.normalized()
    }
}

struct HubGeometry {
    let hasNotch: Bool
    let notchHeight: CGFloat
    let panelWidth: CGFloat
    let panelHeight: CGFloat
    let previewWidth: CGFloat
    let previewHeight: CGFloat
    let islandWidth: CGFloat
    let islandHeight: CGFloat
    let topOffset: CGFloat
    let triggerWidth: CGFloat
    static func resolve(_ preferences: HubLayoutPreferences, screen: CGRect, safeTop: CGFloat, notchWidth: CGFloat?) -> Self {
        let preferences = preferences.normalized(), hasNotch = safeTop > 0
        let maxWidth = max(1, screen.width - 40), maxHeight = max(1, screen.height - 40)
        let notchHeight = min(maxHeight, max(24, safeTop))
        let hardwareWidth = hasNotch ? min(maxWidth, max(1, notchWidth ?? 179)) : 0
        let topOffset = min(max(0, CGFloat(preferences.verticalOffset) + (hasNotch ? 0 : 6)), max(0, maxHeight - notchHeight - 70))
        let availableHeight = max(1, maxHeight - topOffset)
        func width(_ wanted: Double, minimum: CGFloat = 1) -> CGFloat { min(maxWidth, max(minimum, CGFloat(wanted))) }
        func height(_ wanted: Double, minimum: CGFloat = 1) -> CGFloat { min(availableHeight, max(minimum, CGFloat(wanted))) }
        let defaultPanelHeight = (notchHeight + 300) / 2
        // Header controls sit beside the camera cutout, not behind it.
        let minimumPanelWidth = hasNotch ? hardwareWidth + 164 : 1
        let islandWidth = width(preferences.islandWidth == 0 ? (hasNotch ? hardwareWidth : 104) : preferences.islandWidth, minimum: hardwareWidth)
        return Self(hasNotch: hasNotch, notchHeight: notchHeight,
                    panelWidth: width(preferences.panelWidth, minimum: minimumPanelWidth),
                    panelHeight: height(preferences.panelHeight == 0 ? defaultPanelHeight : preferences.panelHeight, minimum: notchHeight + 70),
                    previewWidth: width(preferences.previewWidth, minimum: minimumPanelWidth),
                    previewHeight: height(preferences.previewHeight == 0 ? notchHeight + 400 : preferences.previewHeight, minimum: notchHeight + 100),
                    islandWidth: islandWidth,
                    islandHeight: height(preferences.islandHeight == 0 ? (hasNotch ? notchHeight + 1 : 16) : preferences.islandHeight, minimum: hasNotch ? notchHeight + 1 : 1),
                    topOffset: topOffset, triggerWidth: max(1, min(islandWidth, hasNotch ? hardwareWidth : 104) - 2))
    }
    static func resolve(_ preferences: HubLayoutPreferences, screen: NSScreen) -> Self {
        let notchWidth: CGFloat?
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea { notchWidth = right.minX - left.maxX + 2 }
        else { notchWidth = nil }
        return resolve(preferences, screen: screen.frame, safeTop: screen.safeAreaInsets.top, notchWidth: notchWidth)
    }
    func frame(screen: CGRect, width: CGFloat, height: CGFloat) -> CGRect {
        CGRect(x: screen.midX - width / 2, y: screen.maxY - height - topOffset, width: width, height: height)
    }
}

final class LayoutSettings: ObservableObject {
    @Published private(set) var current: HubLayoutPreferences
    private let defaults: UserDefaults
    private let changed: (HubLayoutPreferences) -> Void
    init(defaults: UserDefaults = .standard, changed: @escaping (HubLayoutPreferences) -> Void = { _ in }) {
        self.defaults = defaults; self.changed = changed; current = HubLayoutPreferences.load(from: defaults)
    }
    func set(_ key: WritableKeyPath<HubLayoutPreferences, Double>, to value: Double) {
        var updated = current; updated[keyPath: key] = value; apply(updated)
    }
    func reset() { apply(.standard) }
    private func apply(_ preferences: HubLayoutPreferences) {
        let value = preferences.normalized()
        guard value != current else { return }
        current = value
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: HubLayoutPreferences.preferenceKey) }
        changed(value)
    }
}

struct LayoutSettingsView: View {
    @ObservedObject var settings: LayoutSettings
    private var geometry: HubGeometry {
        if let screen = NSScreen.main ?? NSScreen.screens.first { return HubGeometry.resolve(settings.current, screen: screen) }
        return HubGeometry.resolve(settings.current, screen: CGRect(x: 0, y: 0, width: 1440, height: 900), safeTop: 0, notchWidth: nil)
    }
    private func slider(_ title: String, key: WritableKeyPath<HubLayoutPreferences, Double>, range: ClosedRange<Double>, effective: CGFloat, automatic: Bool = false) -> some View {
        let value = settings.current[keyPath: key]
        let displayed = automatic && value == 0 ? Double(effective) : value
        return VStack(spacing: 4) {
            HStack {
                Text(title).font(.system(size: 11))
                Spacer()
                Text(abs(displayed - effective) < 1 ? "\(Int(effective)) pt" : "\(Int(displayed)) → \(Int(effective)) pt").foregroundStyle(.secondary).monospacedDigit()
            }.font(.callout)
            Slider(value: Binding(get: { displayed }, set: { settings.set(key, to: $0.rounded()) }), in: range).accessibilityLabel(title)
        }
    }
    private func opacity(_ key: WritableKeyPath<HubLayoutPreferences, Double>) -> some View {
        VStack(spacing: 4) {
            HStack { Text("Прозрачность").font(.system(size: 11)); Spacer(); Text("\(Int((1 - settings.current[keyPath: key]) * 100))%").monospacedDigit().foregroundStyle(.secondary) }.font(.callout)
            Slider(value: Binding(get: { (1 - settings.current[keyPath: key]) * 100 }, set: { settings.set(key, to: 1 - $0.rounded() / 100) }), in: 0...80).accessibilityLabel("Прозрачность фона")
        }
    }
    private func panelCard(preview: Bool) -> some View {
        SettingsCard {
            VStack(alignment: .leading, spacing: 13) {
                SettingsHeading(title: preview ? "Предпросмотр" : "Окно хаба", icon: preview ? "eye" : "rectangle.topthird.inset.filled")
                slider("Ширина", key: preview ? \.previewWidth : \.panelWidth, range: preview ? 240...1200 : 240...720, effective: preview ? geometry.previewWidth : geometry.panelWidth)
                slider("Высота", key: preview ? \.previewHeight : \.panelHeight, range: preview ? 180...900 : 110...600, effective: preview ? geometry.previewHeight : geometry.panelHeight, automatic: true)
                opacity(preview ? \.previewOpacity : \.panelOpacity)
            }
        }
    }
    var body: some View {
        VStack(spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    panelCard(preview: false).frame(minWidth: 220)
                    panelCard(preview: true).frame(minWidth: 220)
                }
                VStack(spacing: 14) { panelCard(preview: false); panelCard(preview: true) }
            }
            SettingsCard {
                VStack(alignment: .leading, spacing: 13) {
                    SettingsHeading(title: "Островок", icon: "capsule.inset.filled")
                    HStack(alignment: .top, spacing: 20) {
                        slider("Ширина", key: \.islandWidth, range: 80...400, effective: geometry.islandWidth, automatic: true)
                        slider("Высота", key: \.islandHeight, range: 10...100, effective: geometry.islandHeight, automatic: true)
                    }
                    slider("Смещение вниз", key: \.verticalOffset, range: -40...120, effective: geometry.topOffset)
                }
            }
            HStack(alignment: .top, spacing: 16) {
                Text("Размеры учитывают экран и физическую чёлку. Стрелка показывает фактическое значение. Текст остаётся непрозрачным.")
                    .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Сбросить") { settings.reset() }.buttonStyle(.borderless).font(.system(size: 11))
            }.padding(.horizontal, 3)
        }
    }
}

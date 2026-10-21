import AppKit
import Combine

struct HubTimer: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var duration: TimeInterval
    var remaining: TimeInterval
    var deadline: Date?
    var completed = false
    var running: Bool { deadline != nil }
    var label: String { let seconds = Int(ceil(max(0, remaining))); return String(format: "%02d:%02d", seconds / 60, seconds % 60) }
}

final class TimerLibrary: ObservableObject {
    static let preferenceKey = "hubTimerLibraryV1"
    @Published private(set) var timers: [HubTimer]
    @Published private(set) var focusedTaskID: UUID?
    static let focusedTaskKey = "hubFocusedTaskV1"
    private let defaults: UserDefaults
    private var timer: Timer?
    var current: HubTimer? { timers.first(where: \.running) ?? timers.first }
    var hasScheduledTick: Bool { timer?.isValid == true }
    init(defaults: UserDefaults = .standard, now: Date = Date()) {
        self.defaults = defaults
        timers = defaults.data(forKey: Self.preferenceKey).flatMap { try? JSONDecoder().decode([HubTimer].self, from: $0) } ?? []
        timers = timers.filter { $0.duration.isFinite && $0.duration > 0 && $0.remaining.isFinite }
        focusedTaskID = defaults.string(forKey: Self.focusedTaskKey).flatMap(UUID.init(uuidString:))
        if !timers.contains(where: { $0.id == focusedTaskID }) { focusedTaskID = nil }
        tick(now: now)
        schedule()
    }
    deinit { timer?.invalidate() }
    @discardableResult func add(title: String, minutes: Int) -> UUID {
        let duration = TimeInterval(max(1, min(10080, minutes))) * 60
        let item = HubTimer(title: title.isEmpty ? "Таймер" : title, duration: duration, remaining: duration)
        timers.append(item); persist(); return item.id
    }
    func start(id: UUID, now: Date = Date()) {
        guard let index = timers.firstIndex(where: { $0.id == id }), timers[index].remaining > 0 else { return }
        timers[index].completed = false
        timers[index].deadline = now.addingTimeInterval(timers[index].remaining)
        persist(); schedule()
    }
    func pause(id: UUID, now: Date = Date()) {
        tick(now: now)
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[index].deadline = nil; persist(); schedule()
    }
    func reset(id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[index].remaining = timers[index].duration; timers[index].deadline = nil; timers[index].completed = false
        persist(); schedule()
    }
    func focus(id: UUID?) {
        guard id == nil || timers.contains(where: { $0.id == id }) else { return }
        focusedTaskID = id
        if let id { defaults.set(id.uuidString, forKey: Self.focusedTaskKey) }
        else { defaults.removeObject(forKey: Self.focusedTaskKey) }
    }
    func finish(id: UUID) {
        guard let index = timers.firstIndex(where: { $0.id == id }) else { return }
        timers[index].remaining = 0; timers[index].deadline = nil; timers[index].completed = true
        persist(); schedule()
    }
    func remove(id: UUID) {
        timers.removeAll { $0.id == id }
        if focusedTaskID == id { focus(id: nil) }
        persist(); schedule()
    }
    func tick(now: Date = Date()) {
        var completed = false
        var updated = timers
        for index in updated.indices {
            guard let deadline = updated[index].deadline else { continue }
            updated[index].remaining = max(0, deadline.timeIntervalSince(now))
            if updated[index].remaining == 0 {
                updated[index].completed = true; updated[index].deadline = nil; completed = true
            }
        }
        if updated != timers { timers = updated }
        if completed { persist(); NSSound(named: "Glass")?.play() }
        if !timers.contains(where: \.running) { timer?.invalidate(); timer = nil }
    }
    func pauseAll(now: Date = Date()) {
        tick(now: now)
        for index in timers.indices { timers[index].deadline = nil }
        persist(); schedule()
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(timers) { defaults.set(data, forKey: Self.preferenceKey) }
    }
    private func schedule() {
        guard timers.contains(where: \.running) else { timer?.invalidate(); timer = nil; return }
        guard !hasScheduledTick else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        timer?.tolerance = 0.15
    }
}

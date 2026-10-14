import AppKit
import Carbon

struct ClipboardCycle {
    private var ids: [UUID] = []
    private var index = 0
    var selectedID: UUID? { ids.isEmpty ? nil : ids[index] }
    mutating func begin(ids: [UUID]) { self.ids = ids; index = 0 }
    mutating func advance() { if !ids.isEmpty { index = (index + 1) % ids.count } }
    mutating func finish() -> UUID? {
        let selected = selectedID
        ids = []
        index = 0
        return selected
    }
}

final class ClipboardHotKeys {
    private var handler: EventHandlerRef?
    private var initialKey: EventHotKeyRef?
    private var sessionKey: EventHotKeyRef?
    private var releaseTimer: Timer?
    private let advance: () -> Void
    private let finish: () -> Void
    private let modifiers: () -> UInt32
    private(set) var error: String?
    private let signature: OSType = 0x4E484342
    init(advance: @escaping () -> Void, finish: @escaping () -> Void, modifiers: @escaping () -> UInt32 = { GetCurrentKeyModifiers() }) {
        self.advance = advance
        self.finish = finish
        self.modifiers = modifiers
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr else { return OSStatus(eventNotHandledErr) }
            let owner = Unmanaged<ClipboardHotKeys>.fromOpaque(context).takeUnretainedValue()
            guard id.signature == owner.signature else { return OSStatus(eventNotHandledErr) }
            owner.pressed()
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { error = "Не удалось включить горячую клавишу (\(installed))"; return }
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey | optionKey), EventHotKeyID(signature: signature, id: 1), GetApplicationEventTarget(), 0, &initialKey)
        if result != noErr { error = "⌘⌥V занято другим приложением (\(result))" }
    }
    private func pressed() {
        if releaseTimer == nil {
            let result = RegisterEventHotKey(UInt32(kVK_ANSI_V), UInt32(cmdKey), EventHotKeyID(signature: signature, id: 2), GetApplicationEventTarget(), 0, &sessionKey)
            if result != noErr { error = "Повторяй ⌘⌥V: ⌘V недоступно (\(result))" }
            releaseTimer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                guard let self, (self.modifiers() & UInt32(cmdKey)) == 0 else { return }
                self.cancelSession()
                self.finish()
            }
            RunLoop.main.add(releaseTimer!, forMode: .common)
        }
        advance()
    }
    func cancelSession() {
        releaseTimer?.invalidate()
        releaseTimer = nil
        if let sessionKey { UnregisterEventHotKey(sessionKey) }
        sessionKey = nil
    }
    deinit {
        cancelSession()
        if let initialKey { UnregisterEventHotKey(initialKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

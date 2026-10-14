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
    var sessionActive: Bool { releaseTimer != nil }
    private let signature: OSType = 0x4E484342
    private(set) var shortcut: ClipboardShortcut
    typealias Registration = (ClipboardShortcut, UInt32, inout EventHotKeyRef?) -> OSStatus
    private let register: Registration
    static func registerNative(_ shortcut: ClipboardShortcut, id: UInt32, reference: inout EventHotKeyRef?) -> OSStatus {
        RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, EventHotKeyID(signature: 0x4E484342, id: id), GetApplicationEventTarget(), 0, &reference)
    }
    init(advance: @escaping () -> Void, finish: @escaping () -> Void, shortcut: ClipboardShortcut = .standard, register: @escaping Registration = ClipboardHotKeys.registerNative, modifiers: @escaping () -> UInt32 = { GetCurrentKeyModifiers() }) {
        self.advance = advance
        self.finish = finish
        self.modifiers = modifiers
        self.shortcut = shortcut.isValid ? shortcut : .standard
        self.register = register
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
        let result = register(self.shortcut, 1, &initialKey)
        if result != noErr { error = "\(self.shortcut.label) занято или недоступно (\(result))" }
    }
    @discardableResult func rebind(to candidate: ClipboardShortcut) -> Bool {
        guard candidate.isValid else { error = candidate.validationMessage; return false }
        if candidate == shortcut && initialKey != nil { error = nil; return true }
        var replacement: EventHotKeyRef?
        let result = register(candidate, 1, &replacement)
        guard result == noErr else { error = "\(candidate.label) занято или недоступно (\(result)). Прежняя комбинация сохранена."; return false }
        cancelSession()
        if let initialKey { UnregisterEventHotKey(initialKey) }
        initialKey = replacement; shortcut = candidate; error = nil
        return true
    }
    func pressed() {
        if releaseTimer == nil {
            error = nil
            if shortcut.modifiers != shortcut.primaryModifier {
                let sessionShortcut = ClipboardShortcut(keyCode: shortcut.keyCode, modifiers: shortcut.primaryModifier)
                let result = register(sessionShortcut, 2, &sessionKey)
                if result != noErr { error = "Повторяй \(shortcut.label): \(sessionShortcut.label) недоступно (\(result))" }
            }
            releaseTimer = Timer(timeInterval: 0.025, repeats: true) { [weak self] _ in
                guard let self, (self.modifiers() & self.shortcut.primaryModifier) == 0 else { return }
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

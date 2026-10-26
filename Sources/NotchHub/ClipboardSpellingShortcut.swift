import AppKit
import ApplicationServices

/// The hotkey follows the current app, without requiring its Accessibility text/range APIs.
struct SpellingSelectionTarget {
    let processIdentifier: pid_t
    let validate: () throws -> Void

    @MainActor static func capture() throws -> SpellingSelectionTarget {
        guard let application = NSWorkspace.shared.frontmostApplication,
              !application.isTerminated else { throw ExternalTextSelection.SelectionError.noSelection }
        let focused = try optionalFocusedElement(in: application)
        return SpellingSelectionTarget(processIdentifier: application.processIdentifier, validate: {
            guard !application.isTerminated,
                  let current = NSRunningApplication(processIdentifier: application.processIdentifier),
                  current.launchDate == application.launchDate,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier else {
                throw ExternalTextSelection.SelectionError.selectionChanged
            }
            let nowFocused = try optionalFocusedElement(in: application)
            if let focused {
                guard let nowFocused, CFEqual(focused, nowFocused) else { throw ExternalTextSelection.SelectionError.selectionChanged }
            }
        })
    }
    /// Accessibility is optional; when available it supplies focus and secure-field safety only.
    @MainActor private static func optionalFocusedElement(in application: NSRunningApplication) throws -> AXUIElement? {
        guard AXIsProcessTrusted() else { return nil }
        do { return try SelectionAccessibility.focusedElement(in: application).element }
        catch ExternalTextSelection.SelectionError.protectedField { throw ExternalTextSelection.SelectionError.protectedField }
        catch { return nil }
    }
}

/// One native copy → local correction → paste → clipboard restoration transaction.
@MainActor final class ClipboardSpellingShortcut {
    typealias Cycle = (pid_t, @escaping () throws -> Void, @escaping (String) async throws -> LocalSpellingOutcome, @escaping (Int) -> Void) async throws -> LocalSpellingOutcome
    private(set) var busy = false
    private let capture: () throws -> SpellingSelectionTarget
    private let correct: (String) async throws -> LocalSpellingOutcome
    private let cycle: Cycle
    private let didRestore: (Int) -> Void
    private let feedback: (String) -> Void
    private var operation: Task<Void, Never>?
    private var generation = UUID()

    init(capture: @escaping () throws -> SpellingSelectionTarget = SpellingSelectionTarget.capture,
         correct: @escaping (String) async throws -> LocalSpellingOutcome = MacSpellingCorrector.correct,
         cycle: Cycle? = nil, didRestore: @escaping (Int) -> Void = { _ in }, feedback: @escaping (String) -> Void) {
        self.capture = capture; self.correct = correct; self.didRestore = didRestore; self.feedback = feedback
        self.cycle = cycle ?? { pid, validate, correct, didRestore in
            try await NativeSelectionPaste.perform(processIdentifier: pid, validate: validate, correct: correct, didRestore: didRestore)
        }
    }
    func trigger() {
        guard !busy else { feedback("Проверка уже выполняется — дождись результата"); return }
        let target: SpellingSelectionTarget
        do { target = try capture(); try target.validate() }
        catch { feedback(error.localizedDescription); return }
        let token = UUID(); generation = token; busy = true
        feedback("Исправляю выделение словарём macOS…")
        operation = Task { [weak self] in
            guard let self else { return }
            // Capture stays suspended until the native transaction has restored or released the clipboard.
            defer { busy = false; operation = nil }
            do {
                let outcome = try await cycle(target.processIdentifier, target.validate, correct, didRestore)
                try Task.checkCancellation()
                guard generation == token else { return }
                if outcome.correctedCount == 0 {
                    feedback(outcome.misspellingCount == 0 ? "Словарь macOS не нашёл явных ошибок. Выделение не изменено." : "Нет однозначных исправлений — выделение оставлено без изменений.")
                } else {
                    feedback(outcome.unresolvedCount > 0
                        ? "Правка отправлена в исходное поле. Неоднозначные слова оставлены без изменений."
                        : "Правка отправлена в исходное поле")
                }
            } catch is CancellationError {
            } catch { if generation == token { feedback("Не удалось исправить выделение: " + error.localizedDescription) } }
        }
    }
    func cancel() {
        generation = UUID(); operation?.cancel()
        // Do not release the monitor while a cancelled paste transaction is still cleaning up.
        if operation == nil { busy = false }
    }
    deinit { operation?.cancel() }
}

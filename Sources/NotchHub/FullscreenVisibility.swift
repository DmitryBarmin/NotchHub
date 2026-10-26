import AppKit

/// Window bounds and layer metadata are available without capturing the screen.
/// Public APIs do not tell us whether an arbitrary fullscreen app is playing video,
/// so the unobtrusive behavior applies to any foreground window filling a display.
enum FullscreenWindowGeometry {
    static func fillsDisplay(_ window: CGRect, display: CGRect, tolerance: CGFloat = 2) -> Bool {
        guard !window.isEmpty, !display.isEmpty else { return false }
        return abs(window.minX - display.minX) <= tolerance
            && abs(window.minY - display.minY) <= tolerance
            && abs(window.maxX - display.maxX) <= tolerance
            && abs(window.maxY - display.maxY) <= tolerance
    }

    static func hasFullscreenWindow(_ windows: [[String: Any]], display: CGRect, ownPID: pid_t) -> Bool {
        for window in windows {
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  pid != ownPID,
                  (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue != 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  frame.intersection(display).width > 2,
                  frame.intersection(display).height > 2 else { continue }
            // The list is front to back. A normal window above a fullscreen window
            // means the latter is no longer the foreground surface on this display.
            return fillsDisplay(frame, display: display)
        }
        return false
    }
}

final class FullscreenVisibilityController {
    private let screen: NSScreen
    private let shouldKeepVisible: () -> Bool
    private let visibilityChanged: (Bool) -> Void
    private var observers: [NSObjectProtocol] = []
    private var presentationObservation: NSKeyValueObservation?
    private var refreshWork: DispatchWorkItem?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var idleTimer: Timer?
    private var fullscreen = false
    private var visible = true
    private var started = false
    private let idleDelay: TimeInterval = 2
    private var lastInteraction: TimeInterval = -.infinity

    init(screen: NSScreen, shouldKeepVisible: @escaping () -> Bool, visibilityChanged: @escaping (Bool) -> Void) {
        self.screen = screen
        self.shouldKeepVisible = shouldKeepVisible
        self.visibilityChanged = visibilityChanged
    }

    func start() {
        guard !started else { return }
        started = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.scheduleRefresh() })
        presentationObservation = NSApp.observe(\.currentSystemPresentationOptions, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.scheduleRefresh() }
        }
        refresh()
    }

    func stop() {
        started = false
        refreshWork?.cancel(); refreshWork = nil
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        presentationObservation = nil
        removeMouseMonitors()
        idleTimer?.invalidate(); idleTimer = nil
    }

    /// Explicit keyboard/command access gets the same grace period as mouse motion.
    func userInteracted() {
        guard started else { return }
        setVisible(true)
        guard fullscreen else { return }
        // Mouse hardware can deliver hundreds of events a second. Resetting the
        // idle deadline ten times a second is enough for a two-second timeout.
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastInteraction >= 0.1 else { return }
        lastInteraction = now
        if let idleTimer { idleTimer.fireDate = Date(timeIntervalSinceNow: idleDelay) }
        else {
            let timer = Timer(timeInterval: idleDelay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.idleTimer = nil
                if self.fullscreen && !self.shouldKeepVisible() { self.setVisible(false) }
            }
            idleTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    func refresh() {
        guard started,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let next = FullscreenWindowGeometry.hasFullscreenWindow(windows, display: CGDisplayBounds(number.uint32Value), ownPID: ProcessInfo.processInfo.processIdentifier)
        guard next != fullscreen else { return }
        fullscreen = next
        if fullscreen {
            let mask: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp]
            globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.userInteracted() }
            localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in self?.userInteracted(); return event }
            setVisible(shouldKeepVisible())
            if visible { userInteracted() }
        } else {
            removeMouseMonitors()
            idleTimer?.invalidate(); idleTimer = nil
            setVisible(true)
        }
    }

    private func scheduleRefresh() {
        guard started else { return }
        refreshWork?.cancel()
        // Let the system's Space transition finish before reading window geometry.
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func setVisible(_ value: Bool) {
        guard visible != value else { return }
        visible = value
        visibilityChanged(value)
    }

    private func removeMouseMonitors() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil; localMouseMonitor = nil
    }

    deinit { stop() }
}

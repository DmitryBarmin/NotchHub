import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

final class HubState: ObservableObject {
    @Published var sections = SectionVisibility.all
    @Published var shortcut = ClipboardShortcut.standard
    @Published var expanded = false
    @Published var pinned = false
    @Published var dialogPresented = false
    @Published var notchHeight: CGFloat = 32
    @Published var collapsedWidth: CGFloat = 179
    @Published var expandedWidth: CGFloat = 345
    @Published var panelHeight: CGFloat = 166
    @Published var panelOpacity: Double = 1
    @Published var previewOpacity: Double = 1
    @Published var collapsedHeight: CGFloat = 33
    @Published var capsuleTask: HubTimer?
    @Published var topOffset: CGFloat = 0
    @Published var triggerWidth: CGFloat = 177
    @Published var previewClip: Clip?
    @Published var previewWidth: CGFloat = 680
    @Published var previewContentHeight: CGFloat = 400
    @Published var surface: HubSurface?
    var closeSurface: (() -> Void)?
    var showSurface: ((HubSurface?) -> Void)?
    var hasPreview: Bool { previewClip != nil || surface != nil }
    var panelWidth: CGFloat { hasPreview ? previewWidth : expandedWidth }
    var expandedHeight: CGFloat { !hasPreview ? (sections.isEmpty ? min(panelHeight, notchHeight + 70) : panelHeight) : notchHeight + previewContentHeight }
    @Published var hasNotch = true
    @Published var tab = 0
    @Published var keyboardSelecting = false
    @Published var selectedClipboardID: UUID?
    @Published var actionClipID: UUID?
    @Published var favoritesOnly = false
    @Published var batchMode = false
    @Published var batchIDs: Set<UUID> = []
    var prepareExternalSelection: (() -> Void)?
    var runCommand: ((HubCommand, Clip?) -> Void)?
    var editWorkspace: ((UUID?) -> Void)?
    var reveal: (() -> Void)?
    var hide: (() -> Void)?
    var showPreview: ((Clip?) -> Void)?
    var openSettings: (() -> Void)?
    var takeScreenshot: (() -> Void)?
    @discardableResult func applySectionVisibility(_ visibility: SectionVisibility) -> Bool {
        sections = visibility
        guard !visibility.isEnabled(tab: tab) else { return false }
        tab = visibility.firstVisible?.rawValue ?? -1
        previewClip = nil; keyboardSelecting = false; selectedClipboardID = nil
        return true
    }
    @discardableResult func beginBatchSelection() -> Bool {
        let target: Int
        if (tab == 0 || tab == 1), sections.isEnabled(tab: tab) { target = tab }
        else if sections.isEnabled(.clipboard) { target = 0 }
        else if sections.isEnabled(.shelf) { target = 1 }
        else { return false }
        if target != tab { favoritesOnly = false }
        showPreview?(nil); previewClip = nil
        tab = target; batchMode = true; batchIDs = []
        return true
    }
    static func atTrigger(_ point: CGPoint, screen: CGRect, notchWidth: CGFloat) -> Bool {
        point.y >= screen.maxY - 1 && point.y <= screen.maxY && abs(point.x - screen.midX) <= notchWidth / 2
    }
    static func insideHub(_ point: CGPoint, panel: CGRect, screen: CGRect, notchWidth: CGFloat, island: CGRect? = nil) -> Bool {
        panel.contains(point) || (island?.contains(point) ?? false) || (point.y >= panel.maxY && point.y <= screen.maxY && abs(point.x - screen.midX) <= notchWidth / 2)
    }
}

final class IslandPanel: NSPanel {
    var beforeInteraction: (() -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown || event.type == .rightMouseDown { beforeInteraction?() }
        super.sendEvent(event)
    }
    override func becomeKey() { beforeInteraction?(); super.becomeKey() }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Receives tracking-area events, which the window server sends only while the
/// pointer is over our windows — unlike a global monitor that wakes on every move.
final class HoverTracker: NSResponder {
    var changed: (() -> Void)?
    var entered: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { entered?(); changed?() }
    override func mouseExited(with event: NSEvent) { changed?() }
    override func mouseMoved(with event: NSEvent) { changed?() }
    func track(_ view: NSView) {
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self))
    }
}

final class PanelController {
    let state: HubState
    let panel: IslandPanel
    private var screen: NSScreen?
    private var fullscreenVisibility: FullscreenVisibilityController?
    private var layout = HubLayoutPreferences.standard
    private var pointerMonitor: Any?
    private var pointerMonitorTracksMoves = false
    private var localPointerMonitor: Any?
    private let tracker = HoverTracker()
    /// Top-edge strip for layouts where the island sits below the screen edge.
    private let edgePanel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    private var escapeMonitor: Any?
    private var triggerArmed = true
    private var hoverCheckPending = false
    private var taskObservation: AnyCancellable?
    private var refreshTask: (() -> Void)?
    private var baseIslandHeight: CGFloat = 33
    init(store: HubStore, clock: FocusClock, state: HubState, screen: NSScreen, layout: HubLayoutPreferences = .standard, timers: TimerLibrary? = nil) {
        self.state = state
        self.screen = screen
        self.layout = layout
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.beforeInteraction = { [weak state] in state?.prepareExternalSelection?() }
        panel.becomesKeyOnlyIfNeeded = true
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar; panel.hidesOnDeactivate = false; panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hosting = NSHostingView(rootView: HubView(store: store, clock: clock, state: state))
        hosting.sizingOptions = []
        panel.contentView = hosting
        if let timers {
            let update: ([HubTimer], UUID?, HubPreferencesValue) -> Void = { [weak self] items, selected, preferences in
                guard let self else { return }
                let task = preferences.enabled.contains(.multipleTimers) && self.state.sections.isEnabled(.timer)
                    ? items.first(where: { $0.id == selected }) : nil
                guard self.state.capsuleTask != task else { return }
                self.state.capsuleTask = task
                self.state.collapsedHeight = self.baseIslandHeight + (task == nil ? 0 : 30)
                self.resize(expanded: self.state.expanded, animate: false)
            }
            taskObservation = timers.$timers.combineLatest(timers.$focusedTaskID, store.preferences.$current).sink { items, selected, preferences in
                update(items, selected, preferences)
            }
            refreshTask = { [weak timers, weak store] in
                guard let timers, let store else { return }
                update(timers.timers, timers.focusedTaskID, store.preferences.current)
            }
        }
        tracker.entered = { [weak state] in state?.prepareExternalSelection?() }
        tracker.changed = { [weak self] in self?.scheduleHoverCheck() }
        tracker.track(hosting)
        edgePanel.isOpaque = false; edgePanel.backgroundColor = .clear; edgePanel.hasShadow = false
        edgePanel.level = .statusBar; edgePanel.hidesOnDeactivate = false; edgePanel.isMovable = false
        edgePanel.collectionBehavior = panel.collectionBehavior
        edgePanel.contentView = NSView()
        tracker.track(edgePanel.contentView!)
        state.reveal = { [weak self] in self?.expand() }
        state.hide = { [weak self] in self?.collapse() }
        state.showPreview = { [weak self] clip in
            guard let self else { return }
            if self.state.surface != nil { self.state.closeSurface?() }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { self.state.previewClip = clip }
            self.resize(expanded: self.state.expanded, animate: false)
        }
        state.showSurface = { [weak self] surface in
            guard let self else { return }
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                self.state.surface = surface
                if surface != nil { self.state.previewClip = nil }
            }
            self.resize(expanded: self.state.expanded, animate: false)
            self.fullscreenVisibility?.userInteracted()
            if surface != nil { self.expand(); self.panel.makeKeyAndOrderFront(nil) }
        }
        position()
        panel.orderFrontRegardless()
        fullscreenVisibility = FullscreenVisibilityController(screen: screen, shouldKeepVisible: { [weak self] in
            guard let self else { return false }
            return self.state.pinned || self.state.keyboardSelecting || self.state.dialogPresented || self.state.surface != nil
                || (self.state.expanded && self.panel.frame.contains(NSEvent.mouseLocation)) || NSEvent.pressedMouseButtons != 0
        }, visibilityChanged: { [weak self] visible in
            guard let self else { return }
            if visible {
                self.panel.orderFrontRegardless()
                if self.state.topOffset > 0 { self.edgePanel.orderFrontRegardless() }
            } else {
                self.panel.orderOut(nil); self.edgePanel.orderOut(nil)
            }
        })
        fullscreenVisibility?.start()
        updatePointerMonitor()
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.pointerEvents) { [weak self] event in
            self?.scheduleHoverCheck(); return event
        }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only Esc aimed at the hub; settings and dialog windows keep their own Esc.
            guard let self, event.keyCode == 53, event.window === self.panel else { return event }
            self.state.pinned = false; self.collapse(); return nil
        }
    }
    private static let pointerEvents: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .leftMouseUp, .rightMouseUp, .otherMouseUp]
    /// Global mouse-move delivery wakes the app on every pointer move system-wide, so it
    /// runs only while expanded; collapsed hover comes from tracking areas. Drags stay
    /// global so dropping a file onto the island still opens it.
    private func updatePointerMonitor() {
        let tracksMoves = state.expanded
        guard pointerMonitor == nil || tracksMoves != pointerMonitorTracksMoves else { return }
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        let mask = tracksMoves ? Self.pointerEvents : Self.pointerEvents.subtracting(.mouseMoved)
        pointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in self?.checkHover() }
        pointerMonitorTracksMoves = tracksMoves
    }
    private func scheduleHoverCheck() {
        // Local events arrive before AppKit updates pressedMouseButtons on release.
        guard !hoverCheckPending else { return }
        hoverCheckPending = true
        DispatchQueue.main.async { [weak self] in
            self?.hoverCheckPending = false
            self?.checkHover()
        }
    }
    func dispose() {
        taskObservation?.cancel(); taskObservation = nil; refreshTask = nil
        fullscreenVisibility?.stop(); fullscreenVisibility = nil
        if state.surface != nil { state.closeSurface?() }
        state.surface = nil; state.showSurface = nil; state.closeSurface = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        pointerMonitor = nil; localPointerMonitor = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        tracker.changed = nil; tracker.entered = nil
        panel.beforeInteraction = nil
        state.prepareExternalSelection = nil
        edgePanel.orderOut(nil)
        panel.orderOut(nil)
        state.reveal = nil
        state.hide = nil
        state.showPreview = nil
        state.openSettings = nil
    }
    func applySectionVisibility(_ visibility: SectionVisibility) {
        let routed = state.applySectionVisibility(visibility)
        refreshTask?()
        if routed && state.surface == nil { state.showPreview?(nil) }
    }
    func contains(_ point: CGPoint) -> Bool { screen?.frame.contains(point) ?? false }
    func applyLayout(_ preferences: HubLayoutPreferences) { layout = preferences; position() }
    func position() {
        guard let screen else { return }
        let geometry = HubGeometry.resolve(layout, screen: screen)
        state.hasNotch = geometry.hasNotch; state.notchHeight = geometry.notchHeight
        state.expandedWidth = geometry.panelWidth; state.panelHeight = geometry.panelHeight
        state.previewWidth = geometry.previewWidth; state.previewContentHeight = max(0, geometry.previewHeight - geometry.notchHeight)
        state.collapsedWidth = geometry.islandWidth
        baseIslandHeight = geometry.islandHeight
        state.collapsedHeight = baseIslandHeight + (state.capsuleTask == nil ? 0 : 30)
        state.topOffset = geometry.topOffset; state.triggerWidth = geometry.triggerWidth
        state.panelOpacity = layout.panelOpacity; state.previewOpacity = layout.previewOpacity
        resize(expanded: state.expanded, animate: false)
        if geometry.topOffset > 0 {
            edgePanel.setFrame(NSRect(x: screen.frame.midX - geometry.triggerWidth / 2, y: screen.frame.maxY - 2, width: geometry.triggerWidth, height: 2), display: false)
            edgePanel.orderFrontRegardless()
        } else { edgePanel.orderOut(nil) }
    }
    private func resize(expanded: Bool, animate: Bool) {
        guard let screen else { return }
        let width: CGFloat = expanded ? state.panelWidth : state.collapsedWidth
        let height: CGFloat = expanded ? state.expandedHeight : state.collapsedHeight
        let frame = NSRect(x: screen.frame.midX - width / 2, y: screen.frame.maxY - height - state.topOffset, width: width, height: height)
        // Keep window geometry and hit area synchronized; animate the SwiftUI surface.
        panel.setFrame(frame, display: true)
    }
    func expand() {
        fullscreenVisibility?.userInteracted()
        guard !state.expanded else { return }
        resize(expanded: true, animate: false)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) { state.expanded = true }
        updatePointerMonitor()
    }
    func collapse() {
        fullscreenVisibility?.userInteracted()
        guard state.expanded else { return }
        if state.surface != nil { state.closeSurface?() }
        withAnimation(.easeOut(duration: 0.12)) { state.expanded = false }
        updatePointerMonitor()
        panel.resignKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.state.expanded else { return }
            self.state.previewClip = nil
            self.resize(expanded: false, animate: false)
        }
    }
    private func checkHover() {
        let point = NSEvent.mouseLocation
        let atEdge = screen.map { HubState.atTrigger(point, screen: $0.frame, notchWidth: state.triggerWidth) } ?? false
        let atIsland = !state.expanded && panel.frame.contains(point)
        let atTrigger = atEdge || atIsland
        if !atTrigger { triggerArmed = true }
        if !state.expanded {
            if atTrigger && triggerArmed { triggerArmed = false; expand() }
            return
        }
        if atEdge { triggerArmed = false }
        let inside = screen.map {
            let island = NSRect(x: $0.frame.midX - state.collapsedWidth / 2, y: $0.frame.maxY - state.collapsedHeight - state.topOffset, width: state.collapsedWidth, height: state.collapsedHeight)
            return HubState.insideHub(point, panel: panel.frame, screen: $0.frame, notchWidth: state.triggerWidth, island: island)
        } ?? panel.frame.contains(point)
        if state.pinned || state.keyboardSelecting || state.dialogPresented || state.surface != nil || inside || NSEvent.pressedMouseButtons != 0 {
            return
        }
        collapse()
    }
}

struct GlassBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow; view.blendingMode = .behindWindow; view.state = .active
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) { }
}

struct IslandGlass: View {
    let notchHeight: CGFloat
    private let shape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 14)
    var body: some View {
        Group {
            if #available(macOS 26.0, *) {
                GlassBackground().overlay(Color.black.opacity(0.08))
                    .glassEffect(.clear.tint(.black.opacity(0.1)), in: shape)
            } else {
                GlassBackground().overlay(Color.black.opacity(0.15))
            }
        }
        .overlay {
            GeometryReader { geometry in
                let boundary = min(0.95, notchHeight / max(1, geometry.size.height))
                LinearGradient(stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: boundary),
                    .init(color: .black.opacity(0.70), location: boundary + (1 - boundary) * 0.2),
                    .init(color: .black.opacity(0.28), location: boundary + (1 - boundary) * 0.65),
                    .init(color: .black.opacity(0.06), location: 1)
                ], startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(shape)
        .overlay {
            shape.stroke(LinearGradient(colors: [.white.opacity(0.32), .white.opacity(0.04), .white.opacity(0.16)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
        }
    }
}

struct NotchOutline: Shape {
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 8
        var p = Path()
        p.move(to: CGPoint(x: 0.5, y: 0))
        p.addLine(to: CGPoint(x: 0.5, y: rect.height - r))
        p.addQuadCurve(to: CGPoint(x: r, y: rect.height - 0.5), control: CGPoint(x: 0.5, y: rect.height - 0.5))
        p.addLine(to: CGPoint(x: rect.width - r, y: rect.height - 0.5))
        p.addQuadCurve(to: CGPoint(x: rect.width - 0.5, y: rect.height - r), control: CGPoint(x: rect.width - 0.5, y: rect.height - 0.5))
        p.addLine(to: CGPoint(x: rect.width - 0.5, y: 0))
        return p
    }
}

struct HubView: View {
    @ObservedObject var store: HubStore
    @ObservedObject var clock: FocusClock
    @ObservedObject var state: HubState
    @ObservedObject var preferences: HubPreferences
    @State private var search = ""
    @State private var dropTarget = false
    @State private var confirmClear = false
    @State private var clearClipboard = false
    @State private var searching = false
    private let accent = Color(red: 0.64, green: 0.77, blue: 1)
    init(store: HubStore, clock: FocusClock, state: HubState) { self.store = store; self.clock = clock; self.state = state; self.preferences = store.preferences }
    var body: some View {
        VStack(spacing: 0) {
            // Keep all interactive content below the physical camera cutout.
            Color.clear.frame(height: state.expanded ? state.notchHeight : state.collapsedHeight)
            if state.expanded {
                HStack(spacing: 0) {
                    if state.sections.showScreenshotButton || !state.sections.isEmpty || !railCommands.isEmpty {
                        navigationRail
                    }
                    content.frame(maxWidth: .infinity)
                }
                .frame(height: max(0, state.expandedHeight - state.notchHeight))
                .transition(.opacity)
            }
            Spacer(minLength: 0)
        }
        .frame(width: state.expanded ? state.panelWidth : state.collapsedWidth, height: state.expanded ? state.expandedHeight : state.collapsedHeight, alignment: .top)
        .background {
            if state.expanded {
                IslandGlass(notchHeight: state.notchHeight).opacity(state.hasPreview ? state.previewOpacity : state.panelOpacity)
            } else if !state.hasNotch { Color.black.clipShape(Capsule()) }
            else if state.topOffset > 0 || state.collapsedHeight > state.notchHeight + 1 || state.collapsedWidth > state.triggerWidth + 2 {
                Color.black.clipShape(UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8, bottomTrailingRadius: 8, topTrailingRadius: 8))
            }
        }
        .overlay {
            if state.expanded {
                UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 14, topTrailingRadius: 14)
                    .stroke(dropTarget ? accent : Color.white.opacity(0.12), lineWidth: 1)
            } else if state.hasNotch && (!store.archive.clips.isEmpty || !store.archive.shelf.isEmpty) {
                NotchOutline().stroke(accent.opacity(0.85), lineWidth: 1)
            }
        }
        .overlay(alignment: .top) {
            if !state.expanded, let task = state.capsuleTask {
                VStack(spacing: 3) {
                    HStack(spacing: 5) {
                        Image(systemName: task.completed ? "checkmark.circle.fill" : (task.running ? "timer" : "pause.fill"))
                            .foregroundStyle(task.completed ? Color.green : accent)
                        Text(task.title).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 2)
                        Text(task.completed ? "Готово" : task.label).monospacedDigit()
                    }.font(.system(size: 10, weight: .medium))
                    ProgressView(value: max(0, min(1, 1 - task.remaining / task.duration)))
                        .tint(task.completed ? .green : accent).scaleEffect(y: 0.6)
                }
                .padding(.horizontal, 10)
                .frame(width: state.collapsedWidth, height: 30)
                .padding(.top, state.collapsedHeight - 30)
                .contentShape(Rectangle())
                .onTapGesture { state.runCommand?(.openTimers, nil) }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Задача: \(task.title), \(task.completed ? "завершена" : task.label)")
                .help("Открыть задачу · пауза, завершение и смена задачи внутри панели")
            } else if !state.expanded && !state.hasNotch {
                Image(systemName: store.archive.clips.isEmpty ? "doc.on.clipboard" : "doc.on.clipboard.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(store.archive.clips.isEmpty ? Color.white.opacity(0.4) : accent)
                    .frame(width: state.collapsedWidth, height: state.collapsedHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { state.reveal?() }
                    .accessibilityLabel(store.archive.clips.isEmpty ? "Буфер пуст" : "В буфере \(store.archive.clips.count) элементов")
                    .help("NotchHub · верхний край — раскрыть · \(state.shortcut.label) — переключать буфер")
            }
        }
        .overlay(alignment: .topTrailing) {
            if state.expanded {
                toolbar.frame(height: state.notchHeight).padding(.trailing, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier, UTType.utf8PlainText.identifier], isTargeted: $dropTarget, perform: receive)
        .onChange(of: state.sections) { _, _ in confirmClear = false; search = ""; searching = false }
        .onChange(of: confirmClear) { _, shown in state.dialogPresented = shown }
        .onChange(of: state.keyboardSelecting) { _, selecting in
            if selecting { search = ""; searching = false; state.favoritesOnly = false; state.batchMode = false }
        }
        .onChange(of: preferences.current) { _, value in
            if !value.enabled.contains(.favorites) { state.favoritesOnly = false }
            if !value.enabled.contains(.batchActions) { state.batchMode = false; state.batchIDs = [] }
        }
        .alert(clearClipboard ? "Очистить весь буфер обмена?" : "Удалить все элементы?", isPresented: $confirmClear) {
            Button("Отмена", role: .cancel) { }
            Button("Очистить", role: .destructive) {
                if clearClipboard { store.clearClipboard() } else { store.clear(shelf: state.tab == 1) }
            }
        } message: {
            Text(clearClipboard ? "Удалятся история NotchHub и текущее содержимое буфера macOS. Полка и заметка сохранятся." : "Удалятся только сохранённые копии в NotchHub.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    // The rail participates in the body layout, below the camera safe area.
    // A fixed width keeps list/editor/preview content from rendering beneath it.
    private var navigationRail: some View {
        ScrollView(.vertical) {
            VStack(spacing: 3) {
                if state.sections.showScreenshotButton {
                    Button { state.takeScreenshot?() } label: {
                        Image(systemName: "viewfinder").font(.system(size: 12))
                            .frame(width: 24, height: 22)
                            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .buttonStyle(.plain).help("Сделать скриншот\nВыдели область экрана, добавь пометки, скопируй или сохрани изображение.").accessibilityLabel("Сделать скриншот")
                    .padding(.bottom, 3)
                }
                if state.sections.isEnabled(.clipboard) { tab("Буфер", icon: "doc.on.clipboard", index: 0) }
                if state.sections.isEnabled(.shelf) { tab("Полка", icon: "tray", index: 1) }
                if state.sections.isEnabled(.note) { tab("Заметка", icon: "square.and.pencil", index: 2) }
                if state.sections.isEnabled(.timer) { tab("Фокус", icon: HubSection.timer.icon, index: 3) }
                if !railCommands.isEmpty {
                    Rectangle().fill(Color.white.opacity(0.14)).frame(width: 16, height: 1).padding(.vertical, 3)
                    ForEach(railCommands) { command in railAction(command) }
                }
            }
            .frame(width: 28).padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .frame(width: 28)
        .padding(.leading, 6)
    }
    private var railCommands: [HubCommand] {
        state.sections.visibleCommands(enabledFeatures: preferences.current.enabled)
    }
    @ViewBuilder private func railAction(_ command: HubCommand) -> some View {
        if command == .openWorkspaces {
            Menu { workspaceOptions } label: { railIcon(command) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .help(railHelp(command)).accessibilityLabel(command.title)
        } else {
            Button { state.runCommand?(command, nil) } label: { railIcon(command) }
                .buttonStyle(.plain)
                .help(railHelp(command))
                .accessibilityLabel(command.title)
        }
    }
    private func railHelp(_ command: HubCommand) -> String {
        switch command {
        case .openFavorites: return "Избранное и шаблоны\nОткрой закреплённые элементы и часто используемые тексты."
        case .generateUUID: return "Генератор UUID\nСоздавай UUID v4 по одному или списком до 100, копируй выбранный UUID или весь список."
        case .transformText: return "Преобразовать текст\nИзмени раскладку или регистр выбранного текста, отформатируй JSON или очисти ссылку."
        case .correctText: return "Исправить ошибки\nИсправь орфографию словарём macOS без сети. Для пунктуации и грамматики выбери «Полная правка…» и подтверди отправку на свой сервер."
        case .detachPreview: return "Отдельный предпросмотр\nОткрой выбранный элемент в отдельном окне, которое останется доступно после сворачивания панели."
        case .recognizeImage: return "Распознать изображение\nИзвлеки текст из выбранной картинки. Распознавание выполняется на Mac."
        case .recognizeTable: return "Скриншот → таблица\nРаспознай строки и столбцы, проверь ячейки и скопируй таблицу для Excel или Numbers."
        case .batchCopy: return "Копировать выбранное\nВыбери несколько элементов, затем объедини тексты или скопируй файлы вместе."
        case .openWorkspaces: return "Рабочие наборы\nПереключай наборы с отдельными полкой и заметкой или создай новый набор."
        case .openScreenshots: return "История скриншотов\nОткрой сохранённый фрагмент экрана и продолжи редактирование."
        case .openTimers: return "Таймеры\nСоздавай отдельные таймеры для задач, запускай и приостанавливай отсчёт."
        case .share: return "Передача и QR\nПередай выбранные элементы на другой Mac ссылкой или через AirDrop, создай QR-код."
        case .toggleCapture:
            return store.paused ? "Продолжить запись буфера\nНовые скопированные элементы снова будут сохраняться в истории." : "Приостановить запись буфера\nНовые копии временно не сохраняются. Уже записанная история остаётся доступной."
        }
    }
    private func railIcon(_ command: HubCommand) -> some View {
        Image(systemName: command == .toggleCapture && store.paused ? "play.circle" : command.icon)
            .font(.system(size: 11)).frame(width: 24, height: 22)
            .foregroundStyle(command == .toggleCapture && store.paused ? Color.orange : Color.white.opacity(0.7))
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
    }
    private var toolbar: some View {
        HStack(spacing: 3) {
                Button { state.pinned.toggle() } label: {
                    Image(systemName: state.pinned ? "pin.fill" : "pin").frame(width: 20, height: 20)
                }.help("Оставить открытым")
                Button { clearClipboard = true; confirmClear = true } label: {
                    Image(systemName: "trash").frame(width: 20, height: 20)
                }.help("Очистить весь буфер обмена").accessibilityLabel("Очистить весь буфер обмена")
                Menu {
                    if preferences.isEnabled(.favorites) {
                        Button(state.favoritesOnly ? "Вся история" : "Избранное") { state.favoritesOnly.toggle(); state.tab = 0; state.showPreview?(nil) }
                        Button("Шаблоны…") { state.runCommand?(.openFavorites, nil) }
                    }
                    if preferences.isEnabled(.textTools) { Button("Генератор UUID…") { state.runCommand?(.generateUUID, nil) } }
                    if preferences.isEnabled(.screenshotHistory) { Button("История скриншотов…") { state.runCommand?(.openScreenshots, nil) } }
                    if preferences.isEnabled(.multipleTimers) { Button("Таймеры…") { state.runCommand?(.openTimers, nil) } }
                    if preferences.isEnabled(.batchActions), state.tab < 2 { Button(state.batchMode ? "Завершить выбор" : "Выбрать несколько") { state.batchMode.toggle(); state.batchIDs = [] } }
                    Divider()
                    if state.tab >= 0 && state.tab < 2 {
                        Button(searching ? "Скрыть поиск" : "Поиск") { searching.toggle(); if !searching { search = "" } }
                        Button("Очистить", role: .destructive) { clearClipboard = false; confirmClear = true }
                    }
                    Button(store.paused ? "Продолжить запись" : "Пауза записи буфера") { store.paused.toggle(); store.message = nil }
                    Button("Свернуть") { state.pinned = false; state.hide?() }
                } label: { Image(systemName: "ellipsis").frame(width: 20, height: 20) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Меню хаба")
        }
        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.85))
    }
    private var content: some View {
        VStack(spacing: 3) {
            if state.surface == nil, state.previewClip == nil, let task = state.capsuleTask {
                Button { state.runCommand?(.openTimers, nil) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: task.completed ? "checkmark.circle.fill" : "timer")
                        Text(task.title).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(task.completed ? "Готово" : task.label).monospacedDigit()
                        Image(systemName: "chevron.right")
                    }.font(.system(size: 10)).padding(.horizontal, 6).padding(.vertical, 3)
                }.buttonStyle(.plain).foregroundStyle(accent)
                    .help("Открыть выбранную задачу")
            }
            Group {
                if let surface = state.surface {
                    VStack(spacing: 4) {
                        HStack {
                            Button { state.closeSurface?() } label: { Image(systemName: "chevron.left") }.help("Назад к хабу").accessibilityLabel("Назад к хабу")
                            Text(surface.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                        }.buttonStyle(.plain).padding(.horizontal, 12).padding(.top, 4)
                        surface.content.id(surface.id).frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                } else if state.sections.isEmpty {
                    VStack(spacing: 5) {
                        Text("Разделы скрыты").font(.system(size: 11)).foregroundStyle(.secondary)
                        Button("Настройки…") { state.openSettings?() }.font(.system(size: 11)).buttonStyle(.plain)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let clip = state.previewClip {
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Button { state.showPreview?(nil) } label: { Image(systemName: "chevron.left") }.help("Назад к списку")
                            Text(clip.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Spacer()
                            clipActions(clip)
                            Button { store.copy(clip) } label: { Label("Копировать", systemImage: "doc.on.doc") }.font(.system(size: 11))
                        }.buttonStyle(.plain).padding(.horizontal, 5)
                        ClipPreviewView(clip: clip, url: store.assetURL(clip), backgroundOpacity: state.previewOpacity).id(clip.id)
                    }.padding(6).transition(.opacity)
                } else {
                    switch state.tab {
                    case 0, 1: clipsView
                    case 2: noteView
                    default: focusView
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !searching && !state.sections.isEmpty {
                HStack(spacing: 4) {
                Circle().fill(store.paused ? Color.orange : Color.green).frame(width: 4, height: 4)
                Text(store.message ?? (store.paused ? "Буфер на паузе" : "Перетащи сюда · клик — копировать"))
                    .font(.system(size: 8)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                Spacer(minLength: 0)
                if state.tab >= 0 && state.tab < 2 {
                    Text(state.tab == 1 ? "\(store.activeShelf.count)" : "\(state.favoritesOnly ? store.archive.favorites.count : store.archive.clips.count)/\(preferences.current.historyLimit)")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                }.frame(height: 9)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(height: state.expandedHeight - state.notchHeight)
    }
    private func tab(_ title: String, icon: String, index: Int) -> some View {
        Button { state.showPreview?(nil); state.tab = index; state.favoritesOnly = false; state.batchMode = false; state.batchIDs = []; search = ""; searching = false; store.message = nil } label: {
            Image(systemName: icon).font(.system(size: 11))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(state.tab == index ? Color.white.opacity(0.14) : .clear))
                .foregroundStyle(state.tab == index ? accent : Color.white.opacity(0.55))
        }.buttonStyle(.plain).help(title + "\n" + (HubSection(rawValue: index)?.detail ?? "")).accessibilityLabel(title)
    }
    private var items: [Clip] {
        itemSource.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.text?.localizedCaseInsensitiveContains(search) ?? false) }
    }
    private var itemSource: [Clip] { state.tab == 1 ? store.activeShelf : (state.favoritesOnly ? store.archive.favorites : store.archive.clips) }
    private var clipsView: some View {
        VStack(spacing: 1) {
            if state.tab == 1 && preferences.isEnabled(.workspaces) { workspaceSelector }
            if state.favoritesOnly { HStack { Label("Избранное", systemImage: "star.fill").font(.system(size: 10)); Spacer(); Button("Все") { state.favoritesOnly = false }.font(.system(size: 10)) }.foregroundStyle(accent) }
            if state.batchMode { batchBar }
            if searching {
                TextField("Поиск…", text: $search).textFieldStyle(.plain).font(.system(size: 10))
                    .padding(.horizontal, 4).frame(height: 16)
            }
            if items.isEmpty {
                Text(search.isEmpty ? (state.tab == 1 ? "Перетащи файл, картинку или текст" : "Буфер пуст · скопируй что-нибудь") : "Ничего не найдено")
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.85)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { reader in
                    ScrollView {
                        LazyVStack(spacing: 3) { ForEach(items) { clip in row(clip).id(clip.id) } }
                    }.scrollIndicators(.hidden)
                        .onChange(of: state.selectedClipboardID) { _, id in
                            if let id { withAnimation(.easeOut(duration: 0.12)) { reader.scrollTo(id, anchor: .center) } }
                        }
                        .onAppear {
                            if let id = state.selectedClipboardID { reader.scrollTo(id, anchor: .center) }
                        }
                }
            }
        }
    }
    private func row(_ clip: Clip) -> some View {
        HStack(spacing: 6) {
            if state.batchMode {
                Button { if state.batchIDs.contains(clip.id) { state.batchIDs.remove(clip.id) } else { state.batchIDs.insert(clip.id) } } label: { Image(systemName: state.batchIDs.contains(clip.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(accent) }.buttonStyle(.plain).help("Выбрать элемент")
            }
            Button { state.actionClipID = clip.id; if state.batchMode { if state.batchIDs.contains(clip.id) { state.batchIDs.remove(clip.id) } else { state.batchIDs.insert(clip.id) } } else { store.copy(clip) } } label: {
                HStack(spacing: 6) {
                    preview(clip).frame(width: searching ? 16 : 24, height: searching ? 16 : 24).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).clipped()
                    Text(clip.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Image(systemName: store.isFavorite(clip) ? "star.fill" : "doc.on.doc").foregroundStyle(.white.opacity(0.35))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { state.actionClipID = clip.id; state.showPreview?(clip) } label: {
                Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }.buttonStyle(.plain).help("Предпросмотр").accessibilityLabel("Предпросмотр: \(clip.title)")
            clipActions(clip)
        }.padding(4).background(state.selectedClipboardID == clip.id ? accent.opacity(0.25) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(state.selectedClipboardID == clip.id ? accent.opacity(0.8) : .clear, lineWidth: 1) }
            .onDrag { store.provider(clip) }
            .contextMenu {
                clipActionButtons(clip)
                Divider()
                Button("Предпросмотр") { state.showPreview?(clip) }
                Button("Копировать") { store.copy(clip) }
                if let url = store.assetURL(clip) { Button("Открыть") { NSWorkspace.shared.open(url) }; Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                if state.tab == 0 && state.sections.isEnabled(.shelf) { Button("На полку") { var copy = clip; copy.id = UUID(); store.insert(copy, shelf: true) } }
                Button("Удалить", role: .destructive) { store.remove(clip) }
            }
    }
    @ViewBuilder private func preview(_ clip: Clip) -> some View {
        if clip.kind == .image, let url = store.assetURL(clip) {
            AssetImageView(url: url, maxPixelSize: 64, fill: true)
        } else if clip.kind == .file, let url = store.assetURL(clip) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit().padding(5)
        } else { Image(systemName: "text.alignleft").font(.system(size: 17)).foregroundStyle(accent) }
    }
    private var noteView: some View {
        HStack(spacing: 4) {
            TextEditor(text: Binding(get: { store.currentNote }, set: { store.setNote($0) }))
                .font(.system(size: 11)).scrollContentBackground(.hidden).padding(2)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
            Button { copyNote() } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
            .buttonStyle(.plain).help("Копировать заметку")
        }
    }
    func copyNote() {
        guard store.addText(store.currentNote), let clip = store.archive.clips.first else { return }
        store.copy(clip)
    }
    private var focusView: some View {
        HStack(spacing: 9) {
            Text(clock.label).font(.system(size: 23, weight: .light, design: .rounded)).monospacedDigit()
                .foregroundStyle(clock.completed ? accent : .white)
            Spacer(minLength: 0)
            Button { if clock.running { clock.pause() } else { clock.start() } } label: {
                Image(systemName: clock.running ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 21)).foregroundStyle(accent)
            }.help(clock.running ? "Пауза" : "Начать")
            Menu {
                Button("Фокус · 25 минут") { clock.reset() }
                Button("Перерыв · 5 минут") { clock.reset(minutes: 5) }
            } label: { Image(systemName: "clock").font(.system(size: 12)) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Длительность")
            Button { clock.reset() } label: { Image(systemName: "arrow.counterclockwise").font(.system(size: 12)) }.help("Сбросить")
            if preferences.isEnabled(.multipleTimers) { Button { state.runCommand?(.openTimers, nil) } label: { Image(systemName: "list.bullet") }.help("Все таймеры") }
        }.buttonStyle(.plain).padding(.horizontal, 4)
    }
    func receive(_ providers: [NSItemProvider]) -> Bool {
        guard state.sections.isEnabled(.clipboard) || state.sections.isEnabled(.shelf) else { store.message = "Включи Буфер или Полку в настройках"; return false }
        state.reveal?()
        for provider in providers.prefix(20) {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    let url: URL?
                    if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                    else if let value = item as? URL { url = value }
                    else if let value = item as? String { url = URL(string: value) }
                    else { url = nil }
                    DispatchQueue.main.async { if let url { store.enqueueFile(url, shelf: state.sections.isEnabled(.shelf)) } else { store.message = error?.localizedDescription ?? "Не удалось принять файл" } }
                }
            } else if let imageType = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .image) == true }) {
                provider.loadDataRepresentation(forTypeIdentifier: imageType) { data, error in
                    DispatchQueue.main.async { if let data { store.enqueueImage(data, shelf: state.sections.isEnabled(.shelf)) } else { store.message = error?.localizedDescription ?? "Не удалось принять картинку" } }
                }
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, error in
                    let data = (object as? NSImage).flatMap(Self.boundedImageData)
                    DispatchQueue.main.async { if let data { store.enqueueImage(data, shelf: state.sections.isEnabled(.shelf)) } else { store.message = error?.localizedDescription ?? "Не удалось принять картинку" } }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    DispatchQueue.main.async { if let data { store.enqueueImage(data, shelf: state.sections.isEnabled(.shelf)) } else { store.message = error?.localizedDescription ?? "Не удалось принять картинку" } }
                }
            } else {
                _ = provider.loadObject(ofClass: NSString.self) { object, error in
                    let text = object as? String
                    DispatchQueue.main.async { if let text { store.addText(text, shelf: state.sections.isEnabled(.shelf)) } else { store.message = error?.localizedDescription ?? "Не удалось принять текст" } }
                }
            }
        }
        return !providers.isEmpty
    }
    static func boundedImageData(_ image: NSImage) -> Data? {
        let sizes = image.representations.map { rep in
            if let bitmap = rep as? NSBitmapImageRep { return Double(bitmap.bytesPerRow) * Double(bitmap.pixelsHigh) }
            return max(Double(rep.pixelsWide), Double(image.size.width)) * max(Double(rep.pixelsHigh), Double(image.size.height)) * 4
        }
        let bytes = sizes.isEmpty ? Double(image.size.width) * Double(image.size.height) * 4 : sizes.reduce(0, +)
        guard bytes > 0, bytes <= Double(HubStore.maxBytes) else { return nil }
        return image.tiffRepresentation
    }
    @ViewBuilder private var workspaceOptions: some View {
        Button("Общая полка") { store.selectWorkspace(nil) }
        ForEach(store.archive.workspaces) { workspace in Button(workspace.name) { store.selectWorkspace(workspace.id) } }
        Divider(); Button("Новый набор…") { state.editWorkspace?(nil) }
        if let id = store.archive.activeWorkspaceID {
            Button("Переименовать…") { state.editWorkspace?(id) }
            Button("Убрать набор, сохранив содержимое") { store.removeWorkspace(id) }
        }
    }
    private var workspaceSelector: some View {
        Menu { workspaceOptions } label: { HStack { Image(systemName: HubCommand.openWorkspaces.icon); Text(store.archive.workspaces.first { $0.id == store.archive.activeWorkspaceID }?.name ?? "Общая полка").lineLimit(1); Spacer(); Image(systemName: "chevron.down") }.font(.system(size: 10)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).padding(.horizontal, 4)
    }
    private var batchBar: some View {
        let selected = itemSource.filter { state.batchIDs.contains($0.id) }
        return HStack(spacing: 8) {
            Text("\(selected.count) выбрано").font(.system(size: 10))
            Button { _ = store.copyBatch(selected) } label: { Image(systemName: HubCommand.batchCopy.icon) }.help("Копировать выбранное").disabled(selected.isEmpty)
            BatchDragHandle(clips: selected, store: store).frame(width: 70, height: 18)
            if preferences.isEnabled(.sharing) { Button { state.runCommand?(.share, nil) } label: { Image(systemName: "paperplane") }.help("Передать выбранное").disabled(selected.isEmpty) }
            Spacer(); Button { state.batchMode = false; state.batchIDs = [] } label: { Image(systemName: "xmark") }.help("Завершить выбор")
        }.buttonStyle(.plain).padding(4)
    }
    private func clipActions(_ clip: Clip) -> some View {
        Menu { clipActionButtons(clip) } label: { Image(systemName: "ellipsis.circle").font(.system(size: 11)).foregroundStyle(.white.opacity(0.65)) }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Действия с элементом")
    }
    @ViewBuilder private func clipActionButtons(_ clip: Clip) -> some View {
        if preferences.isEnabled(.favorites) { Button(store.isFavorite(clip) ? "Убрать из избранного" : "В избранное") { store.toggleFavorite(clip) } }
        if preferences.isEnabled(.textTools), clip.text != nil {
            Button { state.runCommand?(.transformText, clip) } label: { Label("Преобразовать текст…", systemImage: HubCommand.transformText.icon) }
            Button { state.runCommand?(.correctText, clip) } label: { Label("Исправить ошибки…", systemImage: HubCommand.correctText.icon) }
        }
        if preferences.isEnabled(.detachedPreview) { Button { state.runCommand?(.detachPreview, clip) } label: { Label("Открыть предпросмотр", systemImage: HubCommand.detachPreview.icon) } }
        if preferences.isEnabled(.imageOCR), clip.kind == .image {
            Button { state.runCommand?(.recognizeImage, clip) } label: { Label("Распознать текст…", systemImage: HubCommand.recognizeImage.icon) }
            Button { state.runCommand?(.recognizeTable, clip) } label: { Label("Скриншот → таблица…", systemImage: HubCommand.recognizeTable.icon) }
        }
        if preferences.isEnabled(.sharing) { Button { state.runCommand?(.share, clip) } label: { Label("Передать / поделиться…", systemImage: HubCommand.share.icon) } }
        if preferences.isEnabled(.workspaces) {
            Menu("В рабочий набор") {
                Button("Общая полка") { store.moveToWorkspace(clip, id: nil) }
                ForEach(store.archive.workspaces) { workspace in Button(workspace.name) { store.moveToWorkspace(clip, id: workspace.id) } }
            }
        }
    }
}

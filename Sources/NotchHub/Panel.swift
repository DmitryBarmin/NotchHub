import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    @Published var topOffset: CGFloat = 0
    @Published var triggerWidth: CGFloat = 177
    @Published var previewClip: Clip?
    @Published var previewWidth: CGFloat = 680
    @Published var previewContentHeight: CGFloat = 400
    var panelWidth: CGFloat { previewClip == nil ? expandedWidth : previewWidth }
    var expandedHeight: CGFloat { previewClip == nil ? (sections.isEmpty ? min(panelHeight, notchHeight + 70) : panelHeight) : notchHeight + previewContentHeight }
    @Published var hasNotch = true
    @Published var tab = 0
    @Published var keyboardSelecting = false
    @Published var selectedClipboardID: UUID?
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
    static func atTrigger(_ point: CGPoint, screen: CGRect, notchWidth: CGFloat) -> Bool {
        point.y >= screen.maxY - 1 && point.y <= screen.maxY && abs(point.x - screen.midX) <= notchWidth / 2
    }
    static func insideHub(_ point: CGPoint, panel: CGRect, screen: CGRect, notchWidth: CGFloat, island: CGRect? = nil) -> Bool {
        panel.contains(point) || (island?.contains(point) ?? false) || (point.y >= panel.maxY && point.y <= screen.maxY && abs(point.x - screen.midX) <= notchWidth / 2)
    }
}

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Receives tracking-area events, which the window server sends only while the
/// pointer is over our windows — unlike a global monitor that wakes on every move.
final class HoverTracker: NSResponder {
    var changed: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { changed?() }
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
    init(store: HubStore, clock: FocusClock, state: HubState, screen: NSScreen, layout: HubLayoutPreferences = .standard) {
        self.state = state
        self.screen = screen
        self.layout = layout
        panel = IslandPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = false
        panel.level = .statusBar; panel.hidesOnDeactivate = false; panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hosting = NSHostingView(rootView: HubView(store: store, clock: clock, state: state))
        hosting.sizingOptions = []
        panel.contentView = hosting
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
            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) { self.state.previewClip = clip }
            self.resize(expanded: self.state.expanded, animate: false)
        }
        position()
        panel.orderFrontRegardless()
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
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        if let localPointerMonitor { NSEvent.removeMonitor(localPointerMonitor) }
        pointerMonitor = nil; localPointerMonitor = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        tracker.changed = nil
        edgePanel.orderOut(nil)
        panel.orderOut(nil)
        state.reveal = nil
        state.hide = nil
        state.showPreview = nil
        state.openSettings = nil
    }
    func applySectionVisibility(_ visibility: SectionVisibility) {
        let routed = state.applySectionVisibility(visibility)
        if routed { state.showPreview?(nil) }
    }
    func contains(_ point: CGPoint) -> Bool { screen?.frame.contains(point) ?? false }
    func applyLayout(_ preferences: HubLayoutPreferences) { layout = preferences; position() }
    func position() {
        guard let screen else { return }
        let geometry = HubGeometry.resolve(layout, screen: screen)
        state.hasNotch = geometry.hasNotch; state.notchHeight = geometry.notchHeight
        state.expandedWidth = geometry.panelWidth; state.panelHeight = geometry.panelHeight
        state.previewWidth = geometry.previewWidth; state.previewContentHeight = max(0, geometry.previewHeight - geometry.notchHeight)
        state.collapsedWidth = geometry.islandWidth; state.collapsedHeight = geometry.islandHeight
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
        guard !state.expanded else { return }
        resize(expanded: true, animate: false)
        withAnimation(.spring(response: 0.38, dampingFraction: 0.84)) { state.expanded = true }
        updatePointerMonitor()
    }
    func collapse() {
        guard state.expanded else { return }
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
        if state.pinned || state.keyboardSelecting || state.dialogPresented || inside || NSEvent.pressedMouseButtons != 0 {
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
    @State private var search = ""
    @State private var dropTarget = false
    @State private var confirmClear = false
    @State private var clearClipboard = false
    @State private var searching = false
    private let accent = Color(red: 0.64, green: 0.77, blue: 1)
    var body: some View {
        VStack(spacing: 0) {
            // Keep all interactive content below the physical camera cutout.
            Color.clear.frame(height: state.expanded ? state.notchHeight : state.collapsedHeight)
            if state.expanded {
                HStack(spacing: 0) {
                    if state.sections.showScreenshotButton || !state.sections.isEmpty {
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
                IslandGlass(notchHeight: state.notchHeight).opacity(state.previewClip == nil ? state.panelOpacity : state.previewOpacity)
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
            if !state.expanded && !state.hasNotch {
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
            if selecting { search = ""; searching = false }
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
                    .buttonStyle(.plain).help("Сделать скриншот").accessibilityLabel("Сделать скриншот")
                    .padding(.bottom, 3)
                }
                if state.sections.isEnabled(.clipboard) { tab("Буфер", icon: "doc.on.clipboard", index: 0) }
                if state.sections.isEnabled(.shelf) { tab("Полка", icon: "tray", index: 1) }
                if state.sections.isEnabled(.note) { tab("Заметка", icon: "square.and.pencil", index: 2) }
                if state.sections.isEnabled(.timer) { tab("Фокус", icon: "timer", index: 3) }
            }
            .frame(width: 28).padding(.vertical, 4)
        }
        .scrollIndicators(.hidden)
        .frame(width: 28)
        .padding(.leading, 6)
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
            Group {
                if state.sections.isEmpty {
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
                    Text("\((state.tab == 1 ? store.archive.shelf : store.archive.clips).count)/20")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
                }.frame(height: 9)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .frame(height: state.expandedHeight - state.notchHeight)
    }
    private func tab(_ title: String, icon: String, index: Int) -> some View {
        Button { state.showPreview?(nil); state.tab = index; search = ""; searching = false; store.message = nil } label: {
            Image(systemName: icon).font(.system(size: 11))
                .frame(width: 24, height: 22)
                .background(RoundedRectangle(cornerRadius: 6).fill(state.tab == index ? Color.white.opacity(0.14) : .clear))
                .foregroundStyle(state.tab == index ? accent : Color.white.opacity(0.55))
        }.buttonStyle(.plain).help(title).accessibilityLabel(title)
    }
    private var items: [Clip] {
        (state.tab == 1 ? store.archive.shelf : store.archive.clips).filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) || ($0.text?.localizedCaseInsensitiveContains(search) ?? false) }
    }
    private var clipsView: some View {
        VStack(spacing: 1) {
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
            Button { store.copy(clip) } label: {
                HStack(spacing: 6) {
                    preview(clip).frame(width: searching ? 16 : 24, height: searching ? 16 : 24).background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 8)).clipped()
                    Text(clip.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Image(systemName: "doc.on.doc").foregroundStyle(.white.opacity(0.35))
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button { state.showPreview?(clip) } label: {
                Image(systemName: "eye").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
            }.buttonStyle(.plain).help("Предпросмотр").accessibilityLabel("Предпросмотр: \(clip.title)")
            Button { store.remove(clip) } label: { Image(systemName: "xmark").font(.system(size: 10)).foregroundStyle(.secondary) }.buttonStyle(.plain).help("Удалить")
        }.padding(4).background(state.selectedClipboardID == clip.id ? accent.opacity(0.25) : Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).stroke(state.selectedClipboardID == clip.id ? accent.opacity(0.8) : .clear, lineWidth: 1) }
            .onDrag { store.provider(clip) }
            .contextMenu {
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
            TextEditor(text: Binding(get: { store.archive.note }, set: { store.setNote($0) }))
                .font(.system(size: 11)).scrollContentBackground(.hidden).padding(2)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
            Button {
                let text = store.archive.note; guard !text.isEmpty else { return }
                store.addText(text); if let clip = store.archive.clips.first { store.copy(clip) }
            } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
            .buttonStyle(.plain).help("Копировать заметку")
        }
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
        }.buttonStyle(.plain).padding(.horizontal, 4)
    }
    private func receive(_ providers: [NSItemProvider]) -> Bool {
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
            } else if provider.canLoadObject(ofClass: NSImage.self) {
                _ = provider.loadObject(ofClass: NSImage.self) { object, error in
                    let data = (object as? NSImage)?.tiffRepresentation
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
}

#if os(macOS)
import LazyPrintKit
import SwiftUI

/// The print tab: the task in use with the Task menu, the sheet the settings make of the documents, the sheet and
/// side being looked at, the plan's notes and the strip of documents; the inspector on the right. Twin of the
/// Windows print tab.
struct PrintView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme

    /// Opens the panel for more files.
    var addFiles: () -> Void
    /// A recent file was picked.
    var openRecent: (URL) -> Void
    /// A task was picked from the Task menu.
    var pickTask: (PrintTask) -> Void

    private static let stagePadding: CGFloat = 24
    private static let zoomStep: CGFloat = 1.25
    private static let maxZoom: CGFloat = 8

    /// The zoom as a fraction of the sheet's real size (a screen point to a paper point); nil fits the sheet to the stage.
    @State private var zoom: CGFloat?
    /// The zoom that fits the sheet to the stage now, which the bar shows when nothing is zoomed.
    @State private var fit: CGFloat = 1
    /// The name being asked for, to save the options as a preset or to rename one.
    @State private var presetDialog: PresetDialog?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                banner
                Divider()
                if sheets.isEmpty {
                    emptyStage
                } else {
                    stage
                    previewBar
                    notes
                }
                if !state.documents.isEmpty {
                    Divider()
                    DocumentStrip(addFiles: addFiles, openRecent: openRecent)
                        .padding(12)
                }
            }
            Divider()
            InspectorView()
                .frame(width: 300)
        }
        .presetDialogs($presetDialog)
    }

    // MARK: The sheets

    private var sheets: [Sheet] { state.jobPlan?.plan.sheets ?? [] }

    /// The sheet and side `previewSide` counts to, over the front and the back of each sheet in turn.
    private var current: (sheet: Int, back: Bool) {
        var left = state.previewSide
        for (index, sheet) in sheets.enumerated() {
            let sides = sheet.back == nil ? 1 : 2
            if left < sides { return (index, left == 1) }
            left -= sides
        }
        return (max(0, sheets.count - 1), false)
    }

    private func side(sheet: Int, back: Bool) -> Int {
        sheets.prefix(sheet).reduce(0) { $0 + ($1.back == nil ? 1 : 2) } + (back ? 1 : 0)
    }

    // MARK: Parts

    private var banner: some View {
        HStack(spacing: 12) {
            if let task = state.task {
                let definition = TaskCatalog.definition(task)
                Image(systemName: TaskSymbols.systemImage(definition.iconKey))
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(definition.title)
                        .font(.headline)
                    Text(definition.subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Pick a task to set everything up, or just add files.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            taskMenu
            if state.task != nil {
                Button {
                    state.clearTask()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .disabled(state.isBusy || state.hasBacksWaiting)
                .help("Keep the settings and leave the task")
                .accessibilityLabel("Leave the task")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private var taskMenu: some View {
        Menu {
            ForEach(TaskGroup.allCases, id: \.self) { group in
                let definitions = state.taskDefinitions.filter { $0.group == group }
                if !definitions.isEmpty {
                    Section(group.title) {
                        ForEach(definitions, id: \.task) { definition in
                            taskItem(definition)
                        }
                    }
                }
            }
            PresetMenuSection(dialog: $presetDialog)
        } label: {
            Label("Task", systemImage: "list.bullet")
        }
        .fixedSize()
        .disabled(state.isBusy || state.isAddingFiles || state.hasBacksWaiting)
    }

    /// The current task is the checked item; one that cannot be started says why after its title.
    private func taskItem(_ definition: TaskDefinition) -> some View {
        let availability = state.availability(of: definition.task)
        let title = availability.isAvailable ? definition.title : "\(definition.title) \u{2013} \(availability.reason ?? "")"
        let isCurrent = Binding(get: { state.task == definition.task }, set: { (on: Bool) in
            if on { pickTask(definition.task) }
        })
        return Toggle(isOn: isCurrent) {
            Label(title, systemImage: TaskSymbols.systemImage(definition.iconKey))
        }
        .disabled(!availability.isAvailable)
        .help(definition.subtitle + "\n" + state.summary(of: definition.task))
    }

    private var emptyStage: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("Nothing to print yet")
                .font(.title3.weight(.semibold))
            Text("Pages you add appear here.")
                .foregroundStyle(.secondary)
            Button {
                addFiles()
            } label: {
                Label("Add files\u{2026}", systemImage: "plus")
            }
            .padding(.top, 4)
            RecentMenu(open: openRecent)
            Text("Or drop PDFs, pictures and text files anywhere in the window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The sheet, fitted to the stage or zoomed; its pixels follow the zoom and the screen's, at most three to a point as on
    /// the iPhone, and a bigger zoom stretches them.
    private var stage: some View {
        GeometryReader { geometry in
            let paper = state.jobPlan?.plan.area.paper ?? LayoutSize(width: 612, height: 792)
            let fitted = CGFloat(max(min((geometry.size.width - 2 * Self.stagePadding) / paper.width,
                                         (geometry.size.height - 2 * Self.stagePadding) / paper.height), 0.1))
            let scale: CGFloat = zoom ?? fitted
            // Whole steps of a quarter, so a small change draws nothing.
            let wanted = min(3, max(0.5, (scale * displayScale * 4).rounded(.up) / 4))
            ZStack {
                // The system's under-page color is barely darker than the panel in Dark Mode.
                scheme == .dark ? Color(white: 0.08) : Color(nsColor: .underPageBackgroundColor)
                if let image = state.preview {
                    SheetScroller(image: image,
                                  size: CGSize(width: (CGFloat(paper.width) * scale).rounded(.down), height: (CGFloat(paper.height) * scale).rounded(.down)),
                                  padding: Self.stagePadding, zoomBy: zoomBy)
                        .accessibilityLabel("Sheet \(current.sheet + 1), \(current.back ? "back" : "front")")
                }
            }
            .onChange(of: wanted, initial: true) { _, scale in
                state.previewScale = scale
            }
            .onChange(of: fitted, initial: true) { _, value in
                fit = value
                if let zoom, zoom <= value * 1.001 { self.zoom = nil }
            }
        }
    }

    /// Zooms by a factor; out past the fit goes back to fitting.
    private func zoomBy(_ factor: CGFloat) {
        let next = min(max((zoom ?? fit) * factor, fit), max(Self.maxZoom, fit))
        zoom = next <= fit * 1.001 ? nil : next
    }

    private var zoomControls: some View {
        HStack(spacing: 2) {
            Button {
                zoomBy(1 / Self.zoomStep)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .disabled(zoom == nil)
            .keyboardShortcut("-", modifiers: .command)
            .help("Zoom out")
            .accessibilityLabel("Zoom out")
            Button {
                zoom = nil
            } label: {
                Text("\(Int(((zoom ?? fit) * 100).rounded()))%")
                    .monospacedDigit()
                    .frame(minWidth: 44)
            }
            .keyboardShortcut("0", modifiers: .command)
            .help("Fit to window")
            .accessibilityLabel("Fit to window")
            Button {
                zoomBy(Self.zoomStep)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .disabled((zoom ?? fit) >= Self.maxZoom)
            .keyboardShortcut("+", modifiers: .command)
            // Command and = is the key most people press for plus.
            .background {
                Button("") { zoomBy(Self.zoomStep) }
                    .keyboardShortcut("=", modifiers: .command)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
            .help("Zoom in")
            .accessibilityLabel("Zoom in")
        }
    }

    private var previewBar: some View {
        let now = current
        let sheet = sheets[min(now.sheet, sheets.count - 1)]
        return HStack {
            zoomControls
            Spacer()
            Button {
                state.previewSide = side(sheet: now.sheet - 1, back: false)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(now.sheet == 0)
            .help("Previous sheet")
            Text("Sheet \(now.sheet + 1) of \(sheets.count)")
                .monospacedDigit()
            Button {
                state.previewSide = side(sheet: now.sheet + 1, back: false)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(now.sheet >= sheets.count - 1)
            .help("Next sheet")
            Spacer()
            if sheet.back != nil {
                Picker("Side", selection: Binding(
                    get: { now.back },
                    set: { state.previewSide = side(sheet: now.sheet, back: $0) })) {
                    Text("Front").tag(false)
                    Text("Back").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// What the plan did to fit the pages: blanks added, pages made smaller.
    @ViewBuilder
    private var notes: some View {
        if let notes = state.jobPlan?.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}

/// The sheet at the size it has on the screen, in a scroll view that is also panned by dragging, which SwiftUI's own
/// scroll view does not do with a mouse. A pinch, or the wheel with Command or Control held, asks `zoomBy` for a zoom.
private struct SheetScroller: NSViewRepresentable {
    let image: CGImage
    let size: CGSize
    let padding: CGFloat
    let zoomBy: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.documentView = SheetView()
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        (scroll.documentView as? SheetView)?.show(image, size: size, padding: padding, zoomBy: zoomBy)
    }
}

/// The scroll view's document: as large as the sheet and its padding, or the visible area when that is more, with the sheet
/// in the middle of it.
private final class SheetView: NSView {
    private var image: CGImage?
    private var sheet = CGSize.zero
    private var padding: CGFloat = 0
    private var zoomBy: (CGFloat) -> Void = { _ in }

    override var isFlipped: Bool { true }

    func show(_ image: CGImage, size: CGSize, padding: CGFloat, zoomBy: @escaping (CGFloat) -> Void) {
        let resized = size != sheet
        // A new size keeps the middle of what is shown in the middle.
        var middle = CGPoint(x: 0.5, y: 0.5)
        if resized, let clip = enclosingScrollView?.contentView, frame.width > 0, frame.height > 0 {
            middle = CGPoint(x: clip.bounds.midX / frame.width, y: clip.bounds.midY / frame.height)
        }
        self.image = image
        self.sheet = size
        self.padding = padding
        self.zoomBy = zoomBy
        fitFrame()
        if resized, let scroll = enclosingScrollView {
            let clip = scroll.contentView
            let origin = NSPoint(x: middle.x * frame.width - clip.bounds.width / 2, y: middle.y * frame.height - clip.bounds.height / 2)
            clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
            scroll.reflectScrolledClipView(clip)
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        guard let clip = superview as? NSClipView else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(visibleAreaChanged), name: NSView.frameDidChangeNotification,
                                               object: clip)
    }

    @objc private func visibleAreaChanged(_ notification: Notification) {
        fitFrame()
        needsDisplay = true
    }

    private func fitFrame() {
        let visible = enclosingScrollView?.contentSize ?? .zero
        setFrameSize(NSSize(width: max(sheet.width + 2 * padding, visible.width), height: max(sheet.height + 2 * padding, visible.height)))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let image else { return }
        let rect = NSRect(x: ((bounds.width - sheet.width) / 2).rounded(), y: ((bounds.height - sheet.height) / 2).rounded(),
                          width: sheet.width, height: sheet.height)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 6
        shadow.shadowOffset = NSSize(width: 0, height: -2)
        shadow.set()
        NSColor.white.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()
        // The bitmap keeps its own shape until the redraw for a new paper lands.
        let scale = min(rect.width / CGFloat(image.width), rect.height / CGFloat(image.height))
        let drawn = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let target = NSRect(x: rect.midX - drawn.width / 2, y: rect.midY - drawn.height / 2, width: drawn.width, height: drawn.height)
        NSImage(cgImage: image, size: target.size).draw(in: target, from: .zero, operation: .sourceOver, fraction: 1,
                                                       respectFlipped: true,
                                                       hints: [.interpolation: NSImageInterpolation.high.rawValue])
    }

    override func resetCursorRects() {
        guard let visible = enclosingScrollView?.contentSize, frame.width > visible.width || frame.height > visible.height else { return }
        addCursorRect(visibleRect, cursor: .openHand)
    }

    // The mouse-down is taken so the drag arrives here.
    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        guard let scroll = enclosingScrollView else { return }
        let clip = scroll.contentView
        let origin = NSPoint(x: clip.bounds.origin.x - event.deltaX, y: clip.bounds.origin.y - event.deltaY)
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        scroll.reflectScrolledClipView(clip)
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control) {
            // A wheel with notches reports lines, a trackpad points.
            let dy = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 5
            zoomBy(exp(dy * 0.02))
        } else {
            super.scrollWheel(with: event)
        }
    }

    override func magnify(with event: NSEvent) {
        zoomBy(1 + event.magnification)
    }
}
#endif

#if os(iOS)
import CoreGraphics
import ImageIO
import LazyPrintKit
import SwiftUI
import UIKit

/// Which sheet and side `AppState.previewSide` counts to, over the front and the back of each sheet in turn.
struct PreviewPosition: Equatable {
    let sheet: Int
    let back: Bool
    let count: Int

    /// A side past the end is the last sheet's front.
    init(side: Int, sheets: [Sheet]) {
        var found: Int = max(0, sheets.count - 1)
        var onBack: Bool = false
        var left: Int = max(0, side)
        for (index, sheet) in sheets.enumerated() {
            let sides: Int = sheet.back == nil ? 1 : 2
            if left < sides {
                found = index
                onBack = left == 1
                break
            }
            left -= sides
        }
        self.sheet = found
        self.back = onBack
        self.count = sheets.count
    }

    /// The side on the other face of this one's sheet. A two-sided plan gives every sheet a back, so a sheet's faces are an
    /// even side and the one after it; on a one-sided plan the other face has nothing printed on it.
    static func otherSide(of side: Int, sheets: [Sheet]) -> Int? {
        guard sheets.first?.back != nil, (0..<sheets.count * 2).contains(side) else { return nil }
        return side ^ 1
    }

    /// The pages on a side, numbered over the documents in turn: "Page 3", "Pages 3-4", "Pages 1, 8". `pageCounts` is the
    /// pages of each document. A side with no pages on it is "Blank".
    static func pages(on side: SheetSide, pageCounts: [Int]) -> String {
        let numbers: [Int] = Set(side.placements.map { (placement: Placement) -> Int in
            pageCounts.prefix(placement.page.document).reduce(0, +) + placement.page.index + 1
        }).sorted()
        guard !numbers.isEmpty else { return "Blank" }
        var runs: [ClosedRange<Int>] = []
        for number in numbers {
            if let last = runs.last, last.upperBound + 1 == number {
                runs[runs.count - 1] = last.lowerBound...number
            } else {
                runs.append(number...number)
            }
        }
        let text: [String] = runs.map { (run: ClosedRange<Int>) -> String in
            run.count == 1 ? "\(run.lowerBound)" : "\(run.lowerBound)\u{2013}\(run.upperBound)"
        }
        return (numbers.count == 1 ? "Page " : "Pages ") + text.joined(separator: ", ")
    }
}

/// The print screen: the task in use, the sides the settings make of the documents as paper to fold over, "Page 3 \u{00B7}
/// Sheet 2" with previous and next under them, the plan's notes, the documents and the Options row; the Print button is fixed
/// at the bottom and says what it does. In landscape, and on an iPad, the page is on the left and the rest scrolls on the right.
struct PrintScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var scheme

    /// Opens the Files importer or the photo picker.
    var addFiles: (FileSource) -> Void
    /// A task was picked from the Task menu.
    var pickTask: (PrintTask) -> Void
    var showPrinters: () -> Void
    var showJobs: () -> Void

    @State private var showOptions = false
    @State private var showDocuments = false
    /// Add files was asked from the documents sheet, with this source: it opens once that sheet has closed.
    @State private var addAfterDocuments: FileSource?
    /// The files are being sent to the paired computer.
    @State private var sending = false
    /// What sits above and under the page in portrait, which gets the rest of the height.
    @State private var aboveStage: CGFloat = 56
    @State private var belowStage: CGFloat = 90
    /// A two-sided job zoomed into one page rather than shown as two decks.
    @State private var singlePage = false
    /// How far the single page is zoomed in, 1 to 4.
    @State private var zoom: CGFloat = 1
    /// The arrows on the page, clear until the page is touched and faint a moment after.
    @State private var arrowsShown = true
    @State private var fadeArrows: Task<Void, Never>?

    private static let stagePadding: CGFloat = 10

    var body: some View {
        NavigationStack {
            GeometryReader { (geometry: GeometryProxy) in
                if verticalSizeClass == .compact || horizontalSizeClass == .regular {
                    landscape(geometry.size)
                } else {
                    portrait(geometry.size)
                }
            }
            .navigationTitle(state.task.map { TaskCatalog.definition($0).title } ?? "Print")
            .navigationBarTitleDisplayMode(.inline)
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: showJobs) {
                        Label("Jobs", systemImage: "clock.arrow.circlepath")
                    }
                    .accessibilityIdentifier("print.jobs")
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    taskMenu
                    if state.task != nil {
                        Button {
                            state.clearTask()
                        } label: {
                            Label("Leave the task", systemImage: "xmark")
                        }
                        .disabled(state.isBusy)
                        .accessibilityIdentifier("print.leaveTask")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                printBar
            }
            .sheet(isPresented: $showOptions) {
                OptionsSheet()
            }
            .sheet(isPresented: $showDocuments, onDismiss: {
                if let source = addAfterDocuments {
                    addAfterDocuments = nil
                    addFiles(source)
                }
            }) {
                DocumentsSheet(addFiles: { (source: FileSource) in
                    addAfterDocuments = source
                    showDocuments = false
                })
            }
            // The two-sided card and the certificate question are shown by the root and the sheets of this screen are in the way.
            .onChange(of: state.duplexCard != nil || state.certificateRequest != nil) { (_: Bool, asking: Bool) in
                if asking {
                    showOptions = false
                    showDocuments = false
                }
            }
        }
    }

    // MARK: The task menu

    private var taskMenu: some View {
        Menu {
            ForEach(TaskGroup.allCases, id: \.self) { (group: TaskGroup) in
                let definitions: [TaskDefinition] = state.taskDefinitions.filter { $0.group == group }
                if !definitions.isEmpty {
                    Section(group.title) {
                        ForEach(definitions, id: \.task) { (definition: TaskDefinition) in
                            taskItem(definition)
                        }
                    }
                }
            }
        } label: {
            Label("Task", systemImage: "list.bullet")
        }
        .disabled(state.isBusy)
        .accessibilityIdentifier("print.task")
    }

    /// The current task is the checked item; one that cannot be started says why under its title.
    private func taskItem(_ definition: TaskDefinition) -> some View {
        let availability: TaskAvailability = state.availability(of: definition.task)
        let isCurrent = Binding<Bool>(get: { state.task == definition.task }, set: { (on: Bool) in
            if on { pickTask(definition.task) }
        })
        return Toggle(isOn: isCurrent) {
            Label {
                Text(definition.title)
                if let reason = availability.reason, !availability.isAvailable {
                    Text(reason)
                }
            } icon: {
                Image(systemName: TaskSymbols.systemImage(definition.iconKey))
            }
        }
        .disabled(!availability.isAvailable)
        .accessibilityIdentifier("task." + definition.task.rawValue)
    }

    // MARK: Layouts

    /// The page takes what the rest leaves; with text so large that the rest fills the screen, the screen scrolls.
    private func portrait(_ size: CGSize) -> some View {
        let spacing: CGFloat = 8
        return ScrollView {
            VStack(spacing: spacing) {
                PrinterButton(action: showPrinters)
                    .padding(.horizontal, 16)
                    .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
                        proxy.size.height
                    } action: { (height: CGFloat) in
                        aboveStage = height
                    }
                stageArea(CGSize(width: size.width, height: max(280, size.height - aboveStage - belowStage - 4 * spacing)))
                VStack(spacing: spacing) {
                    if !sheets.isEmpty {
                        previewBar
                        notes
                    }
                    if !state.documents.isEmpty {
                        DocumentBar(addFiles: addFiles, edit: { showDocuments = true })
                    }
                }
                .onGeometryChange(for: CGFloat.self) { (proxy: GeometryProxy) -> CGFloat in
                    proxy.size.height
                } action: { (height: CGFloat) in
                    belowStage = height
                }
            }
            .padding(.vertical, spacing)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func landscape(_ size: CGSize) -> some View {
        HStack(spacing: 0) {
            stageArea(CGSize(width: size.width * 0.6, height: size.height))
            ScrollView {
                VStack(spacing: 12) {
                    PrinterButton(action: showPrinters)
                    if !sheets.isEmpty {
                        previewBar
                        notes
                    }
                    if !state.documents.isEmpty {
                        DocumentBar(addFiles: addFiles, edit: { showDocuments = true })
                    }
                }
                .padding(16)
            }
        }
    }

    // MARK: The sheets

    private var sheets: [Sheet] { state.jobPlan?.plan.sheets ?? [] }

    private var sideCount: Int { state.jobPlan?.plan.sideCount ?? 0 }

    private var twoSided: Bool { sheets.first?.back != nil }

    private var showsDecks: Bool { twoSided && !singlePage }

    /// The sides in view: the current one, or the two of the decks' spread.
    private var sidesInView: [Int] {
        guard showsDecks else { return [state.previewSide] }
        let spread: Int = PageDecksView.spread(of: state.previewSide)
        return [2 * spread - 1, 2 * spread].filter { (0..<sideCount).contains($0) }
    }

    /// "Page 3 \u{00B7} Sheet 2 front", or across the decks "Pages 2\u{2013}3 \u{00B7} Sheets 1\u{2013}2".
    private var positionText: String {
        let positions: [PreviewPosition] = sidesInView.map { PreviewPosition(side: $0, sheets: sheets) }
        guard let first = positions.first, let last = positions.last else { return "" }
        if first.sheet != last.sheet {
            return "\(pagesInView) \u{00B7} Sheets \(first.sheet + 1)\u{2013}\(last.sheet + 1)"
        }
        let side: String = sheets[first.sheet].back == nil ? "" : first.back ? " back" : " front"
        return "\(pagesInView) \u{00B7} Sheet \(first.sheet + 1)\(side)"
    }

    /// The same for VoiceOver, with how many sheets there are.
    private var positionLabel: String {
        let sides: [String] = sidesInView.map { (side: Int) -> String in
            let position = PreviewPosition(side: side, sheets: sheets)
            let face: String = sheets[position.sheet].back == nil ? "" : position.back ? ", back" : ", front"
            return "sheet \(position.sheet + 1) of \(position.count)\(face)"
        }
        return "\(pagesInView), " + sides.joined(separator: " and ")
    }

    private var pagesInView: String {
        let placements: [Placement] = sidesInView.flatMap { (side: Int) -> [Placement] in
            let position = PreviewPosition(side: side, sheets: sheets)
            let sheet: Sheet = sheets[position.sheet]
            return (position.back ? sheet.back ?? sheet.front : sheet.front).placements
        }
        return PreviewPosition.pages(on: SheetSide(placements: placements, borders: false),
                                     pageCounts: state.documents.map { $0.loaded.pages.count })
    }

    private func stageArea(_ size: CGSize) -> some View {
        Group {
            if sheets.isEmpty {
                emptyStage
            } else {
                stage(size)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private var emptyStage: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.on.doc")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            if state.documents.isEmpty {
                Text("Nothing to print yet")
                    .font(.title3.weight(.semibold))
                Text("Pages you add appear here.")
                    .foregroundStyle(.secondary)
                AddFilesMenu(identifier: "print.addFiles", pick: addFiles)
                    .buttonStyle(.bordered)
                    .padding(.top, 4)
                    .disabled(state.isBusy || state.isAddingFiles)
            } else {
                Text("No pages to print")
                    .font(.title3.weight(.semibold))
                if let problem = state.pageRangeError {
                    Text(problem)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .multilineTextAlignment(.center)
        .padding()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("print.empty")
    }

    /// The page, or the two decks, as large as the stage lets them be; their pixels follow the stage's size, the zoom and the
    /// screen's.
    private func stage(_ size: CGSize) -> some View {
        let paper: LayoutSize = state.jobPlan?.plan.area.paper ?? LayoutSize(width: 612, height: 792)
        let decks: Bool = showsDecks
        let across: Double = decks ? 2 * paper.width : paper.width
        let fit: Double = max(0.1, min((size.width - 2 * Self.stagePadding) / across,
                                       (size.height - 2 * Self.stagePadding) / paper.height))
        // Whole steps of a quarter, so a small resize draws nothing.
        let wanted: Double = min(4, max(0.5, (fit * displayScale * (decks ? 1 : zoom) * 4).rounded(.up) / 4))
        return ZStack {
            scheme == .dark ? Color(white: 0.08) : Color(uiColor: .systemGroupedBackground)
            pages(decks: decks, paper: CGSize(width: paper.width * fit, height: paper.height * fit))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(positionLabel)
                .accessibilityAdjustableAction { (direction: AccessibilityAdjustmentDirection) in
                    switch direction {
                    case .increment: turn(by: 1)
                    case .decrement: turn(by: -1)
                    @unknown default: break
                    }
                }
                .accessibilityIdentifier("preview.stage")
            arrows
        }
        .simultaneousGesture(TapGesture().onEnded { showArrows() })
        .onAppear { showArrows() }
        .onChange(of: state.previewSide) { showArrows() }
        .onChange(of: wanted, initial: true) { (_: Double, scale: Double) in
            state.previewScale = scale
        }
    }

    @ViewBuilder
    private func pages(decks: Bool, paper: CGSize) -> some View {
        let model: AppState = state
        if decks {
            PageDecksView(count: sideCount, sheets: sheets, side: $state.previewSide, image: state.preview,
                          drawn: { (side: Int) -> CGImage? in model.drawnPreviewImage(ofSide: side) },
                          draw: { (side: Int) -> CGImage? in await model.previewImage(ofSide: side) },
                          zoomIn: { (side: Int) in
                              state.previewSide = side
                              singlePage = true
                          })
                .frame(width: 2 * paper.width, height: paper.height)
        } else {
            PageFoldView(count: sideCount, sheets: sheets, side: $state.previewSide, image: state.preview,
                         drawn: { (side: Int) -> CGImage? in model.drawnPreviewImage(ofSide: side) },
                         draw: { (side: Int) -> CGImage? in await model.previewImage(ofSide: side) },
                         paperSize: paper,
                         zoomOut: twoSided ? {
                             zoom = 1
                             singlePage = false
                         } : nil,
                         zoomed: { (scale: CGFloat) in zoom = scale })
                // A new page view starts at full size, whatever an old one was zoomed to.
                .onAppear { zoom = 1 }
        }
    }

    /// Previous and next on the page's edges.
    private var arrows: some View {
        HStack {
            arrow("chevron.left", label: "Previous page", id: "print.previous", enabled: canTurn(by: -1)) { turn(by: -1) }
            Spacer(minLength: 0)
            arrow("chevron.right", label: "Next page", id: "print.next", enabled: canTurn(by: 1)) { turn(by: 1) }
        }
        .padding(.horizontal, 8)
        .opacity(arrowsShown ? 1 : 0.25)
        .animation(.easeInOut(duration: 0.4), value: arrowsShown)
    }

    private func arrow(_ symbol: String, label: String, id: String, enabled: Bool,
                       action: @escaping () -> Void) -> some View {
        Button {
            action()
            showArrows()
        } label: {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0)
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    private func showArrows() {
        arrowsShown = true
        fadeArrows?.cancel()
        fadeArrows = Task {
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled {
                arrowsShown = false
            }
        }
    }

    /// The side a step of the arrows lands on: a side, or across the decks a spread.
    private func target(by offset: Int) -> Int {
        guard showsDecks else { return state.previewSide + offset }
        let spread: Int = PageDecksView.spread(of: state.previewSide) + offset
        guard spread >= 0, spread <= sideCount / 2 else { return -1 }
        return PageDecksView.side(of: spread, count: sideCount)
    }

    private func canTurn(by offset: Int) -> Bool {
        let side: Int = target(by: offset)
        return side >= 0 && side < sideCount && side != state.previewSide
    }

    private func turn(by offset: Int) {
        guard canTurn(by: offset) else { return }
        state.previewSide = target(by: offset)
    }

    private var previewBar: some View {
        Text(positionText)
            .monospacedDigit()
            .accessibilityLabel(positionLabel)
            .accessibilityIdentifier("preview.position")
            .frame(minHeight: 32)
    }

    /// What the plan did to the pages: blanks added, edges cut off.
    @ViewBuilder
    private var notes: some View {
        if let notes = state.jobPlan?.notes, !notes.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notes, id: \.self) { (note: String) in
                    Label(note, systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
    }

    // MARK: Controls

    private var optionsButton: some View {
        Button {
            showOptions = true
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Options")
                        .foregroundStyle(.primary)
                    if !optionsSummary.isEmpty {
                        Text(optionsSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: "slider.horizontal.3")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(state.isBusy)
        .accessibilityIdentifier("print.options")
    }

    /// What differs from the defaults, so a setting is never out of sight.
    private var optionsSummary: String {
        let s: PrintSettings = state.settings
        var parts: [String] = [InspectorSections.pagesSummary(s), InspectorSections.layoutSummary(s), InspectorSections.paperSummary(s)]
        if state.task == .photos || state.task == .photoSheet { parts.append(InspectorSections.photosSummary(s)) }
        return parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }

    /// Options above Print, both always in reach. Print says what it does; greyed out, VoiceOver says why. Once a computer is
    /// paired, Send to it sits beside Print.
    private var printBar: some View {
        let reason: String? = state.printDisabledReason
        return VStack(spacing: 6) {
            optionsButton
            if IOSCompanionText.offersSend(state.companionStatus) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        printButton(reason)
                        sendButton
                    }
                    VStack(spacing: 8) {
                        printButton(reason)
                        sendButton
                    }
                }
            } else {
                printButton(reason)
            }
            if state.isBusy {
                HStack(spacing: 12) {
                    ProgressView()
                    Text(state.status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("print.status")
                    Button("Cancel") { state.cancelJob() }
                        .accessibilityIdentifier("print.cancel")
                }
            } else if state.isAddingFiles {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Adding files\u{2026}")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("print.adding")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    private func printButton(_ reason: String?) -> some View {
        Button {
            Task { await state.print() }
        } label: {
            Text(state.printLabel)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(Color("PrintFill"))
        .controlSize(.large)
        .disabled(reason != nil)
        .accessibilityLabel(reason == nil ? state.printLabel : "\(state.printLabel), not available: \(reason ?? "")")
        .accessibilityIdentifier("print.button")
    }

    /// Sends the files of the documents to the paired computer, which prints them there.
    private var sendButton: some View {
        Button {
            let name: String = UIDevice.current.name
            sending = true
            Task {
                await state.sendJobToDesktop(from: name)
                sending = false
            }
        } label: {
            Text(IOSCompanionText.sendButton(state.companionDesktop?.name ?? ""))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(state.documents.isEmpty || state.isBusy || sending)
        .accessibilityIdentifier("print.send")
    }
}

/// A line under the preview: how many documents and pages, Edit to open the sheet that reorders and removes them, and the
/// plus that adds more.
private struct DocumentBar: View {
    @EnvironmentObject private var state: AppState
    let addFiles: (FileSource) -> Void
    let edit: () -> Void

    var body: some View {
        HStack {
            Text(summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("documents.summary")
            Spacer(minLength: 8)
            Button("Edit", action: edit)
                .disabled(state.isBusy)
                .accessibilityIdentifier("documents.edit")
            AddFilesMenu(identifier: "documents.add", pick: addFiles)
                .disabled(state.isBusy || state.isAddingFiles)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
    }

    private var summary: String {
        let documents: Int = state.documents.count
        let pages: Int = state.pageCount
        return "\(documents) document\(documents == 1 ? "" : "s") \u{00B7} \(pages) page\(pages == 1 ? "" : "s")"
    }
}

/// The documents in a list to reorder and remove: drag by the handle, swipe or use the delete button. Shown as a sheet.
private struct DocumentsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let addFiles: (FileSource) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(state.documents.enumerated()), id: \.offset) { _, document in
                    DocumentRow(document: document)
                }
                .onMove { (from: IndexSet, to: Int) in
                    guard let index = from.first else { return }
                    let target: Int = to > index ? to - 1 : to
                    state.move(at: index, by: target - index)
                }
                .onDelete { (offsets: IndexSet) in
                    for index in offsets.sorted(by: >) {
                        state.remove(at: index)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .disabled(state.isBusy || state.isAddingFiles)
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A menu in a row of a list in edit mode doesn't open, so Add files sits in the bar.
                ToolbarItem(placement: .topBarLeading) {
                    AddFilesMenu(identifier: "documents.sheetAdd", pick: addFiles)
                        .disabled(state.isBusy || state.isAddingFiles)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("documents.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

private struct DocumentRow: View {
    let document: OpenedDocument

    var body: some View {
        let pages: Int = document.loaded.pages.count
        let count: String = "\(pages) page\(pages == 1 ? "" : "s")"
        HStack(spacing: 12) {
            Thumbnail(document: document)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(document.loaded.name)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(count)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(document.loaded.name), \(count)")
    }
}

/// The first page of a document, drawn off the main actor when it appears.
private struct Thumbnail: View {
    let document: OpenedDocument
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.25), radius: 2)
            } else {
                Color.clear
            }
        }
        .task(id: document.url) {
            let opened: OpenedDocument = document
            image = await Task.detached { Self.make(opened) }.value
        }
        .accessibilityHidden(true)
    }

    private nonisolated static func make(_ document: OpenedDocument) -> CGImage? {
        let side: Int = 192
        switch document.source {
        case .picture(let source):
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        case .pdf(let pdf):
            return document.drawing.locked { () -> CGImage? in
                guard let page = pdf.page(at: 1) else { return nil }
                let box: CGRect = page.getBoxRect(.cropBox)
                let turned: Bool = page.rotationAngle % 180 != 0
                let shown: CGSize = turned ? CGSize(width: box.height, height: box.width) : box.size
                guard shown.width > 0, shown.height > 0 else { return nil }
                let scale: CGFloat = CGFloat(side) / max(shown.width, shown.height)
                let width: Int = max(1, Int((shown.width * scale).rounded()))
                let height: Int = max(1, Int((shown.height * scale).rounded()))
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                let target: CGRect = CGRect(x: 0, y: 0, width: width, height: height)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(target)
                context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(page)
                return context.makeImage()
            }
        }
    }
}
#endif

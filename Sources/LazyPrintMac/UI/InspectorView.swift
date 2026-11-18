#if os(macOS)
import Foundation
import LazyPrintKit
import SwiftUI

/// The print screen's right column: the printer, then collapsible sections (`InspectorSections`) for the pages, the layout,
/// the paper and, for the photo tasks, the photos; and at its foot the Print button, which says what it does. A control that
/// cannot apply is hidden, one that conflicts with another choice is greyed out with its reason beside it. Twin of the
/// Windows inspector (`InspectorRules.cs`).
struct InspectorView: View {
    @EnvironmentObject var state: AppState

    private static let perSide = [1, 2, 4, 6, 9, 16]

    /// Opens the section the settings need (a photo layout opens Photos); kept like any section the user opened.
    static func open(for settings: PrintSettings) {
        if let id = InspectorSections.openedBy(settings) {
            UserDefaults.standard.set(true, forKey: "inspector." + id)
        }
    }

    var body: some View {
        let rules = Rules(settings: state.settings, capabilities: state.capabilities)
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    printerSection
                    pagesSection(rules)
                    layoutSection(rules)
                    paperSection(rules)
                    photosSection(rules)
                }
                .padding(14)
                .disabled(state.isBusy)
            }
            Divider()
            printButton
        }
    }

    // MARK: Sections

    private var printerSection: some View {
        InspectorSection(id: InspectorSections.printer, icon: "printer", summary: "") {
            Picker("Printer", selection: Binding(
                get: { state.selectedPrinter?.id ?? "" },
                set: { id in if !id.isEmpty { Task { await state.selectPrinter(id) } } })) {
                if state.selectedPrinter == nil {
                    Text("No printer").tag("")
                }
                ForEach(state.printers) { printer in
                    Text(printer.name).tag(printer.id)
                }
            }
            .labelsHidden()
            if let problem = state.selectedPrinter?.problems.first {
                Label("\(problem.title). \(problem.advice)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(problem.isError ? Color.red : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func pagesSection(_ rules: Rules) -> some View {
        InspectorSection(id: InspectorSections.pages, icon: "doc", summary: InspectorSections.pagesSummary(state.settings)) {
            field("Copies") {
                HStack {
                    TextField("Copies", value: Binding(get: { state.settings.copies }, set: { (count: Int) in
                        state.settings.copies = PrintCopies.clamp(count)
                    }), format: .number)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 56)
                    Stepper("Copies", value: $state.settings.copies, in: 1...PrintCopies.maxCount)
                        .labelsHidden()
                }
                if rules.showCollate {
                    Toggle("Collate", isOn: $state.settings.collate)
                }
            }
            field("Pages") {
                TextField(PrintText.pageRangeHint(pages: state.pageCount, documents: state.documents.count), text: Binding(get: { state.pageRange }, set: { state.setPageRange($0) }))
                    .textFieldStyle(.roundedBorder)
                    .help("Page numbers and ranges, for example 1-3, 5. Empty prints every page.")
                if let problem = state.pageRangeError {
                    note(problem, error: true)
                }
                Picker("Which pages", selection: $state.settings.pageSelection) {
                    Text("All pages").tag(PageSelection.all)
                    Text("Odd pages only").tag(PageSelection.odd)
                    Text("Even pages only").tag(PageSelection.even)
                }
                .labelsHidden()
                Toggle("Reverse order", isOn: $state.settings.reverseOrder)
            }
            field("Two-sided") {
                Picker("Two-sided", selection: Binding(
                    get: { (2...4).contains(state.settings.poster) ? Sides.oneSided : state.settings.booklet ? Sides.longEdge : state.settings.sides },
                    set: { state.settings.sides = $0 })) {
                    Text("Off").tag(Sides.oneSided)
                    Text("Long edge").tag(Sides.longEdge)
                    Text("Short edge").tag(Sides.shortEdge)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!rules.sidesEnabled)
                if let reason = rules.sidesReason ?? rules.sidesNote { note(reason) }
            }
        }
    }

    private func layoutSection(_ rules: Rules) -> some View {
        let printed = state.jobPlan?.plan.printedScale
        let printerMargin = PrintJobs.printerMargin(state.settings, printer: state.capabilities)
        let chosen = MarginChoices.millimetres(state.settings.margin, custom: state.settings.marginMm, printerEdge: printerMargin)
        let edge = PrintJobs.printerEdge(state.settings, printer: state.capabilities, photosOnly: state.photosOnly)
        let cutByEdge = rules.marginEnabled && (edge ?? 0) > (chosen * 10).rounded(.toNearestOrEven) / 10
        return InspectorSection(id: InspectorSections.layout, icon: "square.grid.2x2",
                                summary: InspectorSections.layoutSummary(state.settings, printedScale: printed)) {
            field("Pages per side") {
                Picker("Pages per side", selection: Binding(
                    get: { state.settings.booklet ? 2 : (Self.perSide.contains(state.settings.pagesPerSheet) ? state.settings.pagesPerSheet : 1) },
                    set: { state.settings.pagesPerSheet = $0 })) {
                    ForEach(Self.perSide, id: \.self) { count in
                        Text(count == 1 ? "1 (one per side)" : "\(count) per side").tag(count)
                    }
                }
                .labelsHidden()
                .disabled(!rules.pagesPerSideEnabled)
                if let reason = rules.pagesPerSideReason { note(reason) }
            }
            if rules.showOrientation {
                field("Orientation") {
                    Picker("Orientation", selection: $state.settings.orientation) {
                        Text("Automatic").tag(SheetOrientation.automatic)
                        Text("Portrait").tag(SheetOrientation.portrait)
                        Text("Landscape").tag(SheetOrientation.landscape)
                    }
                    .labelsHidden()
                }
            }
            Toggle("Booklet", isOn: $state.settings.booklet)
                .disabled(!rules.bookletEnabled)
            if let reason = rules.bookletReason { note(reason) }
            field("Poster") {
                Picker("Poster", selection: Binding(
                    get: { (2...4).contains(state.settings.poster) ? state.settings.poster : 0 },
                    set: { state.settings.poster = $0 })) {
                    Text("Off").tag(0)
                    ForEach(2...4, id: \.self) { count in
                        Text("\(count) \u{00D7} \(count) sheets").tag(count)
                    }
                }
                .labelsHidden()
                .disabled(!rules.posterEnabled)
                if let reason = rules.posterReason { note(reason) }
            }
            if rules.showRightToLeft { Toggle("Right to left", isOn: $state.settings.rightToLeft) }
            if rules.showBorders { Toggle("Page borders", isOn: $state.settings.pageBorders) }
            field("Scaling") {
                Picker("Scaling", selection: Binding(
                    get: { rules.scalingFitOnly && state.settings.scaling != .fill ? Scaling.fit : state.settings.scaling },
                    set: { state.settings.scaling = $0 })) {
                    if !rules.scalingFitOnly { Text("Shrink to fit").tag(Scaling.shrinkToFit) }
                    Text("Fit to page").tag(Scaling.fit)
                    if !rules.scalingFitOnly { Text("Actual size").tag(Scaling.actualSize) }
                    Text("Fill").tag(Scaling.fill)
                }
                .labelsHidden()
                .disabled(rules.poster)
                Stepper(value: $state.settings.scale, in: 10...400, step: 5) {
                    Text("\(state.settings.scale) %")
                }
                .disabled(!rules.showScale)
                .accessibilityLabel("Scale")
                .accessibilityValue("\(state.settings.scale) %")
                if rules.showScale, let printed, printed != state.settings.scale {
                    note(PrintText.printsAt(printed))
                }
            }
            field("Margins") {
                Picker("Margins", selection: $state.settings.margin) {
                    ForEach(MarginChoice.allCases, id: \.self) { choice in
                        Text(PrintText.marginLabel(choice)).tag(choice)
                    }
                }
                .labelsHidden()
                .disabled(!rules.marginEnabled)
                if let reason = rules.marginReason { note(reason) }
                if state.settings.margin == .custom {
                    MarginMmFields()
                        .disabled(!rules.marginEnabled)
                }
                if cutByEdge, let edge {
                    note(PrintText.printerEdgeNote(edge))
                } else if rules.marginEnabled, state.settings.margin == .printer, edge != nil {
                    note(PrintText.printerMarginSides(PrintJobs.area(state.settings, printer: state.capabilities, photosOnly: state.photosOnly).margins))
                }
            }
        }
    }

    private func paperSection(_ rules: Rules) -> some View {
        InspectorSection(id: InspectorSections.paper, icon: "doc.plaintext", summary: InspectorSections.paperSummary(state.settings.used(state.capabilities))) {
            field("Paper") {
                let papers = PaperSizes.choices(printer: state.capabilities, chosen: state.settings.paperId,
                                                region: Locale.current.region?.identifier)
                Picker("Paper", selection: Binding(
                    get: { papers.selected },
                    set: { id in
                        state.settings.paperId = id == PaperSizes.customId
                            ? PaperSizes.startCustom(printer: state.capabilities, chosen: state.settings.paperId,
                                                     region: Locale.current.region?.identifier)
                            : id
                    })) {
                    ForEach(papers.sections) { section in
                        if section.heading.isEmpty {
                            ForEach(section.options) { paper in
                                Text(paper.label).tag(paper.id)
                            }
                        } else {
                            Section(section.heading) {
                                ForEach(section.options) { paper in
                                    Text(paper.label).tag(paper.id)
                                }
                            }
                        }
                    }
                }
                .labelsHidden()
                if papers.selected == PaperSizes.customId { CustomPaperFields() }
                if let note = rules.paperNote { self.note(note) }
            }
            mediaField("Tray", ids: MediaChoices.sources(state.capabilities), label: MediaChoices.sourceLabel, selection: Binding(
                get: { MediaChoices.sources(state.capabilities).contains(state.settings.mediaSource) ? state.settings.mediaSource : MediaChoices.auto },
                set: { state.settings.mediaSource = $0 }))
            mediaField("Paper type", ids: MediaChoices.types(state.capabilities), label: MediaChoices.typeLabel, selection: Binding(
                get: { MediaChoices.types(state.capabilities).contains(state.settings.mediaType) ? state.settings.mediaType : MediaChoices.auto },
                set: { state.settings.mediaType = $0 }))
            field("Quality") {
                Picker("Quality", selection: Binding(
                    get: { rules.qualityEnabled ? state.settings.quality : QualityChoice.normal },
                    set: { state.settings.quality = $0 })) {
                    Text("Normal").tag(QualityChoice.normal)
                    Text("Draft").tag(QualityChoice.draft)
                    Text("Best").tag(QualityChoice.best)
                }
                .labelsHidden()
                .disabled(!rules.qualityEnabled)
                if let reason = rules.qualityReason { note(reason) }
            }
            field("Color") {
                Picker("Color", selection: Binding(
                    get: { rules.colorEnabled ? state.settings.color : ColorChoice.gray },
                    set: { state.settings.color = $0 })) {
                    Text("Color").tag(ColorChoice.color)
                    Text("Gray").tag(ColorChoice.gray)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!rules.colorEnabled)
                if let reason = rules.colorReason { note(reason) }
            }
        }
    }

    private func photosSection(_ rules: Rules) -> some View {
        InspectorSection(id: InspectorSections.photos, icon: "photo", summary: InspectorSections.photosSummary(state.settings)) {
            field("Size") {
                let sizes = PrintJobs.photoSizes(state.settings, printer: state.capabilities)
                Picker("Size", selection: Binding(
                    get: { sizes.contains { $0.id == state.settings.photoSizeId } ? state.settings.photoSizeId : "page" },
                    set: { state.settings.photoSizeId = $0 })) {
                    ForEach(sizes, id: \.id) { size in
                        Text(size.title).tag(size.id)
                    }
                }
                .labelsHidden()
            }
            Toggle("Cut marks", isOn: $state.settings.cutMarks)
        }
    }

    // MARK: Parts

    /// A picker of what the printer lists, with Automatic first; the row is left out when it lists none.
    @ViewBuilder
    private func mediaField(_ title: String, ids: [String], label: @escaping (String) -> String, selection: Binding<String>) -> some View {
        if !ids.isEmpty {
            field(title) {
                Picker(title, selection: selection) {
                    Text("Automatic").tag(MediaChoices.auto)
                    ForEach(ids, id: \.self) { id in
                        Text(label(id)).tag(id)
                    }
                }
                .labelsHidden()
            }
        }
    }

    private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.callout)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String, error: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(error ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Print says what it does; greyed out, it says why.
    private var printButton: some View {
        let reason = state.printDisabledReason
        return VStack(spacing: 6) {
            Button {
                Task { await state.print() }
            } label: {
                Label(state.printLabel, systemImage: "printer")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(reason != nil)
            .help(reason ?? "")
            .accessibilityLabel(reason == nil ? state.printLabel : "\(state.printLabel), not available: \(reason ?? "")")
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
    }

    // MARK: Rules

    /// What the inspector shows for the task and the printer (the Windows `InspectorState`).
    private struct Rules {
        var showCollate = false
        var sidesEnabled = true
        var sidesReason: String?
        var sidesNote: String?
        var pagesPerSideEnabled = true
        var pagesPerSideReason: String?
        var showRightToLeft = false
        var showBorders = false
        var showOrientation = true
        var poster = false
        var bookletEnabled = true
        var bookletReason: String?
        var posterEnabled = true
        var posterReason: String?
        var scalingFitOnly = false
        var showScale = false
        var marginEnabled = true
        var marginReason: String?
        var colorEnabled = true
        var colorReason: String?
        var qualityEnabled = true
        var qualityReason: String?
        var paperNote: String?

        init(settings s: PrintSettings, capabilities: PrinterCapabilities?) {
            let canTurn = capabilities?.sidesSupported.contains("two-sided-long-edge") == true
            // A booklet is two-sided whatever the choice says; by hand when the printer cannot turn the sheet.
            let twoSided = !(2...4).contains(s.poster) && (s.booklet || s.sides != .oneSided)
            let grayOnly = capabilities?.grayOnly == true
            let noQuality = capabilities?.noQuality == true

            let poster = (2...4).contains(s.poster)

            showCollate = s.copies > 1
            sidesEnabled = !s.booklet && !poster
            sidesReason = poster ? "Posters are one-sided" : (s.booklet ? "Booklets are two-sided" : nil)
            sidesNote = twoSided && capabilities != nil && !canTurn ? "By hand, in two passes" : nil
            pagesPerSideEnabled = !s.booklet && !poster
            pagesPerSideReason = poster ? "Set by Poster" : (s.booklet ? "Set by Booklet" : nil)
            showRightToLeft = !poster && (s.booklet || s.pagesPerSheet > 1)
            showBorders = !poster && !s.booklet && s.pagesPerSheet > 1
            showOrientation = !s.booklet
            self.poster = poster
            bookletEnabled = !poster
            bookletReason = poster ? "Set by Poster" : nil
            posterEnabled = poster || (!s.booklet && s.pagesPerSheet == 1)
            posterReason = posterEnabled ? nil : "Needs one page per side"
            // Several pages or a print size that fits fit or fill their space; Scale is for a lone page only.
            let alone = !poster && !s.booklet && s.pagesPerSheet == 1
            let lone = alone && PrintJobs.layoutOptions(s, printer: capabilities).cellSize == nil
            scalingFitOnly = !lone
            showScale = lone && (s.scaling == .shrinkToFit || s.scaling == .actualSize)
            colorEnabled = !grayOnly
            colorReason = grayOnly ? "This printer prints gray only" : nil
            qualityEnabled = !noQuality
            qualityReason = noQuality ? "Not on this printer" : nil

            if let size = PaperSizes.pointsOf(s.paperId), !PaperSizes.supports(capabilities, size) {
                paperNote = "Not listed by this printer"
            }
        }
    }
}

/// The width and height of a size typed in, in the region's unit; taken as far as the printer takes it, and shown as taken.
private struct CustomPaperFields: View {
    @EnvironmentObject private var state: AppState
    @State private var width = ""
    @State private var height = ""
    @State private var shownWidth = ""
    @State private var shownHeight = ""
    @FocusState private var focused: Bool

    var body: some View {
        let region: String? = Locale.current.region?.identifier
        HStack(spacing: 8) {
            TextField("Width", text: $width)
                .focused($focused)
                .onSubmit { commit() }
                .accessibilityLabel("Paper width")
            Text("\u{00D7}")
            TextField("Height", text: $height)
                .focused($focused)
                .onSubmit { commit() }
                .accessibilityLabel("Paper height")
            Text(PaperSizes.usesInches(region) ? "in" : "mm")
        }
        .textFieldStyle(.roundedBorder)
        .onAppear { load() }
        .onChange(of: state.settings.paperId) { _, _ in load() }
        .onChange(of: focused) { _, now in
            if !now { commit() }
        }
    }

    private func load() {
        guard let size: LayoutSize = PaperSizes.pointsOf(state.settings.paperId) else { return }
        let (w, h): (Double, Double) = PaperSizes.dimensions(size, region: Locale.current.region?.identifier)
        width = w == w.rounded() ? String(Int(w)) : String(w)
        height = h == h.rounded() ? String(Int(h)) : String(h)
        shownWidth = width
        shownHeight = height
    }

    private func commit() {
        // Tabbing through the boxes must not turn the rounded text on show into the size.
        guard width != shownWidth || height != shownHeight else { return }
        guard let w: Double = Double(width.replacingOccurrences(of: ",", with: ".")),
              let h: Double = Double(height.replacingOccurrences(of: ",", with: ".")), w > 0, h > 0 else {
            load()
            return
        }
        state.settings.paperId = PaperSizes.customSizeId(width: w, height: h, region: Locale.current.region?.identifier,
                                                         printer: state.capabilities)
        load()
    }
}

/// The custom margin typed in millimetres with a comma or a point, next to a stepper; taken to 0.01 mm and shown as taken.
private struct MarginMmFields: View {
    @EnvironmentObject private var state: AppState
    @State private var text = ""
    @State private var shown = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            TextField("Margin in millimetres", text: $text)
                .focused($focused)
                .onSubmit { commit() }
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .accessibilityLabel("Margin in millimetres, typed")
            Text("mm")
            Stepper("Margin in millimetres", value: $state.settings.marginMm,
                    in: 0...Double(MarginChoices.maxMillimetres), step: 0.1)
                .labelsHidden()
                .accessibilityLabel("Margin in millimetres")
                .accessibilityValue(PrintText.marginMillimetres(state.settings.marginMm))
        }
        .onAppear { load() }
        .onChange(of: state.settings.marginMm) { _, _ in
            if !focused { load() }
        }
        .onChange(of: focused) { _, now in
            if !now { commit() }
        }
    }

    private func load() {
        let mm: Double = state.settings.marginMm
        text = String(PrintText.marginMillimetres(mm).dropLast(3))
        shown = text
    }

    private func commit() {
        guard text != shown else { return }
        if let mm: Double = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")) {
            state.settings.marginMm = mm
        }
        load()
    }
}

/// A section of the inspector: a header that opens and closes it, with the section's icon and title, an accent dot and its
/// summary while it is closed and something differs from the default. Open or closed is kept by `@AppStorage`.
private struct InspectorSection<Content: View>: View {
    let id: String
    let icon: String
    let summary: String
    let content: Content
    @AppStorage private var open: Bool

    init(id: String, icon: String, summary: String, @ViewBuilder content: () -> Content) {
        self.id = id
        self.icon = icon
        self.summary = summary
        self.content = content()
        _open = AppStorage(wrappedValue: InspectorSections.openByDefault(id), "inspector." + id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                open.toggle()
            } label: {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: icon)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(InspectorSections.title(id))
                                .font(.headline)
                            if !open && changed {
                                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                            }
                        }
                        if !open && !summary.isEmpty {
                            Text(summary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: 4)
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summary.isEmpty ? InspectorSections.title(id) : "\(InspectorSections.title(id)), \(summary)")
            .accessibilityValue(open ? "Expanded" : "Collapsed")
            if open {
                VStack(alignment: .leading, spacing: 12) {
                    content
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
    }

    /// Something differs from the default; the photos' summary is always there and says nothing about a change.
    private var changed: Bool {
        !summary.isEmpty && id != InspectorSections.photos
    }
}
#endif

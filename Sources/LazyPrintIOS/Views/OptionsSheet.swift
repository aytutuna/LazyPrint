#if os(iOS)
import Foundation
import LazyPrintKit
import SwiftUI

/// The settings of a print as a grouped form: the sections of the Mac's inspector (`InspectorSections`) one under the
/// other, for the pages, the layout, the paper and, for the photo tasks, the photos. A control that cannot apply is
/// hidden, one that conflicts with another choice is greyed out with its reason beside it. Twin of the Windows inspector
/// (`InspectorRules.cs`) through the Mac's. Shown as a sheet that opens at half height.
struct OptionsSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    @FocusState private var copiesFocused: Bool
    @State private var exported: PdfFile?

    private static let perSide: [Int] = [1, 2, 4, 6, 9, 16]
    private static let scalings: [(String, Scaling)] = [("Shrink to fit", .shrinkToFit), ("Fit to page", .fit),
                                                        ("Actual size", .actualSize), ("Fill", .fill)]

    var body: some View {
        let rules: Rules = Rules(settings: state.settings, capabilities: state.capabilities)
        NavigationStack {
            Form {
                pagesSection(rules)
                layoutSection(rules)
                paperSection(rules)
                photosSection(rules)
                if !state.documents.isEmpty { saveSection }
            }
            .fileExporter(isPresented: Binding(get: { exported != nil }, set: { (on: Bool) in
                if !on { exported = nil }
            }), document: exported ?? PdfFile(data: Data()), contentType: .pdf, defaultFilename: state.pdfName) { (result: Result<URL, Error>) in
                if case .failure(let error) = result, (error as? CocoaError)?.code != .userCancelled {
                    state.reportSaveFailure(error)
                }
            }
            .disabled(state.isBusy)
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { copiesFocused = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("options.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Sections

    private var saveSection: some View {
        Section {
            Button("Save as PDF") {
                Task { exported = await state.pdfData().map { PdfFile(data: $0) } }
            }
            .disabled(!state.canSavePDF)
            .accessibilityIdentifier("options.savePdf")
        }
    }

    private func pagesSection(_ rules: Rules) -> some View {
        Section(InspectorSections.title(InspectorSections.pages)) {
            HStack {
                Text("Copies")
                Spacer()
                TextField("Copies", value: Binding(get: { state.settings.copies }, set: { (count: Int) in
                    state.settings.copies = PrintCopies.clamp(count)
                }), format: .number)
                .keyboardType(.numberPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 56)
                .focused($copiesFocused)
                .accessibilityIdentifier("print.copiesField")
                Stepper("Copies", value: $state.settings.copies, in: 1...PrintCopies.maxCount)
                    .labelsHidden()
                    .accessibilityIdentifier("print.copies")
            }
            if rules.showCollate {
                Toggle("Collate", isOn: $state.settings.collate)
                    .accessibilityIdentifier("print.collate")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Pages")
                    .font(.callout)
                TextField(PrintText.pageRangeHint(pages: state.pageCount, documents: state.documents.count), text: Binding(get: { state.pageRange }, set: { (text: String) in
                    state.setPageRange(text)
                }))
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .accessibilityIdentifier("print.pages")
                if let problem = state.pageRangeError {
                    note(problem, error: true)
                }
            }
            Choice(title: "Which pages", selection: Binding(
                get: { state.settings.pageSelection },
                set: { (selection: PageSelection) in state.settings.pageSelection = selection }),
                   options: [("All pages", PageSelection.all), ("Odd pages only", PageSelection.odd),
                             ("Even pages only", PageSelection.even)],
                   id: "print.pageSelection")
            Toggle("Reverse order", isOn: $state.settings.reverseOrder)
                .accessibilityIdentifier("print.reverse")
            Choice(title: "Two-sided", selection: Binding(
                get: { state.settings.layoutStyle.isPhoto || (2...4).contains(state.settings.poster) ? Sides.oneSided : state.settings.booklet ? Sides.longEdge : state.settings.sides },
                set: { (sides: Sides) in state.settings.sides = sides }),
                   options: [("Off", Sides.oneSided), ("Long edge", Sides.longEdge), ("Short edge", Sides.shortEdge)],
                   segmented: true, enabled: rules.sidesEnabled, reason: rules.sidesReason ?? rules.sidesNote,
                   id: "print.sides")
        }
    }

    private func layoutSection(_ rules: Rules) -> some View {
        Section(InspectorSections.title(InspectorSections.layout)) {
            Choice(title: "Style", selection: Binding(
                get: { state.settings.layoutStyle },
                set: { (style: LayoutStyle) in state.settings.layoutStyle = style }),
                   options: LayoutStyle.allCases.map { (style: LayoutStyle) -> (String, LayoutStyle) in (PrintText.layoutStyleTitle(style), style) },
                   id: "print.layoutStyle")
            Choice(title: "Pages per side", selection: Binding(
                get: { state.settings.booklet ? 2 : (Self.perSide.contains(state.settings.pagesPerSheet) ? state.settings.pagesPerSheet : 1) },
                set: { (count: Int) in state.settings.pagesPerSheet = count }),
                   options: Self.perSide.map { (count: Int) -> (String, Int) in (count == 1 ? "1 (one per side)" : "\(count) per side", count) },
                   enabled: rules.pagesPerSideEnabled, reason: rules.pagesPerSideReason, id: "print.perSide")
            if rules.showOrientation {
                Choice(title: "Orientation", selection: Binding(
                    get: { state.settings.orientation },
                    set: { (orientation: SheetOrientation) in state.settings.orientation = orientation }),
                       options: [("Automatic", SheetOrientation.automatic), ("Portrait", SheetOrientation.portrait),
                                 ("Landscape", SheetOrientation.landscape)],
                       id: "print.orientation")
            }
            Toggle("Booklet", isOn: $state.settings.booklet)
                .disabled(!rules.bookletEnabled)
                .accessibilityIdentifier("print.booklet")
            if let reason = rules.bookletReason { note(reason) }
            Choice(title: "Poster", selection: Binding(
                get: { (2...4).contains(state.settings.poster) ? state.settings.poster : 0 },
                set: { (count: Int) in state.settings.poster = count }),
                   options: [("Off", 0), ("2 \u{00D7} 2 sheets", 2), ("3 \u{00D7} 3 sheets", 3), ("4 \u{00D7} 4 sheets", 4)],
                   enabled: rules.posterEnabled, reason: rules.posterReason, id: "print.poster")
            if rules.showRightToLeft {
                Toggle("Right to left", isOn: $state.settings.rightToLeft)
                    .accessibilityIdentifier("print.rightToLeft")
            }
            if rules.showBorders {
                Toggle("Page borders", isOn: $state.settings.pageBorders)
                    .accessibilityIdentifier("print.borders")
            }
            Choice(title: "Scaling", selection: Binding(
                get: { rules.scalingLimited && state.settings.scaling != .fill ? Scaling.fit : state.settings.scaling },
                set: { (scaling: Scaling) in state.settings.scaling = scaling }),
                   options: rules.scalingLimited ? [("Fit to page", Scaling.fit), ("Fill", Scaling.fill)] : Self.scalings,
                   enabled: !rules.poster && !rules.photoPrints, reason: rules.scalingReason, id: "print.scaling")
            Stepper(value: $state.settings.scale, in: 10...400, step: 5) {
                LabeledContent("Scale", value: "\(state.settings.scale) %")
            }
            .disabled(rules.scalingLimited || rules.photoPrints || state.settings.scaling == .fit || state.settings.scaling == .fill)
            .accessibilityIdentifier("print.scale")
            Choice(title: "Margins", selection: Binding(
                get: { state.settings.margin },
                set: { (margin: MarginChoice) in state.settings.margin = margin }),
                   options: [("None", MarginChoice.none), ("Small, 6 mm", MarginChoice.small), ("Normal, 12 mm", MarginChoice.normal),
                             ("Custom", MarginChoice.custom)],
                   enabled: rules.marginEnabled, reason: rules.marginReason, id: "print.margins")
            if state.settings.margin == .custom {
                Stepper(value: $state.settings.marginMm, in: 0...MarginChoices.maxMillimetres) {
                    LabeledContent("Margin", value: "\(state.settings.marginMm) mm")
                }
                .disabled(!rules.marginEnabled)
                .accessibilityIdentifier("print.marginMm")
            }
        }
    }

    private func paperSection(_ rules: Rules) -> some View {
        Section(InspectorSections.title(InspectorSections.paper)) {
            let papers: PaperChoices = PaperSizes.choices(printer: state.capabilities, chosen: state.settings.paperId,
                                                          region: Locale.current.region?.identifier)
            PaperPicker(papers: papers, reason: rules.paperNote, selection: Binding(
                get: { papers.selected },
                set: { (id: String) in
                    state.settings.paperId = id == PaperSizes.customId
                        ? PaperSizes.startCustom(printer: state.capabilities, chosen: state.settings.paperId,
                                                 region: Locale.current.region?.identifier)
                        : id
                }))
            if papers.selected == PaperSizes.customId { CustomPaperFields() }
            mediaChoice("Tray", ids: MediaChoices.sources(state.capabilities), label: MediaChoices.sourceLabel, current: state.settings.mediaSource,
                        set: { (id: String) in state.settings.mediaSource = id }, id: "print.tray")
            mediaChoice("Paper type", ids: MediaChoices.types(state.capabilities), label: MediaChoices.typeLabel,
                        current: state.settings.mediaType, set: { (id: String) in state.settings.mediaType = id }, id: "print.paperType")
            Choice(title: "Quality", selection: Binding(
                get: { rules.qualityEnabled ? state.settings.quality : QualityChoice.normal },
                set: { (quality: QualityChoice) in state.settings.quality = quality }),
                   options: [("Normal", QualityChoice.normal), ("Draft", QualityChoice.draft), ("Best", QualityChoice.best)],
                   segmented: true, enabled: rules.qualityEnabled, reason: rules.qualityReason, id: "print.quality")
            Choice(title: "Color", selection: Binding(
                get: { rules.colorEnabled ? state.settings.color : ColorChoice.gray },
                set: { (color: ColorChoice) in state.settings.color = color }),
                   options: [("Color", ColorChoice.color), ("Gray", ColorChoice.gray)],
                   segmented: true, enabled: rules.colorEnabled, reason: rules.colorReason, id: "print.color")
        }
    }

    /// A menu of what the printer lists, with Automatic first; left out when it lists none (AirPrint lists nothing).
    @ViewBuilder
    private func mediaChoice(_ title: String, ids: [String], label: (String) -> String, current: String,
                             set: @escaping (String) -> Void, id: String) -> some View {
        if !ids.isEmpty {
            Choice(title: title, selection: Binding(
                get: { ids.contains(current) ? current : MediaChoices.auto },
                set: set),
                   options: [("Automatic", MediaChoices.auto)] + ids.map { (item: String) -> (String, String) in (label(item), item) },
                   id: id)
        }
    }

    private func photosSection(_ rules: Rules) -> some View {
        Section(InspectorSections.title(InspectorSections.photos)) {
            Choice(title: "Size", selection: $state.settings.photoSizeId,
                   options: PhotoSize.all.map { (size: PhotoSize) -> (String, String) in (size.title, size.id) },
                   enabled: rules.photoSizeEnabled, reason: rules.photoSizeReason, id: "print.photoSize")
            Toggle("Fill the size", isOn: $state.settings.photoFill)
                .accessibilityIdentifier("print.fill")
            Toggle("Cut marks", isOn: $state.settings.cutMarks)
                .accessibilityIdentifier("print.cutMarks")
        }
    }

    private func note(_ text: String, error: Bool = false) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(error ? Color.red : Color.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Rules

    static func grayOnly(_ capabilities: PrinterCapabilities?) -> Bool {
        capabilities.map { !$0.printColorModesSupported.isEmpty && !$0.printColorModesSupported.contains("color") } ?? false
    }

    static func noQuality(_ capabilities: PrinterCapabilities?) -> Bool {
        capabilities.map { $0.printQualitySupported.isEmpty } ?? false
    }

    /// The settings as the printer will get them: a quality or color it cannot take is the one it uses instead.
    static func used(_ settings: PrintSettings, capabilities: PrinterCapabilities?) -> PrintSettings {
        var s: PrintSettings = settings
        if noQuality(capabilities) { s.quality = .normal }
        if grayOnly(capabilities) { s.color = .gray }
        return s
    }

    /// What the form shows for the task and the printer (the Windows `InspectorState`).
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
        var photoPrints = false
        var bookletEnabled = true
        var bookletReason: String?
        var posterEnabled = true
        var posterReason: String?
        var marginEnabled = true
        var marginReason: String?
        var photoSizeEnabled = false
        var photoSizeReason: String?
        var colorEnabled = true
        var colorReason: String?
        var qualityEnabled = true
        var qualityReason: String?
        var scalingLimited = false
        var scalingReason: String?
        var paperNote: String?

        init(settings s: PrintSettings, capabilities: PrinterCapabilities?) {
            let photos: Bool = s.layoutStyle.isPhoto
            let photoPrints: Bool = s.layoutStyle == .photoPrints
            let canTurn: Bool = capabilities?.sidesSupported.contains("two-sided-long-edge") == true
            // A booklet is two-sided whatever the choice says; by hand when the printer cannot turn the sheet.
            let twoSided: Bool = !(2...4).contains(s.poster) && (s.booklet || s.sides != .oneSided)
            let grayOnly: Bool = OptionsSheet.grayOnly(capabilities)
            let noQuality: Bool = OptionsSheet.noQuality(capabilities)

            let poster: Bool = (2...4).contains(s.poster)
            let margins: Bool = Imposition.keepsMargin(PrintJobs.layoutOptions(s))

            showCollate = s.copies > 1
            sidesEnabled = !s.booklet && !poster && !photos
            sidesReason = photos ? "Photos print one-sided" : poster ? "Posters are one-sided" : (s.booklet ? "Booklets are two-sided" : nil)
            sidesNote = twoSided && !photos && capabilities != nil && !canTurn ? "By hand, in two passes" : nil
            pagesPerSideEnabled = !s.booklet && !poster && !photoPrints
            pagesPerSideReason = photoPrints ? "Set by Photo prints" : poster ? "Set by Poster" : (s.booklet ? "Set by Booklet" : nil)
            showRightToLeft = !poster && (s.booklet || s.pagesPerSheet > 1)
            showBorders = !poster && !s.booklet && s.pagesPerSheet > 1
            showOrientation = !s.booklet
            self.poster = poster
            self.photoPrints = photoPrints
            bookletEnabled = !poster && !photos
            bookletReason = photos ? "Not for photos" : poster ? "Set by Poster" : nil
            posterEnabled = !photos && (poster || (!s.booklet && s.pagesPerSheet == 1))
            posterReason = photos ? "Not for photos" : (posterEnabled ? nil : "Needs one page per side")
            marginEnabled = margins && !photos
            marginReason = photos ? "Photos print without margins" : (margins ? nil : "Not used at actual size or fill")
            scalingLimited = s.booklet || s.pagesPerSheet > 1 || poster
            scalingReason = photoPrints ? "Set by Photo prints" : (scalingLimited ? "Pages are fitted to their spaces" : nil)
            photoSizeEnabled = photoPrints
            photoSizeReason = photoPrints ? nil : "Needs the Photo prints layout"
            colorEnabled = !grayOnly
            colorReason = grayOnly ? "This printer prints gray only" : nil
            qualityEnabled = !noQuality
            qualityReason = noQuality ? "Not on this printer" : nil

            if let size: LayoutSize = PaperSizes.pointsOf(s.paperId), !PaperSizes.supports(capabilities, size) {
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
                .keyboardType(.numbersAndPunctuation)
                .onSubmit { commit() }
                .accessibilityLabel("Paper width")
            Text("\u{00D7}")
            TextField("Height", text: $height)
                .focused($focused)
                .keyboardType(.numbersAndPunctuation)
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

/// The paper menu: the sizes under their group headings, with the note under it when the printer does not list the one chosen.
private struct PaperPicker: View {
    let papers: PaperChoices
    var reason: String?
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Paper", selection: $selection) {
                ForEach(papers.sections) { (section: PaperSection) in
                    if section.heading.isEmpty {
                        ForEach(section.options) { (paper: PaperOption) in
                            Text(paper.label).tag(paper.id)
                        }
                    } else {
                        Section(section.heading) {
                            ForEach(section.options) { (paper: PaperOption) in
                                Text(paper.label).tag(paper.id)
                            }
                        }
                    }
                }
            }
            .pickerStyle(.menu)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityIdentifier("print.paper")
    }
}

/// One choice of a form: a segmented control, or a menu where the choices are many or the text is too large for segments,
/// with the reason it is greyed out or a note under it.
private struct Choice<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [(String, Value)]
    var segmented = false
    var enabled = true
    var reason: String?
    let id: String
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if segmented && !typeSize.isAccessibilitySize {
                Text(title)
                    .font(.callout)
                picker
                    .pickerStyle(.segmented)
                    .labelsHidden()
            } else {
                picker
                    .pickerStyle(.menu)
            }
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .disabled(!enabled)
        .accessibilityIdentifier(id)
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(options.indices, id: \.self) { (index: Int) in
                Text(options[index].0).tag(options[index].1)
            }
        }
    }
}
#endif

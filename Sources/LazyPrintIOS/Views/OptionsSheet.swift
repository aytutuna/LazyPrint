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

    private static let perSide: [Int] = [1, 2, 4, 6, 9, 16]

    var body: some View {
        let rules: Rules = Rules(settings: state.settings, task: state.task, capabilities: state.capabilities)
        NavigationStack {
            Form {
                pagesSection(rules)
                if rules.showLayout { layoutSection(rules) }
                paperSection(rules)
                if rules.showPhotos { photosSection(rules) }
            }
            .disabled(state.isBusy)
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("options.done")
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Sections

    private func pagesSection(_ rules: Rules) -> some View {
        Section(InspectorSections.title(InspectorSections.pages)) {
            Stepper(value: $state.settings.copies, in: 1...PrintCopies.maxCount) {
                Text("Copies: \(state.settings.copies)")
            }
            .accessibilityIdentifier("print.copies")
            if rules.showCollate {
                Toggle("Collate", isOn: $state.settings.collate)
                    .accessibilityIdentifier("print.collate")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Pages")
                    .font(.callout)
                TextField("All, or 1-3, 5", text: Binding(get: { state.pageRange }, set: { (text: String) in
                    state.setPageRange(text)
                }))
                .keyboardType(.numbersAndPunctuation)
                .autocorrectionDisabled()
                .accessibilityIdentifier("print.pages")
                if let problem = state.pageRangeError {
                    note(problem, error: true)
                }
            }
            if rules.showSides {
                Choice(title: "Two-sided", selection: Binding(
                    get: { state.settings.booklet ? Sides.longEdge : state.settings.sides },
                    set: { (sides: Sides) in state.settings.sides = sides }),
                       options: [("Off", Sides.oneSided), ("Long edge", Sides.longEdge), ("Short edge", Sides.shortEdge)],
                       segmented: true, enabled: rules.sidesEnabled, reason: rules.sidesReason ?? rules.sidesNote,
                       id: "print.sides")
            }
        }
    }

    private func layoutSection(_ rules: Rules) -> some View {
        Section(InspectorSections.title(InspectorSections.layout)) {
            Choice(title: "Pages per side", selection: Binding(
                get: { state.settings.booklet ? 2 : (Self.perSide.contains(state.settings.pagesPerSheet) ? state.settings.pagesPerSheet : 1) },
                set: { (count: Int) in state.settings.pagesPerSheet = count }),
                   options: Self.perSide.map { (count: Int) -> (String, Int) in (count == 1 ? "1 (one per side)" : "\(count) per side", count) },
                   enabled: rules.pagesPerSideEnabled, reason: rules.pagesPerSideReason, id: "print.perSide")
            Toggle("Booklet", isOn: $state.settings.booklet)
                .accessibilityIdentifier("print.booklet")
            if rules.showRightToLeft {
                Toggle("Right to left", isOn: $state.settings.rightToLeft)
                    .accessibilityIdentifier("print.rightToLeft")
            }
            if rules.showBorders {
                Toggle("Page borders", isOn: $state.settings.pageBorders)
                    .accessibilityIdentifier("print.borders")
            }
            Choice(title: "Scaling", selection: $state.settings.scaling,
                   options: [("Shrink to fit", Scaling.shrinkToFit), ("Fit to page", Scaling.fit),
                             ("Actual size", Scaling.actualSize), ("Fill", Scaling.fill)],
                   id: "print.scaling")
        }
    }

    private func paperSection(_ rules: Rules) -> some View {
        Section(InspectorSections.title(InspectorSections.paper)) {
            Choice(title: "Paper", selection: Binding(
                get: { PaperSizes.parse(state.settings.paperId) },
                set: { (paper: PaperSize) in state.settings.paperId = paper.rawValue }),
                   options: PaperSizes.displayOrder(region: Locale.current.region?.identifier).map { (paper: PaperSize) -> (String, PaperSize) in
                       (paper.label, paper)
                   },
                   reason: rules.paperNote, id: "print.paper")
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

    /// What the form shows for the task and the printer (the Windows `InspectorState`).
    private struct Rules {
        var showCollate = false
        var showSides = true
        var sidesEnabled = true
        var sidesReason: String?
        var sidesNote: String?
        var showLayout = true
        var pagesPerSideEnabled = true
        var pagesPerSideReason: String?
        var showRightToLeft = false
        var showBorders = false
        var showPhotos = false
        var photoSizeEnabled = false
        var photoSizeReason: String?
        var colorEnabled = true
        var colorReason: String?
        var qualityEnabled = true
        var qualityReason: String?
        var paperNote: String?

        init(settings s: PrintSettings, task: PrintTask?, capabilities: PrinterCapabilities?) {
            let photos: Bool = task == .photos || task == .photoSheet
            let canTurn: Bool = capabilities?.sidesSupported.contains("two-sided-long-edge") == true
            // A booklet is two-sided whatever the choice says; by hand when the printer cannot turn the sheet.
            let twoSided: Bool = s.booklet || s.sides != .oneSided
            let grayOnly: Bool = capabilities.map { !$0.printColorModesSupported.isEmpty && !$0.printColorModesSupported.contains("color") } ?? false
            let noQuality: Bool = capabilities.map { $0.printQualitySupported.isEmpty } ?? false

            showCollate = s.copies > 1
            showSides = !photos
            sidesEnabled = !s.booklet
            sidesReason = s.booklet ? "Booklets are two-sided" : nil
            sidesNote = twoSided && !photos && capabilities != nil && !canTurn ? "By hand, in two passes" : nil
            showLayout = task != .photos
            pagesPerSideEnabled = !s.booklet
            pagesPerSideReason = s.booklet ? "Set by Booklet" : nil
            showRightToLeft = s.booklet || s.pagesPerSheet > 1
            showBorders = !s.booklet && s.pagesPerSheet > 1
            showPhotos = photos
            photoSizeEnabled = task == .photos
            photoSizeReason = task == .photoSheet ? "Set by Photo sheet" : nil
            colorEnabled = !grayOnly
            colorReason = grayOnly ? "This printer prints gray only" : nil
            qualityEnabled = !noQuality
            qualityReason = noQuality ? "Not on this printer" : nil

            let paper: PaperSize = PaperSizes.parse(s.paperId)
            if paper != .auto, let capabilities, !capabilities.mediaColDatabase.isEmpty,
               let size = PaperSizes.points(paper), capabilities.match(size) == nil {
                paperNote = "Not listed by this printer"
            }
        }
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

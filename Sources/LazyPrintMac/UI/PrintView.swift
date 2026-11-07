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
    /// A task was picked from the Task menu.
    var pickTask: (PrintTask) -> Void

    private static let stagePadding: CGFloat = 24

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
                    DocumentStrip(addFiles: addFiles)
                        .padding(12)
                }
            }
            Divider()
            InspectorView()
                .frame(width: 300)
        }
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
                .disabled(state.isBusy)
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
        } label: {
            Label("Task", systemImage: "list.bullet")
        }
        .fixedSize()
        .disabled(state.isBusy)
    }

    /// The current task is the checked item; one that cannot be started says why after its title.
    private func taskItem(_ definition: TaskDefinition) -> some View {
        let availability = state.availability(of: definition.task)
        let title = availability.isAvailable ? definition.title : "\(definition.title) \u{2013} \(availability.reason ?? "")"
        let isCurrent = Binding(get: { state.task == definition.task }, set: { _ in pickTask(definition.task) })
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
            Text("Or drop PDFs and pictures anywhere in the window.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    /// The sheet, as large as the stage lets it be; its pixels follow the stage's size and the screen's.
    private var stage: some View {
        GeometryReader { geometry in
            let paper = state.jobPlan?.plan.area.paper ?? LayoutSize(width: 612, height: 792)
            let fit = min((geometry.size.width - 2 * Self.stagePadding) / paper.width,
                          (geometry.size.height - 2 * Self.stagePadding) / paper.height)
            // Whole steps of a quarter, so a small resize draws nothing.
            let wanted = min(4, max(0.5, (max(fit, 0.1) * displayScale * 4).rounded(.up) / 4))
            ZStack {
                // The system's under-page color is barely darker than the panel in Dark Mode.
                scheme == .dark ? Color(white: 0.08) : Color(nsColor: .underPageBackgroundColor)
                if let image = state.preview {
                    Image(decorative: image, scale: displayScale)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                        .padding(Self.stagePadding)
                        .accessibilityLabel("Sheet \(current.sheet + 1), \(current.back ? "back" : "front")")
                }
            }
            .onChange(of: wanted, initial: true) { _, scale in
                state.previewScale = scale
            }
        }
    }

    private var previewBar: some View {
        let now = current
        let sheet = sheets[min(now.sheet, sheets.count - 1)]
        return HStack {
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
#endif

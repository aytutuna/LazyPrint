#if os(iOS)
import LazyPrintKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where files come from: the choice of Files or Photos, then the Files app's importer or the photo library's picker.
enum FileSource {
    case choice
    case files
    case photos
}

/// The names photos from the library are kept under in the inbox: the loader tells a picture by its extension.
enum PhotoNames {
    static func make(number: Int, type: UTType?) -> String {
        "Photo \(number)." + (type?.preferredFilenameExtension ?? "jpg")
    }
}

/// The start screen: what are you printing? One tile per task of the catalog in its group, with an icon and the title. A task
/// that cannot be started is dimmed with one short line saying why. Twin of the Mac's start screen.
struct TaskStartScreen: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dynamicTypeSize) private var typeSize

    var showPrinters: () -> Void
    /// A tile was picked.
    var onPick: (PrintTask) -> Void

    private var columns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible(), spacing: 12, alignment: .top)]
            : [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)]
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    PrinterButton(action: showPrinters)
                    Text("What are you printing?")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    ForEach(TaskGroup.allCases, id: \.self) { (group: TaskGroup) in
                        let definitions: [TaskDefinition] = state.taskDefinitions.filter { $0.group == group }
                        if !definitions.isEmpty {
                            Text(group.title)
                                .font(.headline)
                                .padding(.top, 4)
                                .accessibilityAddTraits(.isHeader)
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                                ForEach(definitions, id: \.task) { (definition: TaskDefinition) in
                                    tile(definition)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .readableWidth(860)
            }
            .scrollBounceBehavior(.basedOnSize)
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle("Lazy Print")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func tile(_ definition: TaskDefinition) -> some View {
        let availability: TaskAvailability = state.availability(of: definition.task)
        let summary: String = state.summary(of: definition.task)
        let reason: String = availability.reason ?? ""
        return Button {
            onPick(definition.task)
        } label: {
            TaskTileLabel(symbol: TaskSymbols.systemImage(definition.iconKey), title: definition.title,
                          reason: availability.isAvailable ? nil : reason, isCurrent: state.task == definition.task)
        }
        .buttonStyle(TaskCardButtonStyle())
        .disabled(!availability.isAvailable || state.isBusy)
        .accessibilityLabel(Text(definition.title))
        .accessibilityHint(Text(availability.isAvailable ? "\(definition.subtitle) \(summary)."
                                : "\(definition.subtitle) Not available: \(reason)"))
        .accessibilityIdentifier("task." + definition.task.rawValue)
    }
}

/// The inside of a tile: the icon, the title (never cut), and for a task that cannot be started, one line saying why.
private struct TaskTileLabel: View {
    let symbol: String
    let title: String
    let reason: String?
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .frame(minWidth: 28, minHeight: 28)
                    .opacity(reason == nil ? 1 : 0.4)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                if isCurrent {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color("PrintFill")))
                }
            }
            Text(title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A whole-tile button: card surface, hairline border, pressed feedback.
private struct TaskCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemGroupedBackground)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(configuration.isPressed ? 0.5 : 0.22), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}

/// The choice of Files or Photos and the two pickers behind it, for the view that owns `source`. What they bring in goes
/// to `take`, as files in the inbox.
struct FileSources: ViewModifier {
    @EnvironmentObject private var state: AppState
    @Binding var source: FileSource?
    let inbox: IOSFileInbox
    let take: ([URL]) -> Void
    @State private var photos: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .confirmationDialog("Add files", isPresented: shown(.choice), titleVisibility: .visible) {
                Button("Files") { source = .files }
                    .accessibilityIdentifier("source.files")
                Button("Photos") { source = .photos }
                    .accessibilityIdentifier("source.photos")
                Button("Cancel", role: .cancel) {}
            }
            .fileImporter(isPresented: shown(.files), allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { (result: Result<[URL], Error>) in
                if case .success(let urls) = result { take(inbox.receive(urls)) }
            }
            .photosPicker(isPresented: shown(.photos), selection: $photos, matching: .images)
            .onChange(of: photos) { (_: [PhotosPickerItem], items: [PhotosPickerItem]) in
                guard !items.isEmpty else { return }
                photos = []
                Task { await receive(items) }
            }
    }

    /// True while `source` is `kind`. Closing one (the importer says so after a pick) does not clear a source another
    /// choice has set since.
    private func shown(_ kind: FileSource) -> Binding<Bool> {
        Binding(get: { source == kind }, set: { (on: Bool) in
            if !on && source == kind { source = nil }
        })
    }

    /// The photos as files in the inbox, named in the order picked.
    private func receive(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        var failed: [String] = []
        for (index, item) in items.enumerated() {
            let name: String = PhotoNames.make(number: index + 1, type: item.supportedContentTypes.first)
            // An original kept in iCloud may not come down without a network.
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                failed.append(name)
                continue
            }
            if let url = try? inbox.receive(data, named: name) {
                urls.append(url)
            } else {
                failed.append(name)
            }
        }
        // Picking the task clears the bars, so the failures are reported after it.
        if !urls.isEmpty {
            if state.task == nil { await state.startTask(.document) }
            take(urls)
        }
        if !failed.isEmpty { state.reportUnreadable(failed) }
    }
}
#endif

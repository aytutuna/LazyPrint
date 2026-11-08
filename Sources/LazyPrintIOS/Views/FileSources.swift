#if os(iOS)
import LazyPrintKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Where files come from: the Files app's importer or the photo library's picker.
enum FileSource {
    case files
    case photos
}

/// The names photos from the library are kept under in the inbox: the loader tells a picture by its extension.
enum PhotoNames {
    static func make(number: Int, type: UTType?) -> String {
        "Photo \(number)." + (type?.preferredFilenameExtension ?? "jpg")
    }
}

/// The Add files menu: Files or Photos. It sets the source straight away; a dialog in between would still be closing when
/// the picker opened, and UIKit drops a picker presented over a dismissal.
struct AddFilesMenu: View {
    let identifier: String
    let pick: (FileSource) -> Void

    var body: some View {
        Menu {
            Button {
                pick(.files)
            } label: {
                Label("Files", systemImage: "folder")
            }
            .accessibilityIdentifier("source.files")
            Button {
                pick(.photos)
            } label: {
                Label("Photos", systemImage: "photo.on.rectangle")
            }
            .accessibilityIdentifier("source.photos")
        } label: {
            Label("Add files\u{2026}", systemImage: "plus")
        }
        .accessibilityIdentifier(identifier)
    }
}

/// The two pickers behind the Add files menu, for the view that owns `source`. What they bring in goes to `take`, as
/// files in the inbox.
struct FileSources: ViewModifier {
    @EnvironmentObject private var state: AppState
    @Binding var source: FileSource?
    let inbox: IOSFileInbox
    let take: ([URL]) -> Void
    @State private var photos: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
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
    /// pick has set since.
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

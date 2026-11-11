#if os(iOS)
import ImageIO
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

    /// "Photo 2026-11-11 14.03.22.heic": the date the picture was taken.
    static func make(date: Date, type: UTType?) -> String {
        let format: DateFormatter = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Photo \(format.string(from: date))." + (type?.preferredFilenameExtension ?? "jpg")
    }

    /// The date in the picture's Exif, nil when it has none.
    static func dateTaken(in data: Data) -> Date? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String else { return nil }
        let format: DateFormatter = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return format.date(from: text)
    }

    /// The highest n of the "Photo n.ext" names, 0 when there are none. A name made from a date is not one.
    static func highest(in names: [String]) -> Int {
        names.compactMap { (name: String) -> Int? in
            guard name.hasPrefix("Photo ") else { return nil }
            let rest: Substring = name.dropFirst("Photo ".count)
            let digits: Substring = rest.prefix { $0.isNumber }
            guard rest.dropFirst(digits.count).first == "." else { return nil }
            return Int(digits)
        }.max() ?? 0
    }
}

/// The Add files menu, a plus that opens Files or Photos, and Lazy Scan when it is installed. It sets the source straight away; a dialog in
/// between would still be closing when the picker opened, and UIKit drops a picker presented over a dismissal.
struct AddFilesMenu: View {
    @EnvironmentObject private var state: AppState
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
            if state.availability(of: .scanAndPrint).isAvailable {
                Button {
                    Task { await state.startTask(.scanAndPrint) }
                } label: {
                    Label("Lazy Scan", systemImage: "doc.viewfinder")
                }
                .accessibilityIdentifier(identifier + ".lazyScan")
            }
        } label: {
            Label("Add files\u{2026}", systemImage: "plus")
                .labelStyle(.iconOnly)
                .imageScale(.large)
                .frame(minWidth: 32, minHeight: 32)
        }
        .accessibilityIdentifier(identifier)
    }
}

/// The two pickers behind the Add files menu, for the view that owns `source`. The files the importer picks go to `pick`,
/// to be copied into the inbox; the photos are put in the inbox here and go to `take` with the names of those that
/// would not come down.
struct FileSources: ViewModifier {
    @EnvironmentObject private var state: AppState
    @Binding var source: FileSource?
    let inbox: IOSFileInbox
    let pick: ([URL]) -> Void
    let take: ([URL], [String]) -> Void
    @State private var photos: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        content
            .fileImporter(isPresented: shown(.files), allowedContentTypes: [.pdf, .image, .plainText], allowsMultipleSelection: true) { (result: Result<[URL], Error>) in
                switch result {
                case .success(let urls):
                    pick(urls)
                case .failure(let error):
                    if (error as? CocoaError)?.code != .userCancelled { state.reportImportFailure(error) }
                }
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

    /// The photos as files in the inbox, named by the date taken when the picture says it, else numbered on from the
    /// highest "Photo n" in the list, in the order picked.
    private func receive(_ items: [PhotosPickerItem]) async {
        var urls: [URL] = []
        var failed: [String] = []
        var number: Int = PhotoNames.highest(in: state.documents.map { $0.loaded.name })
        await state.whileAddingFiles {
            for item in items {
                let type: UTType? = item.supportedContentTypes.first
                // An original kept in iCloud may not come down without a network.
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    number += 1
                    failed.append(PhotoNames.make(number: number, type: type))
                    continue
                }
                let name: String
                if let taken = PhotoNames.dateTaken(in: data) {
                    name = PhotoNames.make(date: taken, type: type)
                } else {
                    number += 1
                    name = PhotoNames.make(number: number, type: type)
                }
                if let url = try? inbox.receive(data, named: name) {
                    urls.append(url)
                } else {
                    failed.append(name)
                }
            }
        }
        take(urls, failed)
    }
}
#endif

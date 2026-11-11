#if os(iOS)
import Combine
import LazyPrintKit
import QuickLook
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The app's window: the Print screen, with Jobs in a panel that slides in from the left. The printer in use is a button at
/// the top of Print, which opens the printers; the error bar and the bar after a job sit at the bottom. Also the sheets that hang off the state
/// (the printers, the troubleshooter, the two-sided card), the share sheet and Quick Look the file actions ask for, the
/// certificate question, and the files that come in: from the Add files menu (Files and Photos), from Open In and the share sheet
/// (`.onOpenURL`), and the one a UI test hands the app at launch (`-openFixture`). A `lazyprint:` URL with `handoff` brings
/// the files Lazy Scan left in the shared folder, a `lazyprint://pair?` one opens My computer with that code; any other
/// only brings the app forward.
public struct IOSRootView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fileActions: IOSFileActions
    @Environment(\.scenePhase) private var scenePhase
    private let airPrint: IOSPrinterSystem?
    private let inbox: IOSFileInbox
    private let fixture: IOSLaunchFixture?
    private let companion: IOSCompanionBrowser?

    @State private var showJobs = false
    @State private var source: FileSource?
    @State private var showPrinters = false
    @State private var showTroubleshooter = false
    /// The text of a lazyprint://pair link that was opened, until My computer takes it.
    @State private var pairingLink: String?
    /// The last files being opened: the next wait for them, so files that arrive one after the other keep their order.
    @State private var opening: Task<Void, Never>?

    /// `airPrint` is nil where the AirPrint printer picker is not offered (the demo printer alone); `companion` is nil where
    /// the computers on the network are not looked for.
    public init(fileActions: IOSFileActions, airPrint: IOSPrinterSystem?, inbox: IOSFileInbox, fixture: IOSLaunchFixture?,
                companion: IOSCompanionBrowser? = nil) {
        _fileActions = ObservedObject(wrappedValue: fileActions)
        self.airPrint = airPrint
        self.inbox = inbox
        self.fixture = fixture
        self.companion = companion
    }

    public var body: some View {
        ZStack(alignment: .leading) {
            PrintScreen(addFiles: { (picked: FileSource) in source = picked }, pickTask: { (task: PrintTask) in
                Task { await start(task) }
            }, showPrinters: { showPrinters = true }, showJobs: { showJobs = true })
            JobsPanel(isOpen: $showJobs)
        }
        // Outside the panel's dimming, so what a job in the panel says can be read and acted on.
        .modifier(Bars(showJobs: $showJobs, showTroubleshooter: $showTroubleshooter))
        .modifier(FileSources(source: $source, inbox: inbox, pick: { (urls: [URL]) in receive(urls) }, take: take))
        .onDrop(of: [.pdf, .image], isTargeted: nil, perform: drop)
        .background {
            // The shortcut needs a button in the view tree; this one is never seen or tapped.
            Button("Add files") { source = .files }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(state.isBusy || state.isAddingFiles)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .sheet(isPresented: $showPrinters) {
            PrintersScreen(airPrint: airPrint, companion: companion, pairingLink: $pairingLink)
        }
        .sheet(isPresented: $showTroubleshooter) {
            TroubleshooterScreen()
        }
        .sheet(isPresented: Binding(get: { state.duplexCard != nil }, set: { (_: Bool) in })) {
            DuplexSheet()
        }
        .sheet(item: $fileActions.shareRequest) { (request: ShareRequest) in
            ActivityView(items: request.urls, onDone: { fileActions.shareRequest = nil })
        }
        .quickLookPreview($fileActions.previewURL)
        .printCertificateAlert(state)
        // Files from Open In and the share sheet arrive here, Lazy Scan's hand-off address and a pairing link; any other
        // lazyprint: URL only brings the app forward.
        .onOpenURL { (url: URL) in
            if let id = LazyPrintUrl.parseHandoff(url.absoluteString) {
                receiveHandoff(id)
            } else if PairingScannerView.isPairingCode(url.absoluteString) {
                pairingLink = url.absoluteString
                showJobs = false
                showPrinters = true
            } else if url.isFileURL {
                receive([url], delivered: true)
            }
        }
        // The printers are read, and read again, only while the app is in front.
        .onChange(of: scenePhase, initial: true) { (_: ScenePhase, phase: ScenePhase) in
            state.setActive(phase == .active)
            if phase == .active { receiveShared() }
        }
        // After time in the background the search may have failed or gone stale, so it starts again. The scene goes
        // background, inactive, active on its way back, so the change of phase cannot tell.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { (_: Notification) in
            Task { await state.refreshNetwork() }
        }
        // A sheet in the way would keep the card, which holds a half-printed job, from showing.
        .onChange(of: state.duplexCard != nil) { (_: Bool, shown: Bool) in
            if shown {
                showPrinters = false
                showTroubleshooter = false
                closeFileViews()
            }
        }
        // The certificate question is shown by the printers, the card and this view. What cannot hold an alert is closed;
        // the printers and the card stay, since they show it themselves and the printer was chosen there.
        .onChange(of: state.certificateRequest != nil) { (_: Bool, asked: Bool) in
            if asked {
                showTroubleshooter = false
                source = nil
                closeFileViews()
            }
        }
        .task {
            await state.restoreBacks()
        }
        .task {
            guard let fixture, let url = try? inbox.receive(fixture.data, named: fixture.name) else { return }
            take([url], [])
        }
    }

    private func closeFileViews() {
        fileActions.shareRequest = nil
        fileActions.previewURL = nil
    }

    // MARK: Files and tasks

    /// A task was picked from the Task menu: its settings are applied, and a task that starts with files asks for them,
    /// unless some are there already; cancelling the picker leaves the empty Print screen. The test page prints at once,
    /// and its result shows in the bars. The photo tasks open the photo library, the others the Files app.
    private func start(_ task: PrintTask) async {
        await state.startTask(task)
        guard state.task == task, TaskCatalog.definition(task).opensFiles else { return }
        if state.documents.isEmpty {
            source = task == .photos || task == .photoSheet ? .photos : .files
        }
    }

    /// Copies the files the importer and Open In hand over into the inbox, then takes them. `delivered` files came from
    /// Open In: the original is removed from the app's Inbox folder once its copy is made, and kept when the copy failed.
    private func receive(_ urls: [URL], delivered: Bool = false) {
        let before: Task<Void, Never>? = opening
        opening = Task {
            await before?.value
            var received: (copies: [URL], failed: [String]) = (copies: [], failed: [])
            await state.whileAddingFiles {
                received = await inbox.receive(urls)
            }
            if delivered {
                inbox.discardDelivered(urls, failed: received.failed)
            }
            await open(received.copies, notAdded: received.failed)
        }
    }

    /// Files dropped on the window, taken as data: the file a provider hands over is gone when its callback returns.
    private func drop(_ providers: [NSItemProvider]) -> Bool {
        let wanted: [(provider: NSItemProvider, type: UTType)] = providers.compactMap { (provider: NSItemProvider) -> (provider: NSItemProvider, type: UTType)? in
            provider.registeredContentTypes.first { $0.conforms(to: .pdf) || $0.conforms(to: .image) }.map { (provider: provider, type: $0) }
        }
        guard !wanted.isEmpty, !state.isBusy, !state.isAddingFiles else { return false }
        Task {
            var urls: [URL] = []
            var failed: [String] = []
            await state.whileAddingFiles {
                for item in wanted {
                    let ext: String = item.type.preferredFilenameExtension ?? "jpg"
                    var name: String = item.provider.suggestedName ?? "Dropped file"
                    if !name.lowercased().hasSuffix("." + ext) { name += "." + ext }
                    let data: Data? = await withCheckedContinuation { (done: CheckedContinuation<Data?, Never>) in
                        _ = item.provider.loadDataRepresentation(forTypeIdentifier: item.type.identifier) { (data: Data?, _: Error?) in
                            done.resume(returning: data)
                        }
                    }
                    if let data, let url = try? inbox.receive(data, named: name) {
                        urls.append(url)
                    } else {
                        failed.append(name)
                    }
                }
            }
            take(urls, failed)
        }
        return true
    }

    /// Copies the files Lazy Scan handed over into the inbox and clears its folder, so they are not kept twice. When a
    /// file did not copy the folder stays until the old hand-offs are removed; the files that did copy are in the job.
    /// While a job runs they wait, and are added once it is over.
    private func receiveHandoff(_ id: UUID) {
        let before: Task<Void, Never>? = opening
        opening = Task {
            await before?.value
            // Adding files or saying one is missing would replace the status and error of the job that is running.
            _ = await state.$isBusy.values.first { (busy: Bool) -> Bool in !busy }
            guard let urls = IOSFileInbox.handoffFiles(id) else {
                state.reportMissingHandoff()
                return
            }
            var received: (copies: [URL], failed: [String]) = (copies: [], failed: [])
            await state.whileAddingFiles {
                received = await inbox.receive(urls)
            }
            if received.failed.isEmpty { IOSFileInbox.removeHandoff(id) }
            await open(received.copies, notAdded: received.failed)
        }
    }

    /// Takes what the share extension left in the App Group, one folder per share. A folder is removed once it is read, so
    /// a file that failed to copy is reported rather than tried again on every return.
    private func receiveShared() {
        let folders: [URL] = IOSFileInbox.sharedFolders()
        if folders.isEmpty { return }
        let before: Task<Void, Never>? = opening
        opening = Task {
            await before?.value
            _ = await state.$isBusy.values.first { (busy: Bool) -> Bool in !busy }
            for folder in folders {
                let urls: [URL] = IOSFileActions.files(in: folder)
                var received: (copies: [URL], failed: [String]) = (copies: [], failed: [])
                await state.whileAddingFiles {
                    received = await inbox.receive(urls)
                }
                try? FileManager.default.removeItem(at: folder)
                await open(received.copies, notAdded: received.failed)
            }
        }
    }

    /// Takes files already in the inbox. The names in `notAdded` are files that could not be brought in; they are reported
    /// with the ones the loader cannot read.
    private func take(_ urls: [URL], _ notAdded: [String]) {
        let before: Task<Void, Never>? = opening
        opening = Task {
            await before?.value
            await open(urls, notAdded: notAdded)
        }
    }

    /// Opens the files and shows the Print screen. Files that come with no task are added with the settings as they are.
    private func open(_ urls: [URL], notAdded: [String]) async {
        let files: [URL] = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        if files.isEmpty {
            if !notAdded.isEmpty { state.reportUnreadable(notAdded) }
            return
        }
        let unreadable: [(name: String, reason: String)] = notAdded.map { (name: String) -> (name: String, reason: String) in
            (name: name, reason: DocumentText.unreadable)
        }
        await state.whileAddingFiles {
            await state.addFiles(files, alsoNotAdded: unreadable)
        }
        if !state.documents.isEmpty { showJobs = false }
    }
}

/// Jobs, sliding in from the left over the dimmed Print screen. A tap beside it or a drag to the left closes it.
private struct JobsPanel: View {
    @Binding var isOpen: Bool
    @GestureState private var drag: CGFloat = 0

    var body: some View {
        GeometryReader { (geometry: GeometryProxy) in
            ZStack(alignment: .leading) {
                if isOpen {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .onTapGesture { isOpen = false }
                        .accessibilityHidden(true)
                        .transition(.opacity)
                    JobsScreen(close: { isOpen = false })
                        .frame(width: min(360, geometry.size.width * 0.85))
                        .background(Color(uiColor: .systemGroupedBackground).shadow(color: .black.opacity(0.3), radius: 8).ignoresSafeArea())
                        .offset(x: min(0, drag))
                        .gesture(DragGesture(minimumDistance: 20).updating($drag) { (value: DragGesture.Value, offset: inout CGFloat, _: inout Transaction) in
                            offset = value.translation.width
                        }.onEnded { (value: DragGesture.Value) in
                            if value.predictedEndTranslation.width < -80 { isOpen = false }
                        })
                        .accessibilityAddTraits(.isModal)
                        .accessibilityAction(.escape) { isOpen = false }
                        .transition(.move(edge: .leading))
                }
            }
        }
        .allowsHitTesting(isOpen)
        .animation(.easeOut(duration: 0.25), value: isOpen)
        .animation(.easeOut(duration: 0.15), value: drag)
    }
}

/// The error bar and the bar after a job, at the bottom of the window.
private struct Bars: ViewModifier {
    @EnvironmentObject private var state: AppState
    @Binding var showJobs: Bool
    @Binding var showTroubleshooter: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if let error = state.error {
                    errorBar(error)
                }
                if let sent = state.sentMessage {
                    sentBar(sent)
                }
            }
        }
    }

    private func errorBar(_ error: AppError) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: error.isNotice ? "info.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(error.isNotice ? Color.secondary : Color.red)
                    .accessibilityHidden(true)
                (Text(error.title).fontWeight(.semibold) + Text("  ") + Text(error.detail))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("bar.error")
                Spacer(minLength: 8)
                Button {
                    state.dismissError()
                } label: {
                    Image(systemName: "xmark")
                        .frame(minWidth: 32, minHeight: 32)
                }
                .accessibilityLabel("Dismiss")
                .accessibilityIdentifier("bar.error.dismiss")
            }
            if error.suggestsTroubleshooter {
                Button("Troubleshoot") { showTroubleshooter = true }
                    .accessibilityIdentifier("bar.error.troubleshoot")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(error.isNotice ? Color.secondary.opacity(0.12) : Color.red.opacity(0.12), ignoresSafeAreaEdges: [])
        .background(.bar, ignoresSafeAreaEdges: [])
    }

    private func sentBar(_ sent: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            Text(sent)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("bar.sent")
            Spacer(minLength: 8)
            if !showJobs {
                Button("Jobs") { showJobs = true }
                    .accessibilityIdentifier("bar.sent.jobs")
            }
            Button {
                state.dismissSent()
            } label: {
                Image(systemName: "xmark")
                    .frame(minWidth: 32, minHeight: 32)
            }
            .accessibilityLabel("Dismiss")
            .accessibilityIdentifier("bar.sent.dismiss")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.green.opacity(0.12), ignoresSafeAreaEdges: [])
        .background(.bar, ignoresSafeAreaEdges: [])
    }
}

/// The system share sheet (`UIActivityViewController`) for files, in a SwiftUI sheet. `onDone` runs when the user has shared
/// or cancelled, so the sheet closes with it.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [URL]
    let onDone: @MainActor () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let activityItems: [Any] = items
        let controller: UIActivityViewController = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        // The demo printer's pictures are shared; saving them to the photo library would need a permission text.
        controller.excludedActivityTypes = [.saveToCameraRoll]
        let done: @MainActor () -> Void = onDone
        controller.completionWithItemsHandler = { (_: UIActivity.ActivityType?, _: Bool, _: [Any]?, _: Error?) -> Void in
            Task { @MainActor in
                done()
            }
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

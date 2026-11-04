#if os(iOS)
import LazyPrintKit
import QuickLook
import SwiftUI
import UIKit

enum RootTab: Hashable {
    case start
    case print
    case jobs
}

/// The app's window: Start, Print and Jobs in a tab bar. The printer in use is a button at the top of Start and Print, which
/// opens the printers; the error bar and the bar after a job sit above the tab bar. Also the sheets that hang off the state
/// (the printers, the troubleshooter, the two-sided card), the share sheet and Quick Look the file actions ask for, the
/// certificate question, and the files that come in: from the Files and Photos choice, from Open In and the share sheet
/// (`.onOpenURL`), and the one a UI test hands the app at launch (`-openFixture`). A `lazyprint:` URL only brings the app
/// forward.
public struct IOSRootView: View {
    @EnvironmentObject private var state: AppState
    @ObservedObject private var fileActions: IOSFileActions
    @Environment(\.scenePhase) private var scenePhase
    private let airPrint: IOSPrinterSystem?
    private let inbox: IOSFileInbox
    private let fixture: IOSLaunchFixture?
    private let companion: IOSCompanionBrowser?

    @State private var tab: RootTab = .start
    @State private var source: FileSource?
    @State private var showPrinters = false
    @State private var showTroubleshooter = false
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
        TabView(selection: $tab) {
            TaskStartScreen(showPrinters: { showPrinters = true }, onPick: { (task: PrintTask) in
                Task { await start(task) }
            })
            .modifier(Bars(tab: $tab, showTroubleshooter: $showTroubleshooter))
            .tabItem { Label("Start", systemImage: "square.grid.2x2") }
            .tag(RootTab.start)
            PrintScreen(addFiles: { source = .choice }, changeTask: { tab = .start }, showPrinters: { showPrinters = true })
                .modifier(Bars(tab: $tab, showTroubleshooter: $showTroubleshooter))
                .tabItem { Label("Print", systemImage: "printer") }
                .tag(RootTab.print)
            JobsScreen()
                .modifier(Bars(tab: $tab, showTroubleshooter: $showTroubleshooter))
                .tabItem { Label("Jobs", systemImage: "clock.arrow.circlepath") }
                .tag(RootTab.jobs)
        }
        .modifier(FileSources(source: $source, inbox: inbox, take: take))
        .sheet(isPresented: $showPrinters) {
            PrintersScreen(airPrint: airPrint, companion: companion)
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
        // Files from Open In and the share sheet arrive here; a lazyprint: URL only brings the app forward.
        .onOpenURL { (url: URL) in
            guard url.isFileURL else { return }
            let received: [URL] = inbox.receive([url])
            take(received)
            // A file the inbox could not copy was passed on as it is, and is the one that gets printed.
            if received != [url] { inbox.discardDelivered(url) }
        }
        // The printers are read, and read again, only while the app is in front.
        .onChange(of: scenePhase, initial: true) { (_: ScenePhase, phase: ScenePhase) in
            state.setActive(phase == .active)
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
            guard let fixture, let url = try? inbox.receive(fixture.data, named: fixture.name) else { return }
            take([url])
        }
    }

    private func closeFileViews() {
        fileActions.shareRequest = nil
        fileActions.previewURL = nil
    }

    // MARK: Files and tasks

    /// A tile was picked: its settings are applied, and a task that starts with files opens the Print screen and asks for
    /// them, unless some are there already; cancelling the choice leaves the empty Print screen. The test page prints at
    /// once and stays here, where its result shows in the bars. The photo tasks go straight to the photo library.
    private func start(_ task: PrintTask) async {
        await state.startTask(task)
        guard state.task == task, TaskCatalog.definition(task).opensFiles else { return }
        tab = .print
        if state.documents.isEmpty {
            source = task == .photos || task == .photoSheet ? .photos : .choice
        }
    }

    /// Opens the files and shows the Print screen. Files that come before any task was picked start the plain document
    /// task, so there is something to lay them out by.
    private func take(_ urls: [URL]) {
        let files: [URL] = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        let before: Task<Void, Never>? = opening
        opening = Task {
            await before?.value
            if state.task == nil { await state.startTask(.document) }
            await state.addFiles(files)
            if !state.documents.isEmpty { tab = .print }
        }
    }
}

/// The error bar and the bar after a job, above the tab bar.
private struct Bars: ViewModifier {
    @EnvironmentObject private var state: AppState
    @Binding var tab: RootTab
    @Binding var showTroubleshooter: Bool

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                if state.isBusy && tab != .print {
                    busyBar
                }
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

    /// A job that was not started from the Print screen (the test page): what it is doing, and a way to stop it.
    private var busyBar: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(state.status)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("bar.busy")
            Spacer(minLength: 8)
            Button("Cancel") { state.cancelJob() }
                .accessibilityIdentifier("bar.busy.cancel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
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
            if tab != .jobs {
                Button("Jobs") { tab = .jobs }
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

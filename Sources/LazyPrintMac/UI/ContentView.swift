#if os(macOS)
import AppKit
import LazyPrintKit
import SwiftUI
import UniformTypeIdentifiers

enum ContentTab: String, Hashable {
    case print
    case jobs
}

/// Files and phone batches that came while a job ran, taken once it has ended. Kept outside the window, which can be closed
/// and reopened meanwhile.
@MainActor
enum PendingOpens {
    enum Item {
        case files([URL], refused: [(name: String, reason: String)])
        case batch(String, startNew: Bool)
    }

    static var items: [Item] = []
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var host: MacCompanionHosting

    @State private var tab: ContentTab
    @State private var showImporter = false
    @State private var showTroubleshooter = false
    @State private var showAddPrinter = false
    @State private var showPhone = false
    /// Add by address was asked in the troubleshooter: the add sheet opens once that one has closed.
    @State private var addPrinterAfterTroubleshooter = false
    /// Files are dragged over the window: it says where they go.
    @State private var dropTargeted = false
    @State private var queuedBatch: String?
    /// The last file being opened: the next waits for it, so several files from Open With keep their order.
    @State private var opening: Task<Void, Never>?

    static let tabKey = "selectedTab"

    /// A tab given here wins over the one kept from the last run.
    init(tab: ContentTab? = nil) {
        let kept = UserDefaults.standard.string(forKey: ContentView.tabKey).flatMap(ContentTab.init(rawValue:))
        _tab = State(initialValue: tab ?? kept ?? .print)
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(showTroubleshooter: $showTroubleshooter, showAddPrinter: $showAddPrinter, showPhone: $showPhone)
                .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 320)
        } detail: {
            // The tab switcher lives in the content, not the toolbar: toolbar `.principal` items merge the title bar on
            // newer macOS and push the sidebar under the traffic-light buttons.
            VStack(spacing: 0) {
                bars
                if state.duplexCard != nil {
                    DuplexCardView()
                    Divider()
                }
                HStack {
                    Picker("View", selection: $tab) {
                        Text("Print").tag(ContentTab.print)
                        Text("Jobs").tag(ContentTab.jobs)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 300)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
                Divider()
                switch tab {
                case .print:
                    PrintView(addFiles: { showImporter = true }, pickTask: { task in
                        Task { await start(task) }
                    })
                case .jobs:
                    JobsView()
                }
                Divider()
                StatusBar()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            take(urls)
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .overlay {
            if dropTargeted {
                Text(state.isBusy ? "Drop to add when the job ends" : "Drop to add to the print")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
            }
        }
        // Below this the layout cannot stay usable.
        .frame(minWidth: 760, minHeight: 520)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image, .plainText], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { _ = take(urls) }
        }
        .sheet(isPresented: $showTroubleshooter, onDismiss: {
            if addPrinterAfterTroubleshooter {
                addPrinterAfterTroubleshooter = false
                showAddPrinter = true
            }
        }) {
            TroubleshooterView(onAddByAddress: { addPrinterAfterTroubleshooter = true })
                .environmentObject(state)
        }
        .sheet(isPresented: $showAddPrinter) {
            AddPrinterView()
                .environmentObject(state)
        }
        .sheet(isPresented: $showPhone) {
            PhoneView()
                .environmentObject(state)
                .environmentObject(host)
        }
        .printCertificateAlert(state)
        .passwordAlert(state)
        .focusedSceneValue(\.sheetOpen, showTroubleshooter || showAddPrinter || showPhone)
        // Files from Open With, the Dock icon and `open` arrive here, and lazyprint:open?file=... from Lazy Scan.
        .onOpenURL { url in
            if url.isFileURL {
                _ = take([url])
            } else {
                NSApp.activate(ignoringOtherApps: true)
                let (readable, refused) = ContentView.readable(ContentView.files(in: url))
                _ = take(readable, refused: refused.map { (name: $0.lastPathComponent, reason: ContentView.addressNotOpened) })
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .addFilesRequested)) { _ in
            if !state.isBusy { showImporter = true }
        }
        .onChange(of: state.isBusy) { _, busy in
            if !busy { takeQueued() }
        }
        .onChange(of: tab) { _, tab in
            UserDefaults.standard.set(tab.rawValue, forKey: ContentView.tabKey)
        }
        .onReceive(NotificationCenter.default.publisher(for: .tabRequested)) { note in
            if let raw = note.object as? String, let requested = ContentTab(rawValue: raw) { tab = requested }
        }
        .onAppear {
            state.phoneWindowRequested = { showPhone = true }
            if !state.isBusy { takeQueued() }
        }
        // A problem with the cloud folder is also said here, where it is seen without the phone sheet open.
        .onChange(of: host.syncFolderProblem) { _, problem in
            state.reportSyncProblem(problem)
        }
        // Open-file and URL events go to this window, not to a new one.
        .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
    }

    // MARK: Bars

    /// The error bar and the bar after a job, above the tabs.
    @ViewBuilder
    private var bars: some View {
        if let error = state.error {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: error.isNotice ? "info.circle" : "exclamationmark.triangle.fill")
                    .foregroundStyle(error.isNotice ? Color.secondary : Color.red)
                (Text(error.title).fontWeight(.semibold) + Text("  ") + Text(error.detail))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if error.suggestsTroubleshooter {
                    Button("Troubleshoot") { showTroubleshooter = true }
                        .help("Opens the troubleshooter: checks what stops printers from appearing or printing")
                }
                Button {
                    state.dismissError()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(error.isNotice ? Color.secondary.opacity(0.12) : Color.red.opacity(0.12))
            .accessibilityElement(children: .combine)
            Divider()
        }
        if let sent = state.sentMessage {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(.green)
                Text(sent)
                Spacer(minLength: 8)
                if tab != .jobs {
                    Button("Jobs") { tab = .jobs }
                }
                Button {
                    state.dismissSent()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.green.opacity(0.12))
            .accessibilityElement(children: .combine)
            Divider()
        }
        if let batch = state.phoneBatches.first {
            PhoneBarView(batch: batch,
                         queued: queuedBatch == batch.id,
                         add: { usePhoneBatch(batch.id, startNew: false) },
                         startNew: { usePhoneBatch(batch.id, startNew: true) },
                         dismiss: { state.dismissBatch(batch.id) })
            Divider()
        }
    }

    // MARK: Files and tasks

    /// Takes what came while a job ran, in the order it came.
    private func takeQueued() {
        let waiting = PendingOpens.items
        PendingOpens.items = []
        queuedBatch = nil
        for item in waiting {
            switch item {
            case .files(let urls, let refused): _ = take(urls, refused: refused)
            case .batch(let id, let startNew): usePhoneBatch(id, startNew: startNew)
            }
        }
    }

    /// The files a lazyprint: URL asks to add: absolute paths only, as `LazyPrintUrl` parses them.
    static func files(in url: URL) -> [URL] {
        LazyPrintUrl.parse(url.absoluteString).map { URL(fileURLWithPath: $0) }
    }

    static let addressNotOpened = "It could not be opened from the address the other app sent. If the file is there, drag it onto this window or open it with Lazy Print from Finder."

    /// Splits the files a lazyprint: address names into those this app can open and those it cannot. A sandboxed app is
    /// granted the files the system opens for it, not a path another app names, so the second kind is expected.
    static func readable(_ files: [URL]) -> (readable: [URL], refused: [URL]) {
        var readable: [URL] = []
        var refused: [URL] = []
        for file in files {
            if let handle = try? FileHandle(forReadingFrom: file) {
                try? handle.close()
                readable.append(file)
            } else {
                refused.append(file)
            }
        }
        return (readable, refused)
    }

    /// Takes the files of the oldest batch from a phone into the job, or into a new one, and shows the print tab.
    private func usePhoneBatch(_ id: String, startNew: Bool) {
        if state.isBusy {
            PendingOpens.items.append(.batch(id, startNew: startNew))
            queuedBatch = id
            return
        }
        let before = opening
        opening = Task {
            await state.whileAddingFiles {
                await before?.value
                await state.takeBatch(id, startNew: startNew)
            }
            if !state.documents.isEmpty {
                if let task = state.task { InspectorView.open(for: task) }
                tab = .print
            }
        }
    }

    /// A task was picked from the Task menu: its settings are applied, and a task that starts with files shows the print tab
    /// and asks for them, unless some are there already; cancelling the panel leaves the empty print tab. The test page
    /// prints at once, and its result shows in the bars.
    private func start(_ task: PrintTask) async {
        await state.startTask(task)
        guard state.task == task, TaskCatalog.definition(task).opensFiles else { return }
        InspectorView.open(for: task)
        tab = .print
        if state.documents.isEmpty { showImporter = true }
    }

    /// Opens the files and shows the print tab. Files that come with no task are added with the settings as they are.
    /// Folders are left, and said so when they were all there was; any file is taken, and the loader says why one is not a
    /// PDF or a picture.
    private func take(_ urls: [URL], refused: [(name: String, reason: String)] = []) -> Bool {
        let files = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        guard !files.isEmpty else {
            let folders = urls.filter { $0.isFileURL && $0.hasDirectoryPath }
            // Nothing to add, but what could not be opened is still said, in one bar.
            let notAdded: [(name: String, reason: String)] = folders.map { (name: $0.lastPathComponent, reason: DocumentText.notSupported) } + refused
            if !notAdded.isEmpty { state.reportNotAdded(notAdded) }
            return false
        }
        if state.isBusy {
            PendingOpens.items.append(.files(urls, refused: refused))
            return true
        }
        // Files from the file importer are scoped to this app; each document keeps the access for as long as it lives.
        let started = files.filter { $0.startAccessingSecurityScopedResource() }.map { ScopedAccess(url: $0) }
        let before = opening
        opening = Task {
            await state.whileAddingFiles {
                await before?.value
                await state.addFiles(files, alsoNotAdded: refused)
            }
            state.holdAccess(started)
            if !state.documents.isEmpty {
                if let task = state.task { InspectorView.open(for: task) }
                tab = .print
            }
        }
        return true
    }
}

/// The slim bar under the content: the status line (six words at most; VoiceOver reads the whole sentence), a busy spinner
/// and Cancel while a job goes out.
private struct StatusBar: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 8) {
            Text(state.status)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityLabel(Text(state.statusAccessible))
            if state.isBusy {
                ProgressView()
                    .controlSize(.small)
                Button("Cancel") { state.cancelJob() }
                    .controlSize(.small)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}
#endif

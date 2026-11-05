#if os(macOS)
import AppKit
import LazyPrintKit
import SwiftUI
import UniformTypeIdentifiers

enum ContentTab: Hashable {
    case start
    case print
    case jobs
}

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var host: MacCompanionHosting

    @State private var tab: ContentTab
    @State private var showImporter = false
    @State private var showTroubleshooter = false
    @State private var showAddPrinter = false
    @State private var showPhone = false
    /// Files are dragged over the window: it says where they go.
    @State private var dropTargeted = false
    /// The last file being opened: the next waits for it, so several files from Open With keep their order.
    @State private var opening: Task<Void, Never>?

    init(tab: ContentTab = .start) {
        _tab = State(initialValue: tab)
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
                HStack {
                    Picker("View", selection: $tab) {
                        Text("Start").tag(ContentTab.start)
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
                case .start:
                    TaskStartView { task in
                        Task { await start(task) }
                    }
                case .print:
                    PrintView(addFiles: { showImporter = true }, changeTask: { tab = .start })
                case .jobs:
                    JobsView()
                }
                Divider()
                StatusBar()
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard !state.isBusy else { return false }
            return take(urls)
        } isTargeted: { targeted in
            dropTargeted = targeted
        }
        .overlay {
            if dropTargeted && !state.isBusy {
                Text("Drop to add to the print")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
            }
        }
        // Below this the layout cannot stay usable.
        .frame(minWidth: 900, minHeight: 600)
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.pdf, .image], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { _ = take(urls) }
        }
        .sheet(isPresented: $showTroubleshooter) {
            TroubleshooterView(onAddByAddress: { showAddPrinter = true })
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
        .sheet(isPresented: Binding(get: { state.duplexCard != nil }, set: { _ in })) {
            DuplexSheet()
                .environmentObject(state)
        }
        .printCertificateAlert(state)
        // Files from Open With, the Dock icon and `open` arrive here, and lazyprint:open?file=... from Lazy Scan.
        .onOpenURL { url in
            if url.isFileURL {
                _ = take([url])
            } else {
                NSApp.activate(ignoringOtherApps: true)
                _ = take(ContentView.files(in: url))
            }
        }
        .onAppear { state.phoneWindowRequested = { showPhone = true } }
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
            PhoneBarView(batch: batch, busy: state.isBusy,
                         add: { usePhoneBatch(batch.id, startNew: false) },
                         startNew: { usePhoneBatch(batch.id, startNew: true) },
                         dismiss: { state.dismissBatch(batch.id) })
            Divider()
        }
    }

    // MARK: Files and tasks

    /// The files a lazyprint: URL asks to add: absolute paths only, as `LazyPrintUrl` parses them.
    static func files(in url: URL) -> [URL] {
        LazyPrintUrl.parse(url.absoluteString).map { URL(fileURLWithPath: $0) }
    }

    /// Takes the files of the oldest batch from a phone into the job, or into a new one, and shows the print tab.
    private func usePhoneBatch(_ id: String, startNew: Bool) {
        let before = opening
        opening = Task {
            await before?.value
            await state.takeBatch(id, startNew: startNew)
            if !state.documents.isEmpty {
                if let task = state.task { InspectorView.open(for: task) }
                tab = .print
            }
        }
    }

    /// A tile was picked: its settings are applied, and a task that starts with files opens the print tab and asks for
    /// them, unless some are there already; cancelling the panel leaves the empty print tab. The test page prints at once
    /// and stays here, where its result shows in the bars.
    private func start(_ task: PrintTask) async {
        await state.startTask(task)
        guard state.task == task, TaskCatalog.definition(task).opensFiles else { return }
        InspectorView.open(for: task)
        tab = .print
        if state.documents.isEmpty { showImporter = true }
    }

    /// Opens the files and shows the print tab. Files that come before any task was picked start the plain document task,
    /// so there is something to lay them out by. Folders are left; any file is taken, and the loader says why one is not a
    /// PDF or a picture.
    private func take(_ urls: [URL]) -> Bool {
        let files = urls.filter { $0.isFileURL && !$0.hasDirectoryPath }
        guard !files.isEmpty else { return false }
        let before = opening
        opening = Task {
            await before?.value
            if state.task == nil { await state.startTask(.document) }
            await state.addFiles(files)
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

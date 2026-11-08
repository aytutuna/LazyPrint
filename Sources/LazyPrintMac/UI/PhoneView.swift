#if os(macOS)
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import LazyPrintKit
import SwiftUI

/// "Print from your phone": whether this Mac receives from phones and on which networks (with "Allow receiving on this
/// network" for each), pairing a phone by QR code (asking the user to allow the phone that presents it), the paired
/// phones with Forget, the cloud folder phones put files in when they cannot reach this Mac, the connection checks
/// (`CompanionTroubleshooter`) and Reset pairing. Shown as a sheet from the sidebar and the task From your phone; the
/// pairing code stops working when it closes. It changes no system setting. Twin of the Windows `PhoneWindow`.
struct PhoneView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var host: MacCompanionHosting
    @Environment(\.dismiss) private var dismiss

    @StateObject private var question = PhonePairingQuestion()
    /// The pairing code shown, with its picture; nil when none is.
    @State private var code: PairingUri?
    @State private var qr: CGImage?
    /// Why no code could be shown, or the phone just paired.
    @State private var pairNote: String?
    @State private var footerMessage: String?
    @State private var opening = false
    @State private var confirmReset = false

    /// `code` is a pairing code already open on the service (the screenshots show one).
    @MainActor
    init(code: PairingUri? = nil) {
        _code = State(initialValue: code)
        _qr = State(initialValue: code.flatMap { try? $0.format() }.flatMap { PhoneView.qrImage($0) })
    }

    var body: some View {
        let service = host.service
        let snapshot = service?.snapshot()
            ?? CompanionSnapshot(platform: .mac, listen: host.status.state == .elsewhere ? .elsewhere : .failed,
                                 listenError: host.error)
        let checks = CompanionTroubleshooter.diagnose(snapshot)
        let devices = service?.devices.devices ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Print from your phone")
                    .font(.title2.weight(.semibold))
                Text(headline(snapshot))
                    .font(.headline)
                    .padding(.top, 4)
                Text("PDFs and pictures sent from a paired phone wait here until you choose to print them. Nothing goes through the internet: the phone and this Mac talk directly, encrypted, on networks you allow.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(20)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    sectionTitle("Networks")
                    if snapshot.networks.isEmpty && service != nil {
                        Text("Not connected to a network.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(snapshot.networks, id: \.listId) { network in
                        networkCard(network, service: service)
                    }

                    sectionTitle("Pair a phone")
                    pairCard(service)

                    sectionTitle("Paired phones")
                    if devices.isEmpty {
                        Text("No phone is paired yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(devices, id: \.id) { device in
                        phoneRow(device, service: service)
                    }

                    sectionTitle("Cloud folder")
                    syncFolderCard(service)

                    sectionTitle("Connection checks")
                    Text(CompanionTroubleshooter.summary(checks))
                        .foregroundStyle(.secondary)
                    ForEach(checks, id: \.id) { check in
                        TroubleshootCheckCard(check: check) { action in perform(action) }
                    }
                }
                .padding(20)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Reset pairing\u{2026}") {
                    confirmReset = true
                }
                .disabled(service == nil)
                .help("Unpair every phone and make a new security key for this Mac")
                if let footerMessage {
                    Text(footerMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(footerMessage)
                }
                Spacer()
                Button {
                    Task { await service?.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Check again")
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(16)
        }
        .frame(minWidth: 520, idealWidth: 600, minHeight: 480, idealHeight: 720)
        .onChange(of: devices.map(\.id)) { before, after in
            // A phone that presented the code was allowed and is paired now.
            guard let added = after.first(where: { !before.contains($0) }),
                  let device = host.service?.devices.devices.first(where: { $0.id == added }) else { return }
            code = nil
            pairNote = "Paired with \(device.name). Files sent from it wait for you to print them."
        }
        .onAppear {
            host.ensure()
            let question = question
            host.confirmPairing = { request in await question.ask(request) }
            Task { await host.service?.refresh() }
        }
        .onDisappear {
            question.settle(false)
            host.confirmPairing = nil
            if let service = host.service, service.pairing != nil {
                Task { await service.closePairing() }
            }
        }
        .alert("Reset pairing?", isPresented: $confirmReset) {
            Button("Reset pairing", role: .destructive) {
                Task { await resetPairing() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every paired phone will be forgotten and this Mac gets a new security key. Phones then pair again with a new code.")
        }
    }

    private func headline(_ snapshot: CompanionSnapshot) -> String {
        guard host.service == nil else { return CompanionTroubleshooter.headline(snapshot) }
        if host.status.state == .elsewhere { return "Another copy of Lazy Print receives from phones. Pair and manage phones there." }
        return "The phone link could not start: \(host.error ?? "unknown error")"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.headline)
            .padding(.top, 6)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Networks

    private func networkCard(_ network: CompanionNetworkState, service: CompanionService?) -> some View {
        let name = network.network.name.isEmpty ? "Unnamed network" : network.network.name
        let receiving = network.trust != .notTrusted
        return VStack(alignment: .leading, spacing: 4) {
            Text(name)
                .font(.headline)
            Text(network.network.id.isEmpty ? "Waiting for the network's details"
                 : receiving ? "Receiving allowed" : "Not receiving")
                .font(.caption)
                .foregroundStyle(.secondary)
            Toggle("Allow receiving on this network", isOn: Binding(
                get: { receiving },
                set: { allowed in Task { await setAllowed(network.network, allowed, service: service) } }))
                .toggleStyle(.switch)
                .disabled(service == nil || network.network.id.isEmpty)
                .help("For a network you trust, such as your home Wi-Fi. Only phones you paired can send.")
                .accessibilityLabel("Allow receiving on \(name)")
                .padding(.top, 4)
            if receiving {
                Text("macOS may ask once whether Lazy Print may find devices on local networks. Choose Allow, so phones can find this Mac.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneCard()
        .accessibilityElement(children: .contain)
    }

    private func setAllowed(_ network: CompanionNetwork, _ allowed: Bool, service: CompanionService?) async {
        guard let service else { return }
        if !(await service.setNetworkApproved(network, allowed)) {
            footerMessage = "The setting could not be saved."
        }
    }

    // MARK: - Pairing

    /// The code stays up while its question waits: the session is used by then, but not settled.
    private func codeShown(_ service: CompanionService?) -> Bool {
        code != nil && (service?.pairing != nil || question.phoneName != nil)
    }

    private func pairCard(_ service: CompanionService?) -> some View {
        let shown = codeShown(service)
        let title = shown ? "Show a new code" : "Pair a phone"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Open Lazy Print on your phone, go to Printers \u{203A} My computer \u{203A} Pair with a computer, and scan the code shown here. The code works once, for 5 minutes.")
                .fixedSize(horizontal: false, vertical: true)
            Button(title) {
                Task { await pair() }
            }
            .disabled(service == nil || opening)
            if shown, let code {
                codeDetails(code, service: service)
            }
            if let name = question.phoneName {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allow \u{201C}\(name)\u{201D} to send files to this Mac?")
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Button("Allow") {
                            question.settle(true)
                            code = nil
                        }
                        Button("Don't allow") {
                            question.settle(false)
                            code = nil
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
                }
            }
            if !shown {
                // Cleared wherever the user ends the pairing, so a code still set but not shown has run out.
                if let pairNote {
                    Text(pairNote)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if code != nil {
                    Text("The code expired. Choose Pair a phone to show a new one.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneCard()
    }

    private func codeDetails(_ code: PairingUri, service: CompanionService?) -> some View {
        let pairingText = (try? code.format()) ?? ""
        return HStack(alignment: .top, spacing: 16) {
            if let qr {
                Image(qr, scale: 1, label: Text("Pairing code to scan with your phone"))
                    .interpolation(.none)
                    .background(Color.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(expiry(at: context.date, service: service))
                        .font(.headline)
                }
                Text("Cannot scan the code? Get this pairing text onto the phone (a message to yourself, say) and paste it under Printers \u{203A} My computer \u{203A} Pair with a computer \u{203A} Enter pairing text, then compare the check code.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pairing text").foregroundStyle(.secondary)
                    Text(pairingText)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Copy") {
                        copyPairingText(pairingText)
                    }
                    .accessibilityLabel("Copy the pairing text")
                }
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("Check code").foregroundStyle(.secondary)
                        Text(code.fingerprintBytes.map { SpkiFingerprint.formatCheckCode(SpkiFingerprint.checkCode($0)) } ?? "")
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Button("Stop pairing") {
                    Task { await stopPairing() }
                }
                .padding(.top, 4)
            }
        }
    }

    private func expiry(at now: Date, service: CompanionService?) -> String {
        if let session = service?.pairing {
            let left = Int(session.remaining(at: now).rounded(.up))
            let remaining: String = Duration.seconds(left).formatted(.time(pattern: .minuteSecond(padMinuteToLength: 1)))
            return "Scan this code with your phone. It works for \(remaining) more."
        }
        return question.phoneName != nil ? "A phone scanned this code. Allow it below, or not." : ""
    }

    /// Shows a new pairing code, or says why none can be shown.
    private func pair() async {
        guard let service = host.ensure() else { return }
        footerMessage = nil
        opening = true
        let opened = await service.openPairing()
        opening = false
        code = opened
        if let opened, let text = try? opened.format() {
            qr = PhoneView.qrImage(text)
            pairNote = nil
        } else {
            code = nil
            qr = nil
            pairNote = PhoneView.whyNoCode(service.status)
        }
    }

    private func stopPairing() async {
        question.settle(false)
        // Before the close, or the update it causes calls the code expired.
        code = nil
        await host.service?.closePairing()
    }

    private func copyPairingText(_ text: String) {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.clearContents()
        footerMessage = pasteboard.setString(text, forType: .string) ? "Copied to the clipboard." : "Copy did not work."
    }

    static func whyNoCode(_ status: CompanionHostStatus) -> String {
        switch status.state {
        case .offline:
            return "Connect this Mac to a network first, then choose Pair a phone again."
        case .noTrustedNetwork:
            return "This Mac does not receive on the network it is on. Turn on Allow receiving on this network above, then choose Pair a phone again."
        case .failed:
            return status.error ?? "Receiving from phones could not start."
        default:
            return "No pairing code could be made."
        }
    }

    /// The QR code of `text` from Core Image's generator (level M, one module per pixel, a quiet zone of its own that is cut
    /// off), drawn with a quiet zone of four modules, black on white, at whole pixels per module so it stays sharp without
    /// interpolation. The Mac counterpart of the Windows `ZXingQrEncoder`.
    static func qrImage(_ text: String) -> CGImage? {
        guard let data = text.data(using: .utf8), !text.isEmpty else { return nil }
        let filter = CIFilter.qrCodeGenerator()
        filter.message = data
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        guard let generated = context.createCGImage(output, from: output.extent.integral) else { return nil }
        let width = generated.width, height = generated.height
        guard let gray = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                   space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let source = gray.data else { return nil }
        gray.interpolationQuality = .none
        gray.draw(generated, in: CGRect(x: 0, y: 0, width: width, height: height))
        let pixels = source.bindMemory(to: UInt8.self, capacity: width * height)
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            for x in 0..<width where pixels[y * width + x] < 128 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        let size = maxX - minX + 1
        guard maxX >= minX, size == maxY - minY + 1, size >= 21, (size - 21) % 4 == 0 else { return nil }
        let quiet = 4
        let span = size + 2 * quiet
        let scale = max(3, 232 / span)
        let side = span * scale
        var picture = [UInt8](repeating: 255, count: side * side)
        for y in 0..<size {
            for x in 0..<size where pixels[(minY + y) * width + minX + x] < 128 {
                for dy in 0..<scale {
                    let row = ((y + quiet) * scale + dy) * side + (x + quiet) * scale
                    for dx in 0..<scale {
                        picture[row + dx] = 0
                    }
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(picture) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    // MARK: - Paired phones

    private func phoneRow(_ device: PairedDevice, service: CompanionService?) -> some View {
        let name = device.name.isEmpty ? "Phone" : device.name
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.headline)
                Text(PhoneView.caption(device))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if service?.devices.hasSyncKey(device.id) == false {
                    Text("Pair again to use the cloud folder")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Forget") {
                Task { await forget(device.id, service: service) }
            }
            .help("This phone can no longer send files here, until it is paired again")
            .accessibilityLabel("Forget \(name)")
        }
        .phoneCard()
        .accessibilityElement(children: .contain)
    }

    private func forget(_ id: String, service: CompanionService?) async {
        guard let service else { return }
        await service.removeDevice(id)
        footerMessage = "Forgotten. That phone can no longer send files here."
    }

    /// "Paired 20/10/2026 · last seen today at 14:05".
    static func caption(_ device: PairedDevice) -> String {
        var parts: [String] = []
        if let paired = device.paired {
            parts.append("Paired \(paired.formatted(date: .numeric, time: .omitted))")
        }
        if let seen = device.lastSeen {
            parts.append(Calendar.current.isDateInToday(seen)
                ? "last seen today at \(seen.formatted(date: .omitted, time: .shortened))"
                : "last seen \(seen.formatted(date: .numeric, time: .omitted))")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: - Cloud folder

    private func syncFolderCard(_ service: CompanionService?) -> some View {
        let folder = service?.syncFolder
        let problem = service == nil ? nil : host.syncFolderProblem
        return VStack(alignment: .leading, spacing: 8) {
            Text("A folder synced by iCloud Drive or OneDrive. The phone puts files here when it cannot reach this Mac; they are encrypted with a key only this Mac and the phone know.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Text(folder?.path ?? "")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(folder?.path ?? "")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("Choose\u{2026}") {
                    chooseSyncFolder(folder)
                }
                .disabled(service == nil)
                .help("Choose the cloud folder")
                Button("Clear") {
                    setSyncFolder(nil)
                }
                .disabled(folder == nil)
                .help("Stop watching the cloud folder")
            }
            Text(PhoneView.syncFolderStatus(folder, running: service != nil))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let problem {
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .phoneCard()
        .accessibilityElement(children: .contain)
    }

    static func syncFolderStatus(_ folder: URL?, running: Bool) -> String {
        guard running else { return "Not watching." }
        guard let folder else { return "Not watching: no folder chosen." }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isFolder), isFolder.boolValue else {
            return "Waiting for \(folder.path): the folder is not there now."
        }
        return "Watching \(folder.path)."
    }

    /// The user's own home folder. `homeDirectoryForCurrentUser` is the app's container when it is sandboxed.
    private static var realHome: URL {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else {
            return FileManager.default.homeDirectoryForCurrentUser
        }
        return URL(fileURLWithPath: String(cString: directory), isDirectory: true)
    }

    /// Starts in the folder chosen now, or else in iCloud Drive.
    private func chooseSyncFolder(_ current: URL?) {
        let panel = NSOpenPanel()
        panel.title = "Choose the cloud folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if let current, FileManager.default.fileExists(atPath: current.path) {
            panel.directoryURL = current
        } else {
            // Not checked for: a sandboxed app cannot see the folder, but the panel can, and ignores a start that is not there.
            panel.directoryURL = PhoneView.realHome
                .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        }
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setSyncFolder(url)
    }

    private func setSyncFolder(_ folder: URL?) {
        if !host.setSyncFolder(folder) {
            footerMessage = "The setting could not be saved."
        }
    }

    // MARK: - Reset and checks

    private func resetPairing() async {
        guard let service = host.service else { return }
        question.settle(false)
        do {
            try await service.resetPairing()
            code = nil
            pairNote = nil
            footerMessage = "Pairing was reset."
        } catch {
            let reason = (error as? SelfSignedCertificateError)?.message ?? error.localizedDescription
            footerMessage = "Pairing could not be reset: \(reason)"
        }
    }

    private func perform(_ action: TroubleshootAction) {
        switch action {
        case .refresh:
            Task { await host.service?.refresh() }
        case .openNetworkSettings:
            Task {
                let before = state.errorsShown
                await state.perform(action)
                footerMessage = state.errorDetail(since: before)
            }
        default:
            break
        }
    }
}

/// The question the phone sheet asks when a phone presents the pairing code (`MacCompanionHosting.confirmPairing`):
/// answered with Allow or Don't allow, and declined when it is cancelled (no answer within two minutes, or the phone went
/// away), when another phone asks, or when the sheet closes.
@MainActor
final class PhonePairingQuestion: ObservableObject {
    /// The name of the phone asking; nil when nothing is asked.
    @Published private(set) var phoneName: String?
    private var answer: CheckedContinuation<Bool, Never>?
    private var asked = 0

    func ask(_ request: PairRequest) async -> Bool {
        settle(false)
        asked += 1
        let number = asked
        phoneName = request.phoneName
        if !NSApp.isActive { _ = NSApp.requestUserAttention(.informationalRequest) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                answer = continuation
            }
        } onCancel: {
            Task { @MainActor in
                if self.asked == number { self.settle(false) }
            }
        }
    }

    /// Answers the question asked now, if any.
    func settle(_ allow: Bool) {
        let waiting = answer
        answer = nil
        phoneName = nil
        waiting?.resume(returning: allow)
    }
}

private extension CompanionNetworkState {
    /// Networks without a router signature all have the empty `network.id`; their adapters tell them apart.
    var listId: String {
        network.id + (network.interfaces.first?.adapterId ?? "")
    }
}

private extension View {
    /// The card the phone sheet shows each network, phone and the pairing in.
    func phoneCard() -> some View {
        padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor))
            }
    }
}
#endif

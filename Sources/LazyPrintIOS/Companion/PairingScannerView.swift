#if os(iOS)
import AVFoundation
import LazyPrintKit
import SwiftUI
import UIKit
import VisionKit

/// The camera looking for the computer's pairing code (its QR code): VisionKit's live scanner where this
/// device has it, else the camera's own QR reader (AVCaptureMetadataOutput). The first text read that is
/// a pairing code (`isPairingCode`) is handed to `onCode`, once. Camera access is asked for the first
/// time (`PairingCameraAvailability`); without a camera (the Simulator) or access, one
/// line says why, and the pairing text is entered below instead.
struct PairingScannerView: View {
    let onCode: @MainActor (String) -> Void
    @State private var availability: PairingCameraAvailability?
    /// The camera stopped or could not start here, as in Split View or Slide Over, where another app may have it.
    @State private var cameraLost = false

    var body: some View {
        Group {
            if cameraLost {
                lost
            } else if let shown = availability {
                if shown.isAvailable {
                    if PairingScannerView.usesDataScanner {
                        PairingDataScanner(onCode: onCode, onLost: { cameraLost = true })
                    } else {
                        PairingCaptureScanner(onCode: onCode, onLost: { cameraLost = true })
                    }
                } else {
                    unavailable(shown)
                }
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityIdentifier("companion.scanner")
        .task {
            availability = await PairingScannerView.cameraAvailability()
        }
    }

    private var lost: some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(Color.white)
                .accessibilityHidden(true)
            Text("The camera is not available here. Paste the pairing text below instead.")
                .font(.headline)
                .foregroundStyle(Color.white)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("companion.scanner.message")
        }
        .padding(16)
    }

    private func unavailable(_ shown: PairingCameraAvailability) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "qrcode.viewfinder")
                .font(.largeTitle)
                .foregroundStyle(Color.white)
                .accessibilityHidden(true)
            Text(shown.reason ?? "")
                .font(.headline)
                .foregroundStyle(Color.white)
                .accessibilityIdentifier("companion.scanner.message")
            if shown.opensSettings {
                Button(IOSCompanionText.settingsButton) {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url, options: [:], completionHandler: nil)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("companion.scanner.settings")
            }
        }
        .padding(16)
    }

    /// VisionKit's scanner can run here now (it needs camera access too).
    @MainActor
    static var usesDataScanner: Bool {
        DataScannerViewController.isSupported && DataScannerViewController.isAvailable
    }

    /// Whether this device can look for codes, asking for camera access when it never was.
    @MainActor
    static func cameraAvailability() async -> PairingCameraAvailability {
        let found: Bool = DataScannerViewController.isSupported || AVCaptureDevice.default(for: .video) != nil
        var status: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if found && status == .notDetermined {
            let granted: Bool = await AVCaptureDevice.requestAccess(for: .video)
            status = granted ? .authorized : .denied
        }
        return PairingCameraAvailability.resolve(isSupported: found, authorization: status)
    }

    /// A text read from a QR code that is a pairing code.
    static func isPairingCode(_ text: String) -> Bool {
        text.lowercased().hasPrefix(PairingUri.prefix)
    }
}

/// Whether the camera can look for codes, and if not, why (one short line).
enum PairingCameraAvailability: Equatable {
    case available
    /// This device has no camera (the Simulator).
    case noCamera
    /// The user turned camera access off for the app in Settings.
    case denied
    /// Camera access is not allowed here (Screen Time or a device profile).
    case restricted

    static func resolve(isSupported: Bool, authorization: AVAuthorizationStatus) -> PairingCameraAvailability {
        if !isSupported { return .noCamera }
        switch authorization {
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .available
        }
    }

    var isAvailable: Bool { self == .available }

    var reason: String? {
        switch self {
        case .available: return nil
        case .noCamera: return "No camera here"
        case .denied: return "Camera access is off"
        case .restricted: return "Camera not allowed"
        }
    }

    /// Settings can turn camera access back on.
    var opensSettings: Bool { self == .denied }
}

/// VisionKit's live scanner, for QR codes only.
private struct PairingDataScanner: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void
    let onLost: @MainActor () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onCode: onCode, onLost: onLost)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner: DataScannerViewController = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                                           qualityLevel: .balanced,
                                                                           recognizesMultipleItems: false,
                                                                           isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning {
            do {
                try scanner.startScanning()
            } catch {
                // Not while a view update is running.
                let lost: @MainActor () -> Void = onLost
                Task { @MainActor in lost() }
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        scanner.stopScanning()
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: @MainActor (String) -> Void
        var onLost: @MainActor () -> Void
        private var handed: Bool = false

        init(onCode: @escaping @MainActor (String) -> Void, onLost: @escaping @MainActor () -> Void) {
            self.onCode = onCode
            self.onLost = onLost
        }

        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onLost()
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                guard !handed, case .barcode(let barcode) = item, let text = barcode.payloadStringValue,
                      PairingScannerView.isPairingCode(text) else { continue }
                handed = true
                onCode(text)
            }
        }
    }
}

/// The camera's own QR reader, where VisionKit's scanner is not supported.
private struct PairingCaptureScanner: UIViewControllerRepresentable {
    let onCode: @MainActor (String) -> Void
    let onLost: @MainActor () -> Void

    func makeUIViewController(context: Context) -> PairingCaptureController {
        PairingCaptureController(onCode: onCode, onLost: onLost)
    }

    func updateUIViewController(_ controller: PairingCaptureController, context: Context) {
        controller.onCode = onCode
        controller.onLost = onLost
    }
}

/// The capture session, started and stopped off the main thread as AVFoundation asks.
private final class PairingCaptureSession: @unchecked Sendable {
    let session: AVCaptureSession = AVCaptureSession()
    let queue: DispatchQueue = DispatchQueue(label: "LazyPrint.pairing.camera")

    func start() {
        queue.async {
            if !self.session.isRunning {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        queue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
        }
    }
}

private final class PairingCaptureController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: @MainActor (String) -> Void
    var onLost: @MainActor () -> Void
    private let capture: PairingCaptureSession = PairingCaptureSession()
    private var preview: AVCaptureVideoPreviewLayer?
    private var handed: Bool = false
    private var interruption: NSObjectProtocol?

    init(onCode: @escaping @MainActor (String) -> Void, onLost: @escaping @MainActor () -> Void) {
        self.onCode = onCode
        self.onLost = onLost
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let interruption {
            NotificationCenter.default.removeObserver(interruption)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor.black
        let session: AVCaptureSession = capture.session
        // Another app using the camera beside this one (Split View, Slide Over) interrupts the session.
        interruption = NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session,
                                                              queue: .main) { [weak self] (_: Notification) in
            Task { @MainActor in self?.onLost() }
        }
        guard let camera = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            Task { @MainActor [weak self] in self?.onLost() }
            return
        }
        session.addInput(input)
        let output: AVCaptureMetadataOutput = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
        // Only once the output is in the session does it offer QR codes.
        if output.availableMetadataObjectTypes.contains(.qr) {
            output.metadataObjectTypes = [.qr]
        }
        let layer: AVCaptureVideoPreviewLayer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        preview = layer
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        preview?.frame = view.bounds
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        capture.start()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        capture.stop()
    }

    nonisolated func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject],
                                    from connection: AVCaptureConnection) {
        var texts: [String] = []
        for object in metadataObjects {
            if let code = object as? AVMetadataMachineReadableCodeObject, let text = code.stringValue {
                texts.append(text)
            }
        }
        MainActor.assumeIsolated {
            self.read(texts)
        }
    }

    private func read(_ texts: [String]) {
        for text in texts where !handed && PairingScannerView.isPairingCode(text) {
            handed = true
            onCode(text)
        }
    }
}
#endif

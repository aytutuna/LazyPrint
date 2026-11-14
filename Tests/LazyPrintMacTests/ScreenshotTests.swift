#if os(macOS)
import AppKit
import CoreGraphics
import CoreText
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import LazyPrintKit
@testable import LazyPrintMac

// The Mac app's screens, written as PNGs when LAZYPRINT_SHOTS names a folder, so they can be looked at without a Mac. They
// are not assertions of pixels. Each screen is a view hosted in an NSHostingView inside a borderless window out of sight, in
// the light and the dark appearance. The windows that are sheets in the app (the troubleshooter, the add sheet, the
// two-sided card) are hosted on their own, since a sheet is a window of its own and would not be in the picture.

/// A queue with a problem and a few jobs, for the troubleshooter.
@MainActor
private final class StoppedQueue: PrinterSystem {
    func queues() async -> [SystemPrinter] {
        [SystemPrinter(name: "HP LaserJet", model: "HP LaserJet Pro M404", port: "ipp://hp.local/ipp/print", isDefault: true,
                       isVirtual: false, states: [.paperOut, .tonerLow],
                       jobs: SystemQueueJobs(count: 3, anyInError: false, oldestMinutes: 12))]
    }

    func capabilities(ofQueue name: String) async -> PrinterCapabilities? { nil }
    func clearJobs(ofQueue name: String) async throws {}
    func resume(queue name: String) async throws {}
}

/// A phone link with one batch of files waiting, for the bar.
@MainActor
private final class OneBatch: CompanionHosting {
    var onChange: (@MainActor () -> Void)?

    func batches(now: Date) -> [PhoneBatch] {
        [PhoneBatch(id: "batch-0001", from: "Aytu's iPhone", count: 3, arrived: 3, lastReceived: now)]
    }

    func take(batch: String) async -> [URL] { [] }
    func discard(batch: String) {}
}

/// A fixture that could not be made: a failure, not a skip, so a broken run does not read as one that was not asked for.
private struct ShotError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@MainActor
final class ScreenshotTests: XCTestCase {
    private func shots() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["LAZYPRINT_SHOTS"], !path.isEmpty else {
            throw XCTSkip("LAZYPRINT_SHOTS names no folder")
        }
        // A window cannot be built without the application.
        _ = NSApplication.shared
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func workFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("lp-shots-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    /// The demo printer alone (or, with `system`, a queue beside it), the printers read once.
    private func makeState(in work: URL, system: (any PrinterSystem)? = nil, companion: (any CompanionHosting)? = nil) async -> AppState {
        let state = AppState(printerSystem: system, companion: companion, files: AppStateFiles.all(in: work.appendingPathComponent("files")))
        if system == nil { state.settings.printerId = PrinterMerge.demoId }
        await state.refreshPrinters()
        return state
    }

    /// A report of `pages` letter pages, each with its number.
    private func writePDF(pages: Int, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent("Quarterly report.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw ShotError("No PDF context") }
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 44, nil)
        for page in 1...pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 0.2, green: 0.45, blue: 0.75, alpha: 1))
            context.fill(CGRect(x: 54, y: 620, width: 504, height: 100))
            context.setFillColor(CGColor(gray: 0.85, alpha: 1))
            for line in 0..<9 {
                context.fill(CGRect(x: 54, y: 540 - CGFloat(line) * 40, width: line % 3 == 2 ? 300 : 504, height: 14))
            }
            let text = NSAttributedString(string: "Page \(page)", attributes: [.font: font])
            context.textPosition = CGPoint(x: 54, y: 120)
            CTLineDraw(CTLineCreateWithAttributedString(text), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A photo: a sky of the given color over a field.
    private func writePhoto(named name: String, sky: CGColor, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name + ".png")
        let width = 1200, height = 800
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let gradient = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.95, green: 0.7, blue: 0.4, alpha: 1), sky] as CFArray,
                                        locations: [0, 1]) else { throw ShotError("No bitmap context") }
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 300), end: CGPoint(x: 0, y: 800), options: [])
        context.setFillColor(CGColor(red: 0.25, green: 0.55, blue: 0.3, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: 300))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ShotError("No image destination")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ShotError("The picture was not written") }
        return url
    }

    /// Hosts `view` in a window of its own and writes it in both appearances as mac-<name>-light.png and -dark.png.
    private func capture<Content: View>(_ view: @autoclosure () -> Content, of state: AppState, name: String, in folder: URL,
                                        size: CGSize = CGSize(width: 1280, height: 800),
                                        before: () async throws -> Void = {}) async throws {
        // ContentView reads the phone link as it draws. The phone sheet brings its own, which is the one it sees.
        let phone = MacCompanionHosting(options: try .test(in: try workFolder()))
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (NSAppearance.Name.darkAqua, "dark")] {
            try await before()
            // The window's own background is not in the picture: without one the parts of the view that have none are clear.
            let host = NSHostingView(rootView: view().environmentObject(state).environmentObject(phone)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: appearance)
            window.contentView = host
            window.orderFront(nil)
            host.frame = NSRect(origin: .zero, size: size)
            // The views appear, the preview asks for its size and is drawn again at it.
            for _ in 0..<3 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 300_000_000)
                await state.previewTask?.value
            }
            host.layoutSubtreeIfNeeded()
            // Drawn at twice the points, as on a Retina screen: the 1280 x 800 window is the App Store's 2560 x 1600.
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * 2, pixelsHigh: Int(size.height) * 2,
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
                XCTFail("No bitmap for \(name)")
                continue
            }
            rep.size = size
            host.cacheDisplay(in: host.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else {
                XCTFail("No PNG for \(name)")
                continue
            }
            try png.write(to: folder.appendingPathComponent("mac-\(name)-\(suffix).png"))
            window.orderOut(nil)
            // A view that goes away may close what it opened (the phone sheet's code), in a task of its own: let that
            // finish before the next appearance opens its own.
            window.contentView = nil
            try await Task.sleep(nanoseconds: 300_000_000)
        }
    }

    func test_print_twoUp() async throws {
        let folder = try shots()
        let work = try workFolder()
        let state = await makeState(in: work)
        await state.startTask(.handouts)
        await state.addFiles([try writePDF(pages: 5, in: work)])
        try await capture(ContentView(tab: .print), of: state, name: "print", in: folder)
    }

    func test_print_photoSheet() async throws {
        let folder = try shots()
        let work = try workFolder()
        let state = await makeState(in: work)
        await state.startTask(.photoSheet)
        let skies = [(0.25, 0.5, 0.85), (0.6, 0.35, 0.7), (0.2, 0.65, 0.6), (0.8, 0.3, 0.3)]
        var photos = [URL]()
        for (i, sky) in skies.enumerated() {
            photos.append(try writePhoto(named: "Holiday \(i + 1)", sky: CGColor(red: sky.0, green: sky.1, blue: sky.2, alpha: 1), in: work))
        }
        await state.addFiles(photos)
        try await capture(ContentView(tab: .print), of: state, name: "photo-sheet", in: folder)
    }

    /// Margin None on a printer that cannot print to the edge: its limit is the margin, and the page prints a little smaller.
    func test_print_marginNone() async throws {
        let folder = try shots()
        let work = try workFolder()
        let state = await makeState(in: work)
        await state.startTask(.document)
        state.settings.margin = .none
        state.settings.scaling = .shrinkToFit
        await state.addFiles([try writePDF(pages: 2, in: work)])
        let key = "inspector." + InspectorSections.layout
        UserDefaults.standard.set(true, forKey: key)
        addTeardownBlock { UserDefaults.standard.removeObject(forKey: key) }
        // Tall enough for the inspector to reach the margins without scrolling.
        try await capture(ContentView(tab: .print), of: state, name: "margin-none", in: folder, size: CGSize(width: 1280, height: 1150))
    }

    func test_jobs() async throws {
        let folder = try shots()
        let work = try workFolder()
        let state = await makeState(in: work)
        await state.startTask(.document)
        await state.addFiles([try writePDF(pages: 2, in: work)])
        await state.print()
        XCTAssertEqual(state.jobs.count, 1)
        try await capture(ContentView(tab: .jobs), of: state, name: "jobs", in: folder)
    }

    func test_twoSidedCard() async throws {
        let folder = try shots()
        let work = try workFolder()
        let state = await makeState(in: work)
        await state.setDemoDuplex(false)
        await state.startTask(.twoSided)
        await state.addFiles([try writePDF(pages: 4, in: work)])
        await state.print()
        XCTAssertNotNil(state.duplexCard, "A printer that prints one side gets the card")
        try await capture(DuplexCardView(), of: state, name: "two-sided", in: folder, size: CGSize(width: 520, height: 200))
    }

    func test_troubleshooter_noPrinter() async throws {
        let folder = try shots()
        let state = await makeState(in: try workFolder())
        await state.openTroubleshooter()
        XCTAssertEqual(Troubleshooter.headline(state.snapshot), "No printer found")
        try await capture(TroubleshooterView(), of: state, name: "troubleshooter-none", in: folder,
                          size: CGSize(width: 620, height: 680))
    }

    func test_troubleshooter_stoppedPrinter() async throws {
        let folder = try shots()
        let state = await makeState(in: try workFolder(), system: StoppedQueue())
        await state.openTroubleshooter()
        XCTAssertEqual(Troubleshooter.headline(state.snapshot), "1 printer found")
        try await capture(TroubleshooterView(), of: state, name: "troubleshooter-stopped", in: folder,
                          size: CGSize(width: 620, height: 680))
    }

    func test_phoneBar() async throws {
        let folder = try shots()
        let state = await makeState(in: try workFolder(), companion: OneBatch())
        XCTAssertEqual(state.phoneBatches.count, 1)
        try await capture(ContentView(tab: .print), of: state, name: "phone-bar", in: folder)
    }

    func test_phoneSheet() async throws {
        let folder = try shots()
        let work = try workFolder()
        let state = await makeState(in: work)
        let options = try CompanionServiceOptions.test(in: work.appendingPathComponent("link"), networks: [GivenNetworks.loopback()])
        _ = try PairedDeviceStore(directory: options.settingsDirectory)
            .pair(id: "phone-0001", name: "Aytu's iPhone", platform: "ios", appVersion: "1.0", now: Date())
        let host = MacCompanionHosting(options: options)
        let service = try XCTUnwrap(host.ensure())
        await service.refresh()
        var code: PairingUri?
        // A sheet that goes away closes its code, so each appearance opens one.
        try await capture(PhoneView(code: code).environmentObject(host), of: state, name: "phone-sheet", in: folder,
                          size: CGSize(width: 640, height: 1400)) {
            code = await service.openPairing()
            XCTAssertNotNil(code, "The loopback network should let a code be shown")
        }
        await service.dispose()
    }

    func test_addPrinter() async throws {
        let folder = try shots()
        let state = await makeState(in: try workFolder())
        try await capture(AddPrinterView(), of: state, name: "add-printer", in: folder, size: CGSize(width: 480, height: 250))
    }
}
#endif

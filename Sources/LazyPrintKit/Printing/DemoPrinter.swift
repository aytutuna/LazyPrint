import Combine
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Twin of windows/LazyPrint.App/Printing/DemoPrinter.cs: the printer that is always there.

/// What the demo printer is like right now, shared by the window (its row, its menu) and the printer: whether it prints
/// both sides, whether it is out of paper, its ink and the folders its jobs went to. Kept for the session only.
@MainActor
public final class DemoPrinterState: ObservableObject {
    private static let lowAt = 15
    private static let inks = [("Cyan", "#00AEEF"), ("Magenta", "#EC008C"), ("Yellow", "#FFF200"), ("Black", "#231F20")]

    /// The demo printer prints both sides (a switch on its menu).
    @Published public var duplex = true
    /// Set from its menu to try the troubleshooter and the two-sided card.
    @Published public var outOfPaper = false
    @Published public private(set) var ink = [100, 100, 100, 100]

    /// Where the jobs' folders go.
    public let root: URL
    /// The folder of each job record, by its id.
    public var folders: [String: URL] = [:]

    public init(root: URL) {
        self.root = root
    }

    public func supplies() -> [Supply] {
        Self.inks.enumerated().map { i, ink in
            Supply(name: ink.0, color: ink.1, level: self.ink[i], isLow: self.ink[i] <= Self.lowAt)
        }
    }

    public var problem: PrinterProblem? {
        outOfPaper ? PrinterProblem(title: IppProblemText.outOfPaper, advice: IppProblemText.outOfPaperAdvice, isError: true) : nil
    }

    /// A job takes a little ink: black only for a gray one.
    func useInk(gray: Bool) {
        for i in (gray ? Self.inks.count - 1 : 0)..<ink.count {
            ink[i] = max(0, ink[i] - 2)
        }
    }
}

/// The demo printer: always listed, last, so every task can be tried without a printer. It takes any format, has Letter,
/// A4 and 4 × 6 in photo paper with 0.17 in margins, and prints both sides unless its state says it does not. It "prints"
/// by writing each side as a PNG into a folder of its own under `DemoPrinterState.root`.
public struct DemoPrinter: SheetPrinter {
    /// 0.17 in in hundredths of a millimetre.
    private static let margin = 432
    private static let dpi: Double = 150
    private static let papers = [(21590, 27940), (21000, 29700), (10160, 15240)]

    private let state: DemoPrinterState

    public init(state: DemoPrinterState) {
        self.state = state
    }

    public static func capabilities(duplex: Bool) -> PrinterCapabilities {
        var caps = PrinterCapabilities()
        caps.name = PrinterMerge.demoName
        caps.makeAndModel = "Demo Printer"
        caps.documentFormatsSupported = ["application/pdf", "image/pwg-raster", "image/urf", "image/jpeg"]
        caps.sidesSupported = duplex ? ["one-sided", "two-sided-long-edge", "two-sided-short-edge"] : ["one-sided"]
        caps.printColorModesSupported = ["color", "monochrome"]
        caps.copiesSupported = CopiesRange(lower: 1, upper: 99)
        caps.multipleDocumentHandlingSupported = ["separate-documents-collated-copies"]
        caps.printQualitySupported = [3, 4, 5]
        let margins = MediaMargins(top: margin, left: margin, bottom: margin, right: margin)
        caps.mediaColDatabase = papers.map { paper in
            MediaEntry(attributes: [], width: paper.0, height: paper.1, isVariable: false, margins: margins, type: nil, source: nil)
        }
        return caps
    }

    public func print(_ job: SheetJob, pass: Int, progress: @Sendable (JobStatus) -> Void) async throws {
        try Task.checkCancellation()
        // The state's switches are read once, here; the ink goes down once, at the end.
        let (problem, known, root) = await MainActor.run { (state.problem, state.folders[job.id], state.root) }
        if let problem { throw PrinterProblemError(problem: problem) }

        let sides = JobSides.of(job, pass: pass)
        let folder: URL
        if let known {
            folder = known
        } else {
            folder = try Self.makeFolder(for: job, in: root)
            if !job.id.isEmpty {
                await MainActor.run { state.folders[job.id] = folder }
            }
        }
        let gray = job.settings.color == .gray
        let area = job.plan.plan.area
        let names = Self.names(job, pass: pass, count: sides.count)
        let renderer = SheetRenderer(documents: job.documents)
        progress(JobStatus(state: .printing, sidesDone: 0))
        for (i, side) in sides.enumerated() {
            try Task.checkCancellation()
            try autoreleasepool {
                let bitmap = try renderer.bitmap(side, area: area, dpi: Self.dpi, gray: gray)
                try Self.writePNG(bitmap, to: folder.appendingPathComponent(names[i] + ".png"))
            }
            progress(JobStatus(state: .printing, sidesDone: i + 1))
        }
        await MainActor.run { state.useInk(gray: gray) }
    }

    private static func writePNG(_ bitmap: SheetBitmap, to url: URL) throws {
        guard let image = bitmap.image(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }

    /// The job's folder, made the first time (both passes of a job go to the same one).
    private static func makeFolder(for job: SheetJob, in root: URL) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let clean = String(job.name.unicodeScalars.map { forbidden.contains($0) ? "_" : Character($0) })
            .trimmingCharacters(in: .whitespaces)
        func folder(_ n: Int) -> URL {
            let name = "\(formatter.string(from: Date())) \(clean)" + (n > 1 ? " \(n)" : "")
            return root.appendingPathComponent(name.trimmingCharacters(in: .whitespaces), isDirectory: true)
        }
        var n = 1
        while FileManager.default.fileExists(atPath: folder(n).path) { n += 1 }
        let made = folder(n)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        return made
    }

    /// "Sheet 2 front", "Sheet 2 back", "Sheet 2" for one side, "Fronts 2" and "Backs 2" for the passes of a manual job.
    private static func names(_ job: SheetJob, pass: Int, count: Int) -> [String] {
        (0..<count).map { i in
            if job.plan.manualDuplex { return "\(pass == 0 ? "Fronts" : "Backs") \(i + 1)" }
            if job.plan.plan.duplex { return "Sheet \(i / 2 + 1) \(i % 2 == 0 ? "front" : "back")" }
            return "Sheet \(i + 1)"
        }
    }
}

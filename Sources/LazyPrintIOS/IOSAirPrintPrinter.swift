#if os(iOS)
import LazyPrintKit
import CoreGraphics
import Foundation
import UIKit

/// The iPhone's `SheetPrinter` for the AirPrint printer the user chose (`IOSPrinterSystem`). The pass is written as a PDF
/// of sheets (the Kit has put the copies in it already: `UIPrintPageRenderer` has no copy count and no collate), drawn
/// onto the printer's paper 1:1 by a page renderer, and handed to `UIPrintInteractionController.print(to:)` with the
/// paper the printer has closest to the sheet. The completion handler means the system took the job, so the pass ends as
/// sent: iOS gives no further word on it.
public final class IOSAirPrintPrinter: SheetPrinter {
    private let system: IOSPrinterSystem

    public init(system: IOSPrinterSystem) {
        self.system = system
    }

    public func print(_ job: SheetJob, pass: Int, progress: @Sendable (JobStatus) -> Void) async throws {
        try Task.checkCancellation()
        try await check(job)

        let file: URL = FileManager.default.temporaryDirectory.appendingPathComponent("lp-" + UUID().uuidString.lowercased() + ".pdf")
        let sides: [RenderedSide] = JobSides.of(job, pass: pass)
        progress(JobStatus(state: .preparing, sidesDone: 0))
        // From here the renderer owns the file and removes it when the system lets the renderer go.
        let renderer: IOSPrintRenderer
        do {
            try SheetRenderer(documents: job.documents).writePDF(sides, area: job.plan.plan.area, to: file) { (done: Int) -> Void in
                progress(JobStatus(state: .preparing, sidesDone: done))
            }
            guard let made: IOSPrintRenderer = IOSPrintRenderer(file: file) else {
                throw PrintError.unreadable("The pages could not be prepared for printing.")
            }
            renderer = made
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        try Task.checkCancellation()

        progress(JobStatus(state: .sending, sidesDone: sides.count, cancelable: false))
        try await send(renderer, job: job)
        progress(JobStatus(state: .done, sidesDone: sides.count))
    }

    /// The job is for the printer chosen, and that printer answers; nothing is sent to one that does not.
    @MainActor
    private func check(_ job: SheetJob) async throws {
        guard UIPrintInteractionController.isPrintingAvailable, system.printer != nil,
              IOSAirPrintPrinter.isFor(job, queue: system.queueName) else { throw PrintError.noPrinter }
        guard await system.isReachable() else {
            throw PrintError.unreachable(name: system.queueName, reason: "it did not answer.")
        }
    }

    @MainActor
    private func send(_ renderer: IOSPrintRenderer, job: SheetJob) async throws {
        try Task.checkCancellation()
        guard let printer: UIPrinter = system.printer else { throw PrintError.noPrinter }
        let chooser: PaperChooser = PaperChooser(pageSize: IOSAirPrintPrinter.pageSize(of: job))
        let controller: UIPrintInteractionController = UIPrintInteractionController.shared
        controller.printInfo = IOSAirPrintPrinter.printInfo(for: job)
        controller.printPageRenderer = renderer
        // The delegate is held weakly, and the printer is not left set: the share sheet's Print uses the same controller.
        controller.delegate = chooser
        controller.showsNumberOfCopies = false

        // What a running print uses stays set until the system is done with it, which is the completion handler or a refusal
        // to start, not the end of the wait: Cancel ends the wait first. A later pass may have set its own by the time this
        // runs, and that one is left alone. The controller holds its delegate weakly, so this closure is what keeps `chooser`.
        let release: @MainActor () -> Void = {
            withExtendedLifetime(chooser) {
                guard controller.printPageRenderer === renderer else { return }
                controller.delegate = nil
                controller.printPageRenderer = nil
                controller.printInfo = nil
                controller.showsNumberOfCopies = true
            }
        }

        // The completion handler, a refusal to start and Cancel each end the wait, and the first one counts.
        let name: String = system.queueName
        let once: OneShot<Void, Error> = OneShot()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                once.arm(continuation)
                let started: Bool = controller.print(to: printer) { (_: UIPrintInteractionController, done: Bool, error: Error?) -> Void in
                    if let error {
                        once.resume(throwing: PrintError.unreachable(name: name, reason: error.localizedDescription))
                    } else if done {
                        once.resume(returning: ())
                    } else {
                        once.resume(throwing: PrintError.unreachable(name: name, reason: "it did not take the job."))
                    }
                    Task { @MainActor in
                        release()
                    }
                }
                if !started {
                    once.resume(throwing: PrintError.unreachable(name: name, reason: "it did not take the job."))
                    release()
                }
            }
        } onCancel: {
            // The print is dismissed before the wait ends, so the pass does not return with the system still working on it.
            Task { @MainActor in
                UIPrintInteractionController.shared.dismiss(animated: false)
                once.resume(throwing: CancellationError())
            }
        }
    }

    // MARK: Pure

    /// The sheet in points, which the printer's paper is chosen for.
    static func pageSize(of job: SheetJob) -> CGSize {
        let paper: LayoutSize = job.plan.plan.area.paper
        return CGSize(width: paper.width, height: paper.height)
    }

    /// Two-sided only when the printer does the turning: a pass of a job done by hand is one-sided.
    static func duplex(for job: SheetJob) -> UIPrintInfo.Duplex {
        job.plan.plan.duplex && !job.plan.manualDuplex ? UIPrintInfo.Duplex.longEdge : UIPrintInfo.Duplex.none
    }

    /// The job was planned for the queue `queue` (there is one queue, the printer chosen last).
    static func isFor(_ job: SheetJob, queue: String) -> Bool {
        job.printer.id == "system:" + queue
    }

    static func outputType(for job: SheetJob) -> UIPrintInfo.OutputType {
        // Photo output is what lets the printer print to the edge, which a job planned without margins counts on.
        let gray: Bool = job.settings.color == .gray
        if job.plan.plan.area.margins == LayoutInsets(top: 0, left: 0, bottom: 0, right: 0) {
            return gray ? UIPrintInfo.OutputType.photoGrayscale : UIPrintInfo.OutputType.photo
        }
        return gray ? UIPrintInfo.OutputType.grayscale : UIPrintInfo.OutputType.general
    }

    @MainActor
    static func printInfo(for job: SheetJob) -> UIPrintInfo {
        let info: UIPrintInfo = UIPrintInfo.printInfo()
        info.jobName = job.name
        info.orientation = .portrait
        info.duplex = duplex(for: job)
        info.outputType = outputType(for: job)
        return info
    }
}

/// Gives the printer's sheet closest to the paper the pages were laid out on; without it AirPrint picks its own default
/// and a page laid out on A4 could come out on Letter.
@MainActor
private final class PaperChooser: NSObject, UIPrintInteractionControllerDelegate {
    private let pageSize: CGSize

    init(pageSize: CGSize) {
        self.pageSize = pageSize
    }

    func printInteractionController(_ printInteractionController: UIPrintInteractionController,
                                    choosePaper paperList: [UIPrintPaper]) -> UIPrintPaper {
        UIPrintPaper.bestPaper(forPageSize: pageSize, withPapersFrom: paperList)
    }
}

/// Draws the pages of a PDF of sheets onto the printer's paper at real size (points to points) from its top-left corner.
/// Nothing is scaled to fit: the Kit already placed each page on a sheet the size of the paper.
final class IOSPrintRenderer: UIPrintPageRenderer {
    private let pdf: CGPDFDocument
    private let file: URL

    /// The pages are read from the file as they are drawn, so a big job is not held in memory. The file is removed when
    /// the renderer goes, which is after the system has drawn the last page, even of a job that was cancelled.
    init?(file: URL) {
        guard let pdf: CGPDFDocument = CGPDFDocument(file as CFURL) else { return nil }
        self.pdf = pdf
        self.file = file
        super.init()
    }

    deinit {
        try? FileManager.default.removeItem(at: file)
    }

    override var numberOfPages: Int { pdf.numberOfPages }

    override func drawPage(at pageIndex: Int, in printableRect: CGRect) {
        // CGPDFDocument pages are 1-based.
        guard let context: CGContext = UIGraphicsGetCurrentContext(), let page: CGPDFPage = pdf.page(at: pageIndex + 1) else { return }
        let box: CGRect = page.getBoxRect(.cropBox)
        context.saveGState()
        // PDF space has its origin at the bottom left; flip so the PDF's top edge meets the paper's, 1:1.
        context.translateBy(x: paperRect.minX - box.minX, y: paperRect.minY + box.maxY)
        context.scaleBy(x: 1, y: -1)
        context.drawPDFPage(page)
        context.restoreGState()
    }
}
#endif

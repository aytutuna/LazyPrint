import CoreGraphics
import XCTest
@testable import LazyPrintKit

// Mirrors PrintFixtures in windows/LazyPrint.App.Tests/PrintFixtures.cs: planned jobs for the printers' tests. The
// documents are real PDFs of plain letter pages, opened by the real loader.

enum PrintFixtures {
    static func printer(_ route: PrinterRoute = .system, name: String = "Test Printer") -> PrinterInfo {
        let id = route == .demo ? PrinterMerge.demoId : route == .ipp ? "ipp:test" : "system:" + name
        return PrinterInfo(id: id, name: name, model: nil, address: nil, route: route, ippEndpoint: nil, isDefault: false,
                           state: .idle, problems: [], supplies: [])
    }

    static func letter(_ edit: (inout PrintSettings) -> Void = { _ in }) -> PrintSettings {
        var settings = PrintSettings()
        settings.paperId = "letter"
        edit(&settings)
        return settings
    }

    /// A job of one document, planned as the app plans it.
    static func job(_ settings: PrintSettings, document: OpenedDocument, printer: PrinterInfo = printer(),
                    capabilities: PrinterCapabilities? = nil, id: String = "job", prefs: PrinterPrefs = PrinterPrefs()) -> SheetJob {
        let plan = PrintJobs.plan([document.loaded], pageRange: nil, settings: settings, printer: capabilities,
                                  prefs: prefs)
        return SheetJob(name: document.loaded.name, printer: printer, capabilities: capabilities, settings: settings,
                        plan: plan, documents: [document], id: id)
    }
}

extension XCTestCase {
    /// A folder in the temp folder that is removed when the test ends.
    func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lazyprint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A PDF of `pages` pages of the given size, each a different gray, written as `name` in `folder`.
    func writePDF(named name: String, pages: Int, width: Double = 612, height: Double = 792, in folder: URL) throws -> URL {
        let url = folder.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: 0.2 + 0.15 * Double(page % 5), alpha: 1))
            context.fill(box.insetBy(dx: 100, dy: 100))
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// A PDF of letter pages, opened by the real loader.
    func openLetterPDF(pages: Int, named name: String = "Letter.pdf") throws -> OpenedDocument {
        try DocumentLoader().load(try writePDF(named: name, pages: pages, in: try tempFolder()))
    }
}

/// Takes the reports where they are made (they come from the printer's own thread).
final class Reports: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [JobStatus] = []

    var all: [JobStatus] {
        lock.lock()
        defer { lock.unlock() }
        return list
    }

    var callback: @Sendable (JobStatus) -> Void {
        { [self] status in
            lock.lock()
            list.append(status)
            lock.unlock()
        }
    }
}

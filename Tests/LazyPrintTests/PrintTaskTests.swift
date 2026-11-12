import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/PrintTaskTests.cs: the same cases.

private func makePrinter(_ sides: [String]) -> PrinterCapabilities {
    var printer = PrinterCapabilities()
    printer.sidesSupported = sides
    return printer
}

final class PrintTaskTests: XCTestCase {
    private let duplex = makePrinter(["one-sided", "two-sided-long-edge", "two-sided-short-edge"])
    private let oneSidedOnly = makePrinter(["one-sided"])

    private func settings(_ edit: (inout PrintSettings) -> Void = { _ in }) -> PrintSettings {
        var s = PrintSettings()
        edit(&s)
        return s
    }

    func test_rawValues_areTheStoredNames() {
        XCTAssertEqual(PrintTask.allCases.map(\.rawValue),
                       ["document", "twoSided", "booklet", "handouts", "photos", "photoSheet", "testPage", "scanAndPrint", "fromPhone"])
    }

    func test_tryParse_isExact() {
        for task in PrintTask.allCases { XCTAssertEqual(PrintTask.tryParse(task.rawValue), task) }
        XCTAssertNil(PrintTask.tryParse(nil))
        XCTAssertNil(PrintTask.tryParse(""))
        XCTAssertNil(PrintTask.tryParse("poster"))
        XCTAssertNil(PrintTask.tryParse("Document"))
        XCTAssertNil(PrintTask.tryParse("photosheet"))
    }

    func test_catalog_listsEveryTaskOnce_inStartScreenOrder() {
        XCTAssertEqual(TaskCatalog.all.map(\.task), PrintTask.allCases)
        XCTAssertEqual(TaskCatalog.all.map(\.title),
                       ["Print a document", "Two-sided", "Booklet", "Handouts", "Photo prints", "Photo sheet",
                        "Test page", "Scan and print", "From your phone"])
        XCTAssertEqual(TaskCatalog.all.map(\.iconKey), PrintTask.allCases.map(\.rawValue))
        XCTAssertEqual(TaskCatalog.all.map(\.group),
                       [.documents, .documents, .documents, .documents, .photos, .photos, .other, .other, .other])
        XCTAssertEqual(TaskCatalog.all.map(\.opensFiles), [true, true, true, true, true, true, false, false, false])
        for definition in TaskCatalog.all { XCTAssertEqual(TaskCatalog.definition(definition.task), definition) }
    }

    func test_catalog_texts_areShort() {
        XCTAssertEqual(TaskGroup.allCases.map(\.title), ["Documents", "Photos", "Other"])
        for definition in TaskCatalog.all {
            XCTAssertTrue((1...6).contains(StatusLine.words(definition.title)), definition.title)
            XCTAssertTrue((1...15).contains(StatusLine.words(definition.subtitle)), definition.subtitle)
            XCTAssertTrue(definition.subtitle.hasSuffix("."), definition.subtitle)
        }
    }

    func test_tasks_theIPhoneHasNoPhoneWindow() {
        XCTAssertEqual(TaskCatalog.tasks(for: .windows).map(\.task), PrintTask.allCases)
        XCTAssertEqual(TaskCatalog.tasks(for: .mac).map(\.task), PrintTask.allCases)
        XCTAssertEqual(TaskCatalog.tasks(for: .ios).map(\.task), PrintTask.allCases.filter { $0 != .fromPhone })
    }

    func test_availability_testPageNeedsAPrinter_scanAndPrintNeedsLazyScan() {
        let all = TaskContext(hasPrinter: true, lazyScanInstalled: true, platform: .windows)
        for task in PrintTask.allCases {
            XCTAssertEqual(TaskCatalog.availability(of: task, context: all), .available)
        }

        var withoutPrinter = all
        withoutPrinter.hasPrinter = false
        let noPrinter = TaskCatalog.availability(of: .testPage, context: withoutPrinter)
        XCTAssertFalse(noPrinter.isAvailable)
        XCTAssertEqual(noPrinter.reason, "Needs a printer")

        var withoutScan = all
        withoutScan.lazyScanInstalled = false
        let noScan = TaskCatalog.availability(of: .scanAndPrint, context: withoutScan)
        XCTAssertFalse(noScan.isAvailable)
        XCTAssertEqual(noScan.reason, "Needs Lazy Scan")

        // The others can be started before a printer is found.
        let none = TaskContext(hasPrinter: false, lazyScanInstalled: false, platform: .mac)
        for task in PrintTask.allCases where task != .testPage && task != .scanAndPrint {
            XCTAssertEqual(TaskCatalog.availability(of: task, context: none), .available)
        }
    }

    func test_apply_document_onePerSide_twoSidedWhenThePrinterCan() {
        let start = settings { $0.pagesPerSheet = 4; $0.booklet = true; $0.scaling = .fill; $0.copies = 3 }
        let s = TaskCatalog.apply(.document, to: start, printer: duplex)
        XCTAssertEqual(s.taskId, "document")
        XCTAssertEqual(s.pagesPerSheet, 1)
        XCTAssertFalse(s.booklet)
        XCTAssertEqual(s.scaling, .shrinkToFit)
        XCTAssertEqual(s.sides, .longEdge)
        XCTAssertEqual(s.copies, 3)

        let longEdge = settings { $0.sides = .longEdge }
        XCTAssertEqual(TaskCatalog.apply(.document, to: longEdge, printer: oneSidedOnly).sides, .oneSided)
        XCTAssertEqual(TaskCatalog.apply(.document, to: longEdge, printer: nil).sides, .oneSided)
    }

    func test_apply_twoSided_longEdge_whateverThePrinterCan() {
        for printer in [duplex, oneSidedOnly, nil] {
            let s = TaskCatalog.apply(.twoSided, to: settings { $0.pagesPerSheet = 2; $0.booklet = true }, printer: printer)
            XCTAssertEqual(s.taskId, "twoSided")
            XCTAssertEqual(s.sides, .longEdge)
            XCTAssertEqual(s.pagesPerSheet, 1)
            XCTAssertFalse(s.booklet)
        }
    }

    func test_apply_documentAndTwoSided_backToFullScale() {
        let start = settings { $0.scale = 50 }
        XCTAssertEqual(TaskCatalog.apply(.document, to: start, printer: nil).scale, 100)
        XCTAssertEqual(TaskCatalog.apply(.twoSided, to: start, printer: nil).scale, 100)
    }

    func test_apply_booklet_handouts() {
        let booklet = TaskCatalog.apply(.booklet, to: PrintSettings(), printer: nil)
        XCTAssertEqual(booklet.taskId, "booklet")
        XCTAssertTrue(booklet.booklet)
        XCTAssertEqual(booklet.sides, .longEdge)

        let handouts = TaskCatalog.apply(.handouts, to: booklet, printer: nil)
        XCTAssertEqual(handouts.taskId, "handouts")
        XCTAssertEqual(handouts.pagesPerSheet, 2)
        XCTAssertTrue(handouts.pageBorders)
        XCTAssertFalse(handouts.booklet)
        // The booklet's two-sided choice is not carried over.
        XCTAssertEqual(handouts.sides, .oneSided)
    }

    func test_apply_bookletAndHandouts_afterPhotoSheet_doNotKeepItsFill() {
        let sheet = TaskCatalog.apply(.photoSheet, to: PrintSettings(), printer: nil)
        XCTAssertEqual(sheet.scaling, .fill)
        XCTAssertEqual(TaskCatalog.apply(.booklet, to: sheet, printer: nil).scaling, .shrinkToFit)
        XCTAssertEqual(TaskCatalog.apply(.handouts, to: sheet, printer: nil).scaling, .shrinkToFit)
    }

    func test_apply_documentTasks_putQualityBackToNormalAndLeaveColor() {
        let start = settings { $0.quality = .best; $0.color = .gray }
        for task in [PrintTask.document, .twoSided, .booklet, .handouts] {
            let applied = TaskCatalog.apply(task, to: start, printer: nil)
            XCTAssertEqual(applied.quality, .normal, "\(task)")
            XCTAssertEqual(applied.color, .gray, "\(task)")
        }
        let photos = TaskCatalog.apply(.photos, to: PrintSettings(), printer: nil)
        XCTAssertEqual(TaskCatalog.apply(.document, to: photos, printer: nil).quality, .normal)
    }

    func test_apply_photos_photoSheet() {
        let start = settings { $0.color = .gray; $0.photoSizeId = "5x7"; $0.photoFill = false; $0.booklet = true; $0.cutMarks = false }
        let photos = TaskCatalog.apply(.photos, to: start, printer: nil)
        XCTAssertEqual(photos.taskId, "photos")
        XCTAssertEqual(photos.layoutStyle, .photoPrints)
        XCTAssertEqual(photos.photoSizeId, "4x6")
        XCTAssertTrue(photos.photoFill)
        XCTAssertEqual(photos.quality, .best)
        XCTAssertEqual(photos.color, .color)
        XCTAssertFalse(photos.booklet)
        XCTAssertTrue(photos.cutMarks)

        let sheet = TaskCatalog.apply(.photoSheet, to: start, printer: nil)
        XCTAssertEqual(sheet.taskId, "photoSheet")
        XCTAssertEqual(sheet.layoutStyle, .photoSheet)
        XCTAssertEqual(TaskCatalog.apply(.booklet, to: sheet, printer: nil).layoutStyle, .pages)
        XCTAssertEqual(sheet.pagesPerSheet, 4)
        XCTAssertEqual(sheet.scaling, .fill)
        XCTAssertTrue(sheet.cutMarks)
        XCTAssertFalse(sheet.booklet)
        XCTAssertEqual(sheet.color, .gray)
    }

    func test_apply_document_startsFromTheDefaults() {
        var worn = TaskCatalog.apply(.booklet, to: settings { $0.paperId = "a4"; $0.copies = 2; $0.color = .gray }, printer: nil)
        worn.margin = .custom
        worn.orientation = .landscape
        worn.rightToLeft = true
        worn.photoSizeId = "5x7"
        let fresh = settings { $0.paperId = "a4"; $0.copies = 2; $0.color = .gray }
        XCTAssertEqual(TaskCatalog.apply(.document, to: worn, printer: nil), TaskCatalog.apply(.document, to: fresh, printer: nil))
    }

    func test_apply_tasksWithoutSettings_onlyRememberTheTask() {
        let start = settings { $0.copies = 5; $0.sides = .shortEdge; $0.booklet = true }
        for task in [PrintTask.testPage, .scanAndPrint, .fromPhone] {
            var expected = start
            expected.taskId = task.rawValue
            XCTAssertEqual(TaskCatalog.apply(task, to: start, printer: duplex), expected)
        }
        // The start is left as it was.
        XCTAssertNil(start.taskId)
    }

    func test_sameInUse_ignoresOptionsTheLayoutDoesNotUse() {
        let document = TaskCatalog.apply(.document, to: PrintSettings(), printer: duplex)
        var other = document
        other.marginMm = 15
        XCTAssertTrue(PrintSettings.sameInUse(document, other))
        other = document
        other.photoSizeId = "5x7"
        XCTAssertTrue(PrintSettings.sameInUse(document, other))
        other = document
        other.orientation = .landscape
        XCTAssertFalse(PrintSettings.sameInUse(document, other))

        let booklet = TaskCatalog.apply(.booklet, to: PrintSettings(), printer: duplex)
        other = booklet
        other.orientation = .landscape
        XCTAssertTrue(PrintSettings.sameInUse(booklet, other))
    }
}

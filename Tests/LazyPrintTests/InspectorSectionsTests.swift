import XCTest
@testable import LazyPrintKit

// Mirrored by windows/LazyPrint.Core.Tests/InspectorSectionsTests.cs: the same cases (Lazy Scan's, for
// the print sections).

private func settings(_ edit: (inout PrintSettings) -> Void = { _ in }) -> PrintSettings {
    var s = PrintSettings()
    edit(&s)
    return s
}

final class InspectorSectionsTests: XCTestCase {
    func test_onlyThePrinterAndPages_startOpen() {
        XCTAssertEqual(InspectorSections.all, ["printer", "pages", "layout", "paper", "photos"])
        XCTAssertTrue(InspectorSections.openByDefault(InspectorSections.printer))
        XCTAssertTrue(InspectorSections.openByDefault(InspectorSections.pages))
        for id in [InspectorSections.layout, InspectorSections.paper, InspectorSections.photos] {
            XCTAssertFalse(InspectorSections.openByDefault(id), id)
        }
        func opened(_ task: PrintTask) -> String? {
            InspectorSections.openedBy(TaskCatalog.apply(task, to: PrintSettings(), printer: nil))
        }
        XCTAssertEqual(opened(.booklet), InspectorSections.layout)
        XCTAssertEqual(opened(.handouts), InspectorSections.layout)
        XCTAssertEqual(opened(.photos), InspectorSections.photos)
        XCTAssertEqual(opened(.photoSheet), InspectorSections.photos)
        XCTAssertNil(opened(.document))
        XCTAssertNil(opened(.twoSided))
        XCTAssertNil(opened(.testPage))
    }

    func test_titles_areShort() {
        XCTAssertEqual(InspectorSections.all.map { InspectorSections.title($0) }, ["Printer", "Pages", "Layout", "Paper", "Photos"])
        for id in InspectorSections.all {
            XCTAssertTrue((1...3).contains(StatusLine.words(InspectorSections.title(id))), id)
        }
    }

    func test_summaries_ofTheDefaults_sayLittle() {
        let s = PrintSettings()
        XCTAssertEqual(InspectorSections.summary(InspectorSections.printer, s), "")
        XCTAssertEqual(InspectorSections.pagesSummary(s), "")
        XCTAssertEqual(InspectorSections.layoutSummary(s), "")
        XCTAssertEqual(InspectorSections.paperSummary(s), "")
        XCTAssertEqual(InspectorSections.photosSummary(s), "4 \u{00D7} 6 in \u{00B7} Fill \u{00B7} Cut marks")
        XCTAssertEqual(InspectorSections.headerName(InspectorSections.pages, s), "Pages")
        XCTAssertEqual(InspectorSections.headerName(InspectorSections.photos, s), "Photos, 4 \u{00D7} 6 in \u{00B7} Fill \u{00B7} Cut marks")
    }

    func test_summaries_sayWhatIsOn() {
        let s = settings {
            $0.copies = 3
            $0.sides = .longEdge
            $0.pagesPerSheet = 2
            $0.pageBorders = true
            $0.paperId = "letter"
            $0.quality = .best
            $0.color = .gray
            $0.photoSizeId = "10x15cm"
            $0.photoFill = false
            $0.cutMarks = false
        }
        XCTAssertEqual(InspectorSections.pagesSummary(s), "3 copies \u{00B7} Two-sided")
        XCTAssertEqual(InspectorSections.layoutSummary(s), "2 per side \u{00B7} Borders")
        XCTAssertEqual(InspectorSections.paperSummary(s), "Letter \u{00B7} Best \u{00B7} Gray")
        XCTAssertEqual(InspectorSections.photosSummary(s), "10 \u{00D7} 15 cm \u{00B7} Fit")
        XCTAssertEqual(InspectorSections.headerName(InspectorSections.layout, s), "Layout, 2 per side \u{00B7} Borders")
        XCTAssertEqual(InspectorSections.summary(InspectorSections.layout, s), "2 per side \u{00B7} Borders")
    }

    func test_pagesSummary_copies_andTheEdge() {
        XCTAssertEqual(InspectorSections.pagesSummary(settings { $0.sides = .longEdge }), "Two-sided")
        XCTAssertEqual(InspectorSections.pagesSummary(settings { $0.sides = .shortEdge }), "Two-sided, short edge")
        XCTAssertEqual(InspectorSections.pagesSummary(settings { $0.copies = 2; $0.collate = false }), "2 copies \u{00B7} Not collated")
        // Collating means nothing for one copy; a count past the limit is clamped.
        XCTAssertEqual(InspectorSections.pagesSummary(settings { $0.collate = false }), "")
        XCTAssertEqual(InspectorSections.pagesSummary(settings { $0.copies = 500 }), "99 copies")
    }

    func test_layoutSummary_booklet_scalingAndDirection() {
        // A booklet ignores the pages per side and the borders.
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.booklet = true; $0.pagesPerSheet = 4; $0.pageBorders = true }), "Booklet")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.booklet = true; $0.rightToLeft = true }),
                       "Booklet \u{00B7} Right to left")
        // Direction only matters with several pages.
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.rightToLeft = true; $0.pageBorders = true }), "")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scaling = .actualSize }), "Actual size")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scaling = .fit }), "Fit to page")
        XCTAssertEqual(InspectorSections.layoutSummary(settings {
            $0.pagesPerSheet = 4
            $0.pageBorders = true
            $0.rightToLeft = true
            $0.scaling = .fill
        }), "4 per side \u{00B7} Borders \u{00B7} Right to left +1")
    }

    func test_paperSummary_skipsAutomaticNormalColor() {
        XCTAssertEqual(InspectorSections.paperSummary(settings { $0.paperId = "a4" }), "A4")
        XCTAssertEqual(InspectorSections.paperSummary(settings { $0.quality = .draft }), "Draft")
        XCTAssertEqual(InspectorSections.paperSummary(settings { $0.color = .gray }), "Gray")
        // A paper this version does not know is the automatic one.
        XCTAssertEqual(InspectorSections.paperSummary(settings { $0.paperId = "zine" }), "")
    }

    func test_photosSummary_anUnknownSize_showsItsId() {
        XCTAssertEqual(InspectorSections.photosSummary(settings { $0.photoSizeId = "page" }), "Whole page \u{00B7} Fill \u{00B7} Cut marks")
        XCTAssertEqual(InspectorSections.photosSummary(settings { $0.photoSizeId = "6x8" }), "6x8 \u{00B7} Fill \u{00B7} Cut marks")
    }

    func test_summaries_namePageOrderAndOrientation() {
        let s = settings { $0.pageSelection = .odd; $0.reverseOrder = true; $0.orientation = .landscape }
        XCTAssertEqual(InspectorSections.pagesSummary(s), "Odd pages \u{00B7} Reverse order")
        XCTAssertEqual(InspectorSections.layoutSummary(s), "Landscape")
        XCTAssertEqual(InspectorSections.pagesSummary(settings { $0.pageSelection = .even }), "Even pages")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.booklet = true; $0.orientation = .landscape }), "Booklet")
    }

    func test_pagesSummary_leavesOutTwoSidedForAPoster() {
        XCTAssertEqual(InspectorSections.pagesSummary(settings { $0.sides = .longEdge; $0.poster = 2 }), "")
    }

    func test_summary_marginNoneWithAnEdge_showsTheEdge() {
        XCTAssertEqual(InspectorSections.layoutSummary(settings { _ in }, edge: 4.3), "4.3 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { _ in }, edge: 0), "")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.margin = .small }, edge: 6.4), "6.4 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.margin = .normal }, edge: 4.3), "12 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.margin = .custom; $0.marginMm = 3 }, edge: 3), "3 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scaling = .actualSize }, edge: 4.3), "Actual size · 4.3 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scaling = .fill }, edge: 4.3), "Fill · 4.3 mm margins")
    }

    func test_summary_photoLayouts_showNoMarginPart() {
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.layoutStyle = .photoSheet; $0.margin = .normal }, edge: 4.3),
                       "Photo sheet")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.layoutStyle = .photoSheet }, edge: 4.3, printedScale: 96),
                       "Photo sheet")
    }

    func test_summary_aLonePageShowsWhatItPrintsAt() {
        XCTAssertEqual(InspectorSections.layoutSummary(settings { _ in }, edge: 4.3, printedScale: 96), "96 % \u{00B7} 4.3 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scale = 50 }, printedScale: 50), "50 %")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scale = 50 }), "50 %")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scale = 80 }, printedScale: 100), "")
    }

    func test_layoutSummary_namesAPosterAndTheMarginsThatApply() {
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.poster = 3; $0.pagesPerSheet = 4; $0.rightToLeft = true }), "Poster 3 \u{00D7} 3")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.margin = .normal }), "12 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scaling = .fit; $0.margin = .small }), "Fit to page \u{00B7} 6 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scaling = .actualSize; $0.margin = .normal }), "Actual size · 12 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.scaling = .fill; $0.margin = .normal }), "Fill · 12 mm margins")
        XCTAssertEqual(InspectorSections.layoutSummary(settings { $0.poster = 2; $0.scaling = .fill; $0.margin = .normal }),
                       "Poster 2 \u{00D7} 2 \u{00B7} 12 mm margins")
    }
}

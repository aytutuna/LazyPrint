#if os(macOS)
import XCTest
import LazyPrintKit
@testable import LazyPrintMac

// The options a job is sent to a queue with: the ones that stop CUPS from laying the sheets out again are always there.

final class CupsOptionsTests: XCTestCase {
    private let forced = [
        "document-format": "application/pdf",
        "orientation-requested": "3",
        "print-scaling": "none",
        "fit-to-page": "false",
        "scaling": "100",
        "number-up": "1",
        "outputorder": "normal",
    ]

    private func options(sides: Sides = .oneSided, copies: Int = 1, collate: Bool = true, color: ColorChoice = .color,
                         quality: QualityChoice = .normal, media: String? = nil, duplexPass: Bool = false) -> [String: String] {
        CupsOptions.forJob(sides: sides, copies: copies, collate: collate, color: color, quality: quality, media: media,
                           duplexPass: duplexPass)
    }

    func test_forJob_theTrayAndPaperTypeAreSentOnlyWhenChosen() {
        let plain = CupsOptions.forJob(sides: .oneSided, copies: 1, collate: true, color: .color, quality: .normal, media: nil,
                                       duplexPass: false)
        XCTAssertNil(plain["media-source"])
        XCTAssertNil(plain["media-type"])
        let chosen = CupsOptions.forJob(sides: .oneSided, copies: 1, collate: true, color: .color, quality: .normal, media: nil,
                                        duplexPass: false, source: "tray-2", type: "photographic-glossy")
        XCTAssertEqual(chosen["media-source"], "tray-2")
        XCTAssertEqual(chosen["media-type"], "photographic-glossy")
    }

    func test_forJob_alwaysForcesTheLayoutOptions() {
        let combinations: [[String: String]] = [
            options(),
            options(sides: .longEdge, copies: 3, collate: false, color: .gray, quality: .best, media: "na_letter_8.5x11in"),
            options(sides: .shortEdge, duplexPass: true),
        ]
        for result in combinations {
            for (name, value) in forced {
                XCTAssertEqual(result[name], value, name)
            }
        }
    }

    func test_forJob_oneSidedColorNormal_isTheBaseSet() {
        var expected = forced
        expected["sides"] = "one-sided"
        expected["print-color-mode"] = "color"
        expected["print-quality"] = "4"
        XCTAssertEqual(options(), expected)
    }

    func test_forJob_sides() {
        XCTAssertEqual(options(sides: .oneSided)["sides"], "one-sided")
        XCTAssertEqual(options(sides: .longEdge)["sides"], "two-sided-long-edge")
        // The planner turns the backs for a short edge, so the request is always long edge.
        XCTAssertEqual(options(sides: .shortEdge)["sides"], "two-sided-long-edge")
    }

    func test_forJob_aPassDoneByHand_printsOneSide() {
        XCTAssertEqual(options(sides: .longEdge, duplexPass: true)["sides"], "one-sided")
    }

    func test_forJob_copies_onlyAboveOne() {
        XCTAssertNil(options(copies: 1)["copies"])
        XCTAssertNil(options(copies: 1)["multiple-document-handling"])
        XCTAssertEqual(options(copies: 4)["copies"], "4")
        XCTAssertEqual(options(copies: 4, collate: true)["multiple-document-handling"], "separate-documents-collated-copies")
        XCTAssertEqual(options(copies: 4, collate: false)["multiple-document-handling"], "separate-documents-uncollated-copies")
    }

    func test_forJob_color() {
        XCTAssertEqual(options(color: .color)["print-color-mode"], "color")
        XCTAssertEqual(options(color: .gray)["print-color-mode"], "monochrome")
    }

    func test_forJob_quality() {
        XCTAssertEqual(options(quality: .draft)["print-quality"], "3")
        XCTAssertEqual(options(quality: .normal)["print-quality"], "4")
        XCTAssertEqual(options(quality: .best)["print-quality"], "5")
    }

    func test_forJob_media_onlyWhenGiven() {
        XCTAssertNil(options(media: nil)["media"])
        XCTAssertEqual(options(media: "iso_a4_210x297mm")["media"], "iso_a4_210x297mm")
    }
}
#endif

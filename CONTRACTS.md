# Lazy Print — module contracts

Native printing app for Windows, macOS and the iPhone, the sister of Lazy Scan (`../LazyScan`, whose layout, conventions and much of whose code it shares). SwiftUI, macOS 14+ and iOS 18+, `swift-tools-version: 6.0` with the Swift 5 language mode (`swiftLanguageModes: [.v5]`), SwiftPM, **system frameworks only** (AppKit, SwiftUI, PDFKit, CoreGraphics, ImageIO, UniformTypeIdentifiers, CryptoKit, Security, Network and the DNS-SD library; UIKit on iOS). The Windows app is .NET 10 and WPF, with a Core library that has no dependencies. No third-party code anywhere except ZXing.Net for the pairing QR code on Windows, as in Lazy Scan. UIKit only in `LazyPrintIOS`; AppKit, SwiftUI and UIKit never in `LazyPrintKit`, and `LazyPrintKit` keeps CoreGraphics to the files that draw and the app state (`Render/`, `App/`), so its protocol and layout code needs Foundation alone.

The package's targets:
- `LazyPrintKit` (`Sources/LazyPrintKit/`): everything the Mac and the iPhone share: `Core` (tasks, settings, printers, problems, the troubleshooter), `Layout` (paper, page placement, N-up, booklets, photo sizes, two-sided by hand, the test page), `Ipp` (driverless printers: the IPP codec, attributes, jobs, PWG raster, addresses, trust, the client), `Companion` (the phone link, from Lazy Scan's), `Persistence`, `Render` (drawing a sheet with CoreGraphics), the demo printer, `AppState` and the protocols of the system services an app shell passes in.
- `LazyPrintMac` (`Sources/LazyPrintMac/`): the Mac's views and its system services (printing to the printers macOS has set up, the troubleshooter's system checks, file actions). Every file is wrapped whole in `#if os(macOS)`.
- `LazyPrintIOS` (`Sources/LazyPrintIOS/`): the iPhone's views and services. Every file is wrapped whole in `#if os(iOS)`.
- `LazyPrint` (`Sources/LazyPrint/main.swift`): the Mac app.
- `ios/`: the iPhone app's Xcode project, written by XcodeGen from `ios/project.yml` (not checked in); its app target `LazyPrintiOS` only starts `LazyPrintIOSApp`.
- Tests: `Tests/LazyPrintTests` (shared, `@testable import LazyPrintKit`), `Tests/LazyPrintMacTests`, `Tests/LazyPrintIOSTests`; fixtures both suites read in `Tests/Fixtures/`.

The Windows solution (`windows/LazyPrint.sln`):
- `LazyPrint.Core` (`net10.0`, no dependencies): the twins of `LazyPrintKit`'s Core, Layout, Ipp, Companion and Persistence, plus the protocol logic only Windows has (the print spooler's states and the Windows service checks).
- `LazyPrint.Core.Tests` (xUnit): the same cases as `Tests/LazyPrintTests`, reading the same fixtures.
- `LazyPrint.App` (`net10.0-windows10.0.19041.0`, WPF): the shell, reading PDFs with `Windows.Data.Pdf`, printing through the spooler (XPS) and straight to IPP printers, finding printers on the network, the phone link's Windows pieces.
- `LazyPrint.App.Tests` (xUnit): what the app does with the system, against files and stand-ins (an XPS file instead of a printer, a loopback IPP printer).

## Global rules

1. Platform parity. Every change to shared logic (Core, Layout, Ipp, Companion, Persistence) lands in C# and Swift in the same change, with mirrored tests: `windows/LazyPrint.Core.Tests` and `Tests/LazyPrintTests`, same cases, same names (`ImpositionTests`, `IppCodecTests`). A C# file and its Swift twin use the same words (`IppCodec.cs`, `IppCodec.swift`; `PwgRaster.cs`, `PwgRaster.swift`) and start with a line naming the twin. Byte formats (IPP requests, PWG raster, the print package) are pinned by golden files that C# writes and Swift checks. CI must be green on both (`.github/workflows/ci.yml`) before a change counts as done.
2. Any helper not listed in this document is `private`/`fileprivate` (Swift) or `private`/`internal` (C#).
3. Coordinates:
   - Layout: points (1/72 inch), origin TOP-LEFT of the sheet as it goes into the printer (portrait, short edge first), x right, y down. A quarter turn is clockwise as seen on the sheet.
   - Source pages: points, origin top-left of the page as it is shown (after a PDF page's `/Rotate` or a photo's orientation tag).
   - Pixels (rasters, bitmaps): origin top-left, x right, y down.
   - PDF user space and CoreGraphics: origin bottom-left; converted only where a sheet is drawn (`Render/`, the Windows `SheetRenderer`).
4. Errors thrown across modules are `PrintError` (C# `PrintException` carrying a `PrintError`).
5. Settings files load across versions, by Lazy Scan's rules (its CONTRACTS.md, Global rule 6) unchanged: optional-with-default fields decoded leniently, the first case of a persisted enum is its default, unknown raw values decode as the default, keys never change, an unreadable file is moved aside as `<name>.unreadable-<yyyyMMdd-HHmmss>.json` and one that cannot be read at all is never overwritten. `Persistence` (`StoreFiles`) is Lazy Scan's, renamed. Settings live in `%APPDATA%\Lazy Print` and `~/Library/Application Support/Lazy Print`.
6. User-facing text: short. A status line is six words at most, with the full sentence for screen readers (Lazy Scan's `StatusLine`). A problem is titled by what is wrong ("Out of paper", "Paper jam") and says what to do. Texts both platforms show live in Core, in a `...Text` type, the same words on both.

## Names

The product is "Lazy Print" in text, `LazyPrint` in code. Lazy Scan's identifiers with Print for Scan: `com.lazyprint.lazyprint` (iPhone), `local.lazyprint.app` (the Mac app `scripts/make_app.sh` builds), `LAZYPRINT_*` environment flags, the prefix `lp-`. The phone link: DNS-SD `_lazyprint._tcp`, port 52732 (Lazy Scan has 52731, so both can run on one PC), pairing codes `lazyprint://pair?...`, the mutex `Local\LazyPrint.PhoneLink`. The two apps find each other by the URL schemes `lazyprint:` and `lazyscan:` (see "Hand-off").

## Layout/ (paper, placement, N-up, booklets, photos)

Pure functions over sizes; nothing here reads a file or draws. `PaperSize` is Lazy Scan's (`Core/PaperSize.swift`, `PaperSize.cs`) with its regional default; `PrintCopies` and the ruler page (`PrintCalibration`) come from Lazy Scan's `PrintLayout` unchanged.

```swift
public struct LayoutSize: Equatable, Sendable { public var width: Double; public var height: Double }   // points
public struct LayoutRect: Equatable, Sendable { public var x, y, width, height: Double }               // points, top-left
public struct LayoutInsets: Equatable, Sendable { public var top, left, bottom, right: Double }
public struct LayoutPoint: Equatable, Sendable { public var x, y: Double }

/// Where a printer can put ink on its paper.
public struct PrintableArea: Equatable, Sendable {
    public var paper: LayoutSize          // portrait: width <= height
    public var margins: LayoutInsets      // the printer's unprintable edges; zero for borderless
    public var printable: LayoutRect { get }
    /// Each margin raised to the larger of it and its opposite, so a side turned 180° lands in the same box.
    public var symmetric: PrintableArea { get }
}

/// One page of one document, at the size it is shown.
public struct SourcePage: Equatable, Sendable { public var document: Int; public var index: Int; public var size: LayoutSize }

public enum Scaling: String, Codable, CaseIterable, Sendable {
    case shrinkToFit   // the default: a page larger than the printable area is made smaller, others print at real size
    case fit           // made as large as fits
    case actualSize    // 100 %, cut by the margins if it must be (PlanWarning.clipped)
    case fill          // fills its frame, cropped in the middle (photos)
}

/// The paper edge the sheet turns over on, as in IPP and print dialogs.
public enum Sides: String, Codable, CaseIterable, Sendable { case oneSided, longEdge, shortEdge }

public struct LayoutOptions: Equatable, Sendable {
    public var pagesPerSheet: Int = 1              // 1, 2, 4, 6, 9 or 16
    public var booklet: Bool = false               // two pages per side, in booklet order, folded in the middle
    public var rightToLeft: Bool = false           // booklets and N-up read right to left
    public var scaling: Scaling = .shrinkToFit
    public var sides: Sides = .oneSided
    public var pageBorders: Bool = false           // a thin line around each page when there are several on a side
}

public struct Placement: Equatable, Sendable {
    public var page: SourcePage
    public var frame: LayoutRect        // on the sheet, the box the page's shown area fills after turning
    public var turns: Int               // quarter turns clockwise applied to the page, 0...3 (3 = a quarter counterclockwise)
    public var crop: LayoutRect?        // the part of the page shown (page points), for .fill; nil = whole page
}
public struct SheetSide: Equatable, Sendable { public var placements: [Placement]; public var borders: Bool }
public struct Sheet: Equatable, Sendable { public var front: SheetSide; public var back: SheetSide? }

public enum PlanWarning: Equatable, Sendable { case clipped(points: Double), paddedWithBlanks(count: Int), shrunk(percent: Int) }

public struct SheetPlan: Equatable, Sendable {
    public var area: PrintableArea       // the area actually used (symmetric when backs may turn)
    public var sheets: [Sheet]
    public var duplex: Bool              // every sheet has a back (blank if need be), so sideCount is even
    public var warnings: [PlanWarning]
    public var sideCount: Int { get }
}

public enum Imposition {
    public static func plan(_ pages: [SourcePage], options: LayoutOptions, area: PrintableArea) -> SheetPlan
}
```

Rules `Imposition.plan` keeps (each has a test):
- Paper is always fed portrait. A side that reads landscape (a landscape page alone, a 2- or 6-up grid that comes out landscape, a booklet spread) is worked out on a landscape "reading view" and turned onto the paper a quarter turn counterclockwise: the reading view's top goes to the paper's left edge, and its pages get `turns = 3`. The printer never needs an orientation setting.
- Backs are given as the back looks after the sheet is turned over on its long edge, top edge still at the top: the page image of a `two-sided-long-edge` job. A back is turned 180° exactly when the sheet turns over on its short edge: `shortEdge`, and every booklet back. The reading view does not change this. Worked cases (front's top edge T, bottom B, left L, right R; each a test): portrait long edge, back's top at T, no turn; portrait short edge, top at B, turn; landscape long edge (a calendar's flip), top at R, no turn; landscape short edge (a book's flip), top at L, turn; booklet, turn. So the duplex request is always long edge.
- When any back may be turned (two-sided, booklets, manual duplex), both sides are laid out in `area.symmetric`, so the front and the back line up and a turned back is not cut by an uneven margin.
- One page per side: the page is placed by `scaling` in the printable area, centred, and turned a quarter counterclockwise when it is landscape on portrait paper.
- Several per side: the grid (2, 4, 6, 9, 16 pages: 1×2, 2×2, 2×3, 3×3, 4×4, its longer count along the reading view's longer side, so 2 per side are two rows in the portrait view and two columns in the landscape one) is chosen once per job, from the first page: portrait or landscape reading view, whichever makes that page larger; on a tie the view where pages need no turn wins. Pages are read left to right, top to bottom in the reading view (right to left with `rightToLeft`). Each page is fitted to its cell (`fit`; `fill` crops it to the cell; `actualSize` and `shrinkToFit` mean `fit` here) and turned a quarter counterclockwise only when that makes it strictly larger.
- Booklet: always two-sided (`sides` is ignored). The pages are padded with blanks after the last page to a multiple of 4 (`paddedWithBlanks`); sheet k of n/4 has front (left, right) = (n−1−2k, 2k) and back = (2k+1, n−2−2k), swapped for `rightToLeft`; folded sheets nest in order. The spread's two halves are split at the paper's centre line (the fold), each half met with the printable area. `pagesPerSheet` is ignored.
- Several documents run on as one; a document does not start a new sheet.
- A blank page has no placement; with `duplex` every sheet has a back, so copies of a two-sided job never start on a back.

### Layout/PhotoLayout

```swift
public struct PhotoSize: Equatable, Sendable {
    public var id: String                  // "4x6", "5x7", "8x10", "3.5x5", "wallet", "10x15cm", "13x18cm", "page"
    public var title: String               // "4 × 6 in", "10 × 15 cm", "Whole page"
    public var size: LayoutSize?           // portrait; nil = the whole printable area
    public static let all: [PhotoSize]
}
public struct PhotoOptions: Equatable, Sendable {
    public var size: PhotoSize
    public var copiesEach: Int = 1
    public var fill: Bool = true           // crop to fill the size; false fits the whole photo with white bands
    public var cutMarks: Bool = true       // short gray marks at the corners when several fit on a sheet
}
public enum PhotoLayout {
    /// As many prints of the size as fit on each sheet (the cells turned when more fit), 3 mm apart, in photo order;
    /// a photo whose orientation differs from its cell is turned a quarter counterclockwise.
    public static func plan(_ photos: [SourcePage], options: PhotoOptions, area: PrintableArea) -> SheetPlan
    /// The cut marks of a planned side, as lines for the renderer: at the corners of its print cells, when more than one fits.
    public static func cutMarks(_ side: SheetSide, options: PhotoOptions, area: PrintableArea) -> [TestPageItem]
}
```

### Layout/PageRange

`PageRange.parse("1-3, 5, 8-", pageCount:) -> Result<[Int], PageRangeError>` (C#: `PageRangeResult` with `Pages` and `Error`) (0-based indices, in the order typed, repeats kept); errors name the problem ("Page 9 is past the end (8 pages)", "Type pages like 1-3, 5").

### Layout/ManualDuplex (two-sided on a printer that prints one side)

Both sides of every sheet in two passes: the fronts, then, once the user has put the stack back, the backs. Each pass is a one-sided job. How the stack must go back depends on the printer's paper path, which Lazy Print learns once per printer with one sheet (the two-sided check); until then it assumes the usual one (turn the stack over, backs upright).

```swift
public struct PaperPath: Codable, Equatable, Sendable {
    public var turnStackOver: Bool = true      // the user turns the stack over to reload it (false: reloads it as it lies)
    public var turnBacks: Bool = false         // backs come out upside down unless turned 180°
    public var checked: Bool = false           // the two-sided check was printed and answered
}
public struct DuplexPass: Equatable, Sendable {
    public var sides: [SheetSide]              // in the order sent to the printer
    public var marked: [Int]                   // indices in `sides` of blank backs that get the near-white dot
}
public enum ManualDuplex {
    public static func passes(_ plan: SheetPlan, path: PaperPath) -> (fronts: DuplexPass, backs: DuplexPass)
    /// The check sheet's two sides: a big "1" on the front and "2" on the back, each with an arrow to its top edge.
    public static func checkSheet(area: PrintableArea) -> (front: [TestPageItem], back: [TestPageItem])
    /// The answer to "Do the arrows on both sides point to the same edge?" turned into a paper path.
    public static func learn(_ answer: DuplexCheckAnswer, from path: PaperPath) -> PaperPath
}
public enum DuplexCheckAnswer: String, Sendable { case sameEdge, oppositeEdges, bothOnOneSide }
```

- Sheets stack in the output tray in the order they were printed, whichever way up they land, and the tray feeds its top sheet first: turning the stack over puts the first sheet on top, so the backs go in sheet order; reloading it as it lies puts the last sheet on top, so they go in reverse. Both passes are sent with the page order forced normal (the spooler's `JobPageOrder` Standard, CUPS `outputorder=normal`), so a driver set to reverse order cannot undo this.
- Every front gets a back. In reverse order a blank back gets one near-white dot (0.5 pt, gray 250) in a corner, so a driver that skips blank pages cannot put the backs out of step.
- `learn`: `sameEdge` keeps the path and marks it checked; `oppositeEdges` toggles `turnBacks`; `bothOnOneSide` toggles `turnStackOver` and leaves `checked` false, so the check runs again with the other reloading.
- `ManualDuplexText` holds the step card's words, the same on all three platforms: "Printing the fronts", "Take the 7 printed sheets out. Turn the stack over and put it back in the tray, top edge first." or, for the other paper path, "Put the stack back in the tray as it is, top edge first.", "Print the backs", "Check with one sheet", the check's question and its three answers. Counts are of sheets.

### Layout/TestPage

`TestPage.make(area:, info: TestPageInfo) -> [TestPageItem]`: what a test page shows, as drawing primitives the platforms render the same way (`.rect(LayoutRect, fill: TestColor)`, `.line(from:to:width:color:)`, `.text(String, at:, size:, bold:)`, `.arrow(LayoutRect, up: Bool)`): the printer's name, model, address and the date; cyan, magenta, yellow, black, red, green and blue bars; a gray ramp in 10 % steps; a fine-line grid for clogged nozzles; a 1-inch square and a 10 cm ruler to check real size (Lazy Scan's ruler); the printable area's edge drawn 2 mm inside it.

## Ipp/ (driverless printers)

IPP over HTTP (RFC 8010, 8011; PWG 5100.12 IPP Everywhere, 5100.7 media-col), as IPP Everywhere, AirPrint and Mopria printers speak it, with the transport conventions of Lazy Scan's `Escl/`: an ephemeral session, no proxy, 10 s requests, trust on first use for `ipps` pinned by `SpkiFingerprint`, busy printers retried with Lazy Scan's `EsclRetry` schedule.

### Ipp/IppCodec

```swift
public struct IppVersion: Equatable, Sendable { public var major: UInt8; public var minor: UInt8 }   // 2.0 sent; 1.x and 2.x read
public enum IppValue: Equatable, Sendable {
    case integer(Int32), boolean(Bool), enumValue(Int32), octets(Data), dateTime(Data), resolution(x: Int32, y: Int32, units: UInt8)
    case range(Int32, Int32), text(String), name(String), keyword(String), uri(String), uriScheme(String), charset(String)
    case language(String), mimeType(String), collection([IppAttribute]), outOfBand(UInt8)   // 0x10 unsupported, 0x12 unknown, 0x13 no-value
    case unknown(tag: UInt8, Data)        // a value tag this codec does not know, kept as it came
}
public struct IppAttribute: Equatable, Sendable { public var name: String; public var values: [IppValue] }
public struct IppGroup: Equatable, Sendable { public var tag: UInt8; public var attributes: [IppAttribute] }   // 0x01 operation, 0x02 job, 0x04 printer, 0x05 unsupported, any 0x00-0x0F delimiter kept
public struct IppMessage: Equatable, Sendable {
    public var version: IppVersion
    public var code: UInt16                              // operation id in a request, status code in a response
    public var requestId: Int32
    public var groups: [IppGroup]
    public var isSuccess: Bool { get }                   // code < 0x0100 (0x0001 and 0x0002 are successes too)
    public func encoded() -> Data
    public static func decode(_ data: Data) throws -> (message: IppMessage, documentOffset: Int)   // PrintError.badResponse
    /// The first attribute of that name outside the unsupported-attributes group.
    public subscript(_ name: String) -> IppAttribute? { get }
}
public enum IppOperation: UInt16 { case printJob = 0x0002, validateJob = 0x0004, cancelJob = 0x0008, getJobAttributes = 0x0009, getJobs = 0x000A, getPrinterAttributes = 0x000B }
```

`textWithLanguage` and `nameWithLanguage` decode to `.text` and `.name` (the language is dropped); the codec never writes them. Collections encode as `begCollection`, then per member a `memberAttrName` and its values, then `endCollection`, as RFC 8010 §3.1.6.

### Ipp/IppRequests

The requests both platforms send, byte for byte (golden files in `Tests/Fixtures/Ipp/requests/`, written by C#). Every request: version 2.0, then the operation group in this order: `attributes-charset` utf-8, `attributes-natural-language` en, `printer-uri` (always `ipp://` or `ipps://`, even for an address typed as http), `requesting-user-name`, then the operation's own attributes; then the job group for Print-Job; then the end tag. `requesting-user-name` is the account name on Windows and the Mac, "iPhone" on the iPhone (the same name for Cancel-Job, or printers refuse it). Names (`job-name`, `document-name`) are cut to 255 bytes at a UTF-8 boundary.

- `getPrinterAttributes(printerUri:)`: `requested-attributes` = `all`, `media-col-database`.
- `printJob(printerUri:, ticket: IppJobTicket)`: operation group adds `job-name`, `document-format`; job group, in this order: `copies` (only when > 1), `sides`, `print-color-mode`, `media-col` (or `media`, see below), `print-quality` (when chosen), `print-scaling` (when the printer lists it), `multiple-document-handling` (when the printer makes the copies).
- `getJobAttributes(printerUri:, jobId:)`: adds `job-id`, `requested-attributes` = `job-state`, `job-state-reasons`, `job-impressions-completed`.
- `cancelJob(printerUri:, jobId:)`: adds `job-id`.

On `0x0503` (version not supported), or when `ipp-versions-supported` lacks 2.0, the request goes again as 1.1, and the printer is remembered as 1.1 for the session.

```swift
public struct IppMediaChoice: Equatable, Sendable {
    public var entry: [IppAttribute]?        // a media-col-database entry as media-col: media-size (x and y), the four margins, media-type, media-source
    public var name: String                  // a PWG self-describing name, "na_letter_8.5x11in"; sent as media only without media-col-supported
}
public struct IppJobTicket: Equatable, Sendable {
    public var jobName: String
    public var documentFormat: String         // "application/pdf", "image/pwg-raster", "image/urf", "image/jpeg"
    public var copies: Int
    public var sides: String                  // "one-sided", "two-sided-long-edge"; "two-sided-short-edge" only for a document sent as is
    public var colorMode: String              // "color" or "monochrome"
    public var media: IppMediaChoice
    public var quality: Int?                  // print-quality 3/4/5, when chosen
    public var scaling: String?               // print-scaling "none" for imposed sheets, "fit" or "auto" for a document sent as is
    public var collatedCopies: Bool           // multiple-document-handling separate-documents-collated-copies
}
```

A database entry carries members of the printer's own (`media-key`, `media-size-name`, `media-info`, `media-color`, `media-source-properties`) that printers refuse back, so the job's `media-col` keeps only the members above, and of those only the ones `media-col-supported` lists when it lists any. The margins the layout assumed are the ones of the entry sent, so the printer cannot use others; borderless is an entry with zero margins (often only with a photo `media-type`, which the entry carries).

### Ipp/PrinterCapabilities, IppProblems

`PrinterCapabilities` is what Get-Printer-Attributes says, read leniently (a missing attribute gives the default): name (`printer-name`, else `printer-info`), `printer-make-and-model`, `printer-uuid`, `ipp-versions-supported`, `printer-state` (idle, processing, stopped), `printer-state-reasons`, `printer-state-message`, `printer-is-accepting-jobs`, `document-format-supported`, `sides-supported`, `print-color-mode-supported`, `copies-supported`, `multiple-document-handling-supported`, `media-col-supported`, `media-col-ready` and `media-col-database` (sizes in hundredths of a millimetre, with margins, type and source), `media-ready`, `media-type-supported`, `media-source-supported`, `print-quality-supported`, `print-scaling-supported`, `output-bin-default` and `printer-output-tray`, `pwg-raster-document-resolution-supported`, `-type-supported` and `-sheet-back`, `urf-supported`, the supplies (`marker-names`, `-colors`, `-levels`, `-types`, `-low-levels`, `-high-levels`), `printer-more-info` and `printer-supply-info-uri`. A `PrintableArea` for a paper comes from the matching database entry, never from rounding points. Fixtures in `Tests/Fixtures/Ipp/printers/` are Get-Printer-Attributes responses: written by `scripts/make_ipp_fixtures.py` (standard library only) from the attribute lists beside them, modelled on what printers of four makers report; a response captured byte for byte from a real printer goes beside them as soon as one is at hand (`captured-*.bin`), since synthesized fixtures share the codec's assumptions.

`IppProblems.describe(reasons:, message:, reachable:) -> [PrinterProblem]`: the state reasons a user can act on, worst first. A reason ending `-error` stops jobs, `-warning` and `-report` do not; a reason without a suffix is an error (RFC 8011 §5.4.12), except those ending in `-low` or `-needed`, which are warnings; `none` is nothing. `PrinterProblem` has Lazy Scan's `ScannerProblem` shape: `title` ("Out of paper", "Paper jam", "Cover open", "Ink empty", "Ink low", "Printer paused", "Output tray full", and "Printer offline" for a printer that does not answer, which is not an IPP reason), `advice` ("Load paper in the tray, then press Resume."), `isError`.

### Ipp/DocumentFormats

```swift
public enum DocumentKind: Sendable { case pdf(encrypted: Bool), photo, imposed }
public enum DocumentFormats {
    /// The format a job goes in. A PDF goes as itself only when it is printed as it is: one page per side,
    /// every page once in order, fit or shrink to fit, no booklet, no manual duplex, not encrypted. One photo goes
    /// as JPEG only when it is printed whole on paper of its own size. Everything else is sheets drawn by
    /// Lazy Print: `application/pdf` where the platform can write one (`canWritePDF`: the Mac and the iPhone,
    /// CoreGraphics), else `image/pwg-raster`, then `image/urf`. Nil when the printer takes none of them.
    public static func choose(supported: [String], kind: DocumentKind, canWritePDF: Bool) -> String?
}
```

A job the printer refuses with `client-error-document-format-not-supported` (0x040A), `-document-format-error` (0x0411) or `-document-unprintable-error` (0x041B) is sent once more as raster. `IppStatus` names the status codes of RFC 8011 §B and PWG 5100.13 with their numbers. Nil gives `PrintError.needsDriver` ("This printer needs its driver").

### Ipp/PwgRaster, Ipp/UrfRaster

`PwgRaster` writes PWG 5102.4 raster, big-endian: the `RaS2` sync word, then per page a 1796-byte header (the CUPS v2 header with PWG's fields: `MediaClass` "PwgRaster", `HWResolution`, `PageSize` in points, `cupsWidth`, `cupsHeight`, `cupsBitsPerColor` 8, `cupsBitsPerPixel` 8 or 24, `cupsBytesPerLine`, `cupsColorOrder` 0, `cupsColorSpace` 18 sGray or 19 sRGB, `cupsNumColors`, `Duplex`, `Tumble` false, `cupsInteger[0]` TotalPageCount, `[1]` CrossFeedTransform, `[2]` FeedTransform, `[8]` PrintQuality, `cupsPageSizeName` the PWG media name) and the page's lines. Each line is a line-repeat byte (n means n+1 identical lines) and runs of whole pixels: a byte 0–127 repeats the next pixel n+1 times, 129–255 is followed by 257−n literal pixels. The resolution is one of `pwg-raster-document-resolution-supported` (300 dpi when listed, else the lowest).

`UrfRaster` writes Apple raster for printers that list `urf-supported` and not `image/pwg-raster` (AirPrint-only): `UNIRAST\0`, the page count, then per page its 32-byte header (bits per pixel, color space, duplex, quality, width, height, resolution) and lines with the same line-repeat and run codes as PWG, chosen from the `urf-supported` tokens (`RS300`, `W8`, `SRGB24`, `DM1`–`DM4`). Both are pinned by golden files, and the tests decode what is written with a separate reader.

Backs (the even pages of a two-sided raster job) are reordered for the printer's sheet-back keyword before they are written, on top of the planner's 180° turns, and the header carries the same transforms: `normal` and `manual-tumble` as they are (1, 1); `rotated` turned 180° (−1, −1); `flipped` lines reversed bottom to top (1, −1). Cross-feed −1 means each line is written right to left, feed −1 that the lines are written bottom to top. URF's `DM1`–`DM4` map to normal, flipped, rotated and manual-tumble. A manual-duplex pass is one-sided: `Duplex` false, no transform.

`PwgRaster.writePage(header:, rows:)` and `UrfRaster.writePage` take the sheet a row at a time, so a job never holds more than one sheet in memory.

### Ipp/ addresses, discovery seam, trust

From Lazy Scan's `Escl/` with the protocol changed: `IppService` (the seam a platform's DNS-SD browser hands over: name, host, port, service type `_ipp._tcp` or `_ipps._tcp`, addresses, TXT), `IppTxtRecord` (`rp` default `ipp/print`, `ty`, `product`, `pdl`, `Color`, `Duplex`, `UUID`, `adminurl`, `note`, `URF`, `TLS`, `kind`, `PaperMax`), `IppEndpoint.choose` (one printer per UUID, `ipps` first, then IPv4, the `.local` name, IPv6), `PrinterAddress` (Lazy Scan's `ScannerAddress` for `ipp://`, `ipps://`, `http(s)://`, `host`, `host:port`; port 631 and path `/ipp/print` by default), `IppHostList` (`ipp-hosts.json`), `IppTrust` (`ipp-trust.json`), `IppRetry`.

### Ipp/IppClient

`IppClient(address:, printerName:, userName:, validator:, options:)` (C# also takes the `HttpMessageHandler` that `IppCertificateValidator.CreateHandler` makes, so tests can put a stub in) with `capabilities()`, `print(_ document: URL, ticket:)`, `job(_ id:)`, `cancel(_ id:)`, and `address` and `notEncrypted` for where requests go now. `PrinterCapabilities` also brings `CopiesRange` and `RasterResolution`; `IppTrust` brings `IppCertificateValidator` (C# `IppCertificateValidator`, `IppTrustCheck`), as in Lazy Scan's `EsclTrust`.

- A job's document is first spooled to a temporary file a sheet at a time; the Print-Job request (the encoded operation, then the file) is sent with `Content-Length` and `Content-Type: application/ipp`, never chunked and never with `Expect: 100-continue`, which many printers' web servers mishandle. A retry sends the file again; the file is deleted when the job is done or abandoned. Print-Job's timeout counts from the last byte sent (120 s).
- A busy printer (HTTP 503, or IPP `server-error-busy` 0x0507) is retried with `IppRetry`; `server-error-not-accepting-jobs` (0x0506) is reported as the printer's problem.
- HTTP 426 (upgrade required) moves the printer to `ipps`. An `ipps` handshake that fails before any certificate is seen falls back to `ipp`, marked "Not encrypted", never after a certificate was refused (Lazy Scan's rule).
- Get-Job-Attributes answering `client-error-not-found` after a job was accepted means the printer finished and forgot it: the job counts as completed.
- A certificate accepted for first use is pinned (`rememberDevice`, by the printer's UUID) before any document goes out: `print` reads the capabilities first while the pin is new. A printer already trusted is never reached over plain `ipp`: its failed handshake is "no secure connection".
- Errors: `PrintError.unreachable(name, reason)`, `.refused(status, message)`, `.needsDriver`, `.busy`, `.needsSignIn` (HTTP 401, or a job held with `job-password-wait`, which is cancelled: "This printer asks for a sign-in, which Lazy Print can't do yet"), `.badRaster(line, length, expected)`, `.badResponse`. A refused or changed certificate is `IppCertificateError` (C# `IppCertificateException`), which the app turns into its trust prompt, as Lazy Scan does.
- Tests run against a loopback IPP printer (`LoopbackIppPrinter` in each test suite) that records what it gets and answers from the fixtures.

## Printing through the system

The printers the system has set up are printed to without the system's dialog, with the job's settings forced so a driver's defaults cannot impose the sheets a second time: Windows' spooler ticket always sets `PageMediaSize`, `PageOrientation` Portrait, `PageScaling` None, one page per sheet, no booklet, `JobPageOrder` Standard, and `Duplexing` TwoSidedLongEdge or OneSided (manual passes); the Mac sets portrait, 100 %, no fit to page, `number-up` 1, `outputorder` normal and long-edge duplex or none. Copies are the printer's when it can collate them (`PrintCopies`), else repeated in the job.

## Core/ (tasks, settings, printers, jobs, the troubleshooter)

### Core/PrintTask, TaskCatalog

```swift
public enum PrintTask: String, CaseIterable, Identifiable, Sendable {
    case document, twoSided, booklet, handouts, photos, photoSheet, testPage, scanAndPrint, fromPhone
}
public enum TaskGroup: String, CaseIterable, Sendable { case documents, photos, other }   // "Documents", "Photos", "Other"
public struct TaskDefinition: Equatable, Sendable {
    public let task: PrintTask
    public let title: String          // "Print a document", "Two-sided", "Booklet", "Handouts", "Photo prints", "Photo sheet",
                                      // "Test page", "Scan and print", "From your phone"
    public let subtitle: String       // its help, one sentence ending in a full stop
    public let iconKey: String        // platform-neutral; the Mac maps it to SF Symbols, Windows to Segoe Fluent glyphs
    public let group: TaskGroup
    public let opensFiles: Bool       // starts by asking for files (document, twoSided, booklet, handouts, photos, photoSheet)
}
public struct TaskAvailability: Equatable, Sendable { public let isAvailable: Bool; public let reason: String? }   // Lazy Scan's shape; "Needs a printer", "Needs Lazy Scan"
public struct TaskContext: Equatable, Sendable { public var hasPrinter: Bool; public var lazyScanInstalled: Bool; public var platform: AppPlatform }
public enum AppPlatform: String, Sendable { case windows, mac, ios }
public enum TaskCatalog {
    public static let all: [TaskDefinition]
    public static func definition(_ task: PrintTask) -> TaskDefinition
    public static func tasks(for platform: AppPlatform) -> [TaskDefinition]     // fromPhone is not on the iPhone
    public static func availability(of task: PrintTask, context: TaskContext) -> TaskAvailability
    /// The settings a task sets; what it leaves alone stays as the user had it.
    public static func apply(_ task: PrintTask, to settings: PrintSettings, printer: PrinterCapabilities?) -> PrintSettings
}
```

What each task sets: `document` one per side, shrink to fit, two-sided when the printer can; `twoSided` long edge (by hand when the printer can't); `booklet`; `handouts` 2 per side, page borders; `photos` the photo size 4×6, fill, best quality, color; `photoSheet` 4 per side, fill, cut marks; `testPage` prints `TestPage` at once on the chosen printer; `scanAndPrint` hands off to Lazy Scan (see "Hand-off"); `fromPhone` opens the phone window.

### Core/PrintSettings (settings.json), PrinterPrefs (printers.json)

```swift
public enum ColorChoice: String, Codable, CaseIterable, Sendable { case color, gray }
public enum QualityChoice: String, Codable, CaseIterable, Sendable { case normal, draft, best }   // print-quality 4, 3, 5
public struct PrintSettings: Codable, Equatable, Sendable {
    public var taskId: String? = nil            // the PrintTask raw value, kept as a string so a newer task survives
    public var printerId: String? = nil         // PrinterInfo.id; nil = the system's default printer
    public var copies: Int = 1                  // 1...99 (PrintCopies.clamp)
    public var collate: Bool = true
    public var color: ColorChoice = .color
    public var quality: QualityChoice = .normal
    public var sides: Sides = .oneSided
    public var pagesPerSheet: Int = 1
    public var booklet: Bool = false
    public var rightToLeft: Bool = false
    public var pageBorders: Bool = false
    public var scaling: Scaling = .shrinkToFit
    public var paperId: String = "auto"         // PaperSize raw value; auto = what the printer has loaded, else the regional default
    public var photoSizeId: String = "4x6"
    public var photoFill: Bool = true
    public var cutMarks: Bool = true
}
public struct PrinterPrefs: Codable, Equatable, Sendable {
    public var paperPath: PaperPath = PaperPath()
    public var lastPaperId: String? = nil
}
```

Both files follow Global rule 5. `printers.json` maps `PrinterInfo.id` to `PrinterPrefs`; ids are stable across runs: a system queue is always `system:` and its name, whether or not its IPP twin answered this time; a printer only on the network is `ipp:` and its UUID (`ipp:name:` and its instance name without one); the demo printer is `demo`.

### Core/Printers (the printer list)

```swift
public enum PrinterRoute: String, Sendable { case system, ipp, demo }
public enum PrinterState: String, Sendable { case unknown, idle, printing, stopped, offline }
public struct Supply: Equatable, Sendable { public var name: String; public var color: String?; public var level: Int?; public var isLow: Bool }   // level 0...100, nil unknown
public struct PrinterInfo: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var model: String?
    public var address: String?            // what the troubleshooter and the test page show
    public var route: PrinterRoute         // how jobs go: the system's queue when it has one, else IPP
    public var ippEndpoint: IppEndpoint?   // also set for a system printer matched to its IPP twin, for status and supplies
    public var isDefault: Bool
    public var state: PrinterState
    public var problems: [PrinterProblem]
    public var supplies: [Supply]
    public var queue: QueueStatus?         // a system row's own state and problems, which IPP's answers add to and never replace
}
public enum PrinterMerge {
    /// One row per physical printer, whichever ways it is listed: a system queue and the IPP printer it points at are
    /// one row, routed through the system queue, with the IPP endpoint kept for status. Matching runs in phases over all
    /// queues: UUID, then a host or address in the queue's port or device URI, then the exact DNS-SD instance name
    /// (`IppEndpoint.instanceNames`), then the name without "(Copy 2)"; a queue whose port names a host is never matched
    /// by name, and a name that fits more than one printer matches none. Virtual queues (PDF, OneNote, fax, XPS) are left out.
    /// The demo printer is last.
    public static func merge(system: [SystemPrinter], network: [IppService], demo: Bool) -> [PrinterInfo]
}
```

`SystemPrinter` is what a platform says of a queue it has set up: name, model (driver name), port or device URI, whether it is the default, whether it is virtual, its states (`SystemQueueState`: paused, error, offline, paperOut, paperJam, doorOpen, tonerLow, noToner, busy, userIntervention, from Windows' `PrintQueueStatus` and the Mac's printer state) and its jobs (count, any in error, oldest age). `SystemQueueProblems.describe` turns those states into `PrinterProblem`s with the same titles IPP's reasons get.

### Core/PrintJobs (from settings to sheets to a job)

```swift
public struct LoadedDocument: Equatable, Sendable { public var name: String; public var kind: DocumentKind; public var pages: [LayoutSize] }
public struct JobPlan: Equatable, Sendable {
    public var plan: SheetPlan
    public var manualDuplex: Bool           // two-sided asked for and the printer can't: two passes
    public var passes: [DuplexPass]         // one pass, or fronts then backs
    public var copiesInJob: Int             // copies the printer makes; the rest are repeated in the stream (PrintCopies)
    public var notes: [String]              // "2 blank pages added", "Pages made smaller (82 %)"
}
public enum PrintJobs {
    public static func layoutOptions(_ settings: PrintSettings, task: PrintTask?) -> LayoutOptions
    public static func area(paper: PaperSize, printer: PrinterCapabilities?, borderless: Bool) -> PrintableArea
    public static func plan(_ documents: [LoadedDocument], pageRange: [Int]?, settings: PrintSettings, task: PrintTask?,
                            printer: PrinterCapabilities?, prefs: PrinterPrefs) -> JobPlan
    /// A document `asIs` is the printer's to scale ("auto" or "fit") and may go short edge; imposed sheets are "none" and long edge.
    /// With no database entry for the paper, media-col carries its size and the margins laid out, when the printer takes margins.
    public static func ticket(_ job: JobPlan, settings: PrintSettings, format: String, printer: PrinterCapabilities?, name: String, asIs: Bool = false) -> IppJobTicket
}
public enum JobState: String, Sendable { case preparing, sending, waiting, printing, done, failed, canceled, needsUser }
public struct JobRecord: Equatable, Identifiable, Sendable {   // the Jobs tab: this session's jobs
    public var id: String; public var name: String; public var printerName: String; public var sheets: Int; public var copies: Int
    public var state: JobState; public var detail: String?; public var started: Date
}
```

A printer's capabilities (from IPP, or filled in by the system for a queue with no IPP twin) say whether it prints both sides and color, which papers it has and their margins; `PrintJobs.area` uses the matching `media-col-database` entry, else the system's imageable area, else 0.25 in on every side.

### Core/Troubleshooter ("Why isn't my printer listed?")

Lazy Scan's troubleshooter, the same model (`TroubleshootCheck` with id, status, a title of six words at most, a one-line detail of fifteen at most, `more` behind More help, actions of one to three words; `diagnose`, `headline`, `summary`, `overview`, `label`, `statusLabel`, `report`, the stable sort: problems, warnings, OK, tips). Its snapshot:

```swift
public struct PrinterSnapshot: Equatable, Sendable {
    public var platform: AppPlatform
    public var printers: [PrinterInfo]
    public var network: NetworkStatus = .unknown          // Lazy Scan's enum
    public var spooler: ServiceStatus = .unknown          // Windows: the Print Spooler service
    public var discovery: DiscoveryStatus = .unknown      // off, searching, running, unavailable, denied (Local Network)
    public var discoveryDetail: String? = nil
    public var manualHosts: [ManualHostStatus] = []
    public var stuckJobs: [StuckJobs] = []                 // printer id and name, count, oldest in minutes, any in error
    public var lastFailure: PrinterFailure? = nil          // the last job or connection that failed, with its problem
}
public enum TroubleshootAction: String, CaseIterable, Sendable {
    case refresh, addByAddress, openPrinterSettings, openNetworkSettings, copyDiagnostics, openAppSettings, clearStuckJobs, resumePrinter, printTestPage
}
```

Checks (ids are stable): `lastFailure`; `network` (offline; Public: "Windows won't find network printers on a Public network."); `spooler` (Windows: not running, disabled, missing); `discovery` and `localNetwork` (the iPhone's Local Network access off, with Open Settings); `printer:<id>` for each printer with a problem ("Out of paper: HP LaserJet", its advice); `stuckJobs:<id>` ("3 jobs stuck on HP LaserJet", Clear stuck jobs); `paused:<id>` (Resume); `manualHost:<address>`; tips `usb` ("Connected by USB?": the maker's driver, or the one Windows offers), `asleep` ("Printer asleep? Press any button on it, then Refresh."), `wifiDirect` (a printer's own Wi-Fi is another network), `otherApps`. The headline is "No printer found", "1 printer found", "3 printers found" (the demo printer not counted). `clearStuckJobs` and `resumePrinter` change something, so they ask first and say what they did; every other action only reads.

### Core/StatusLine, InspectorSections, PrintText

`StatusLine` is Lazy Scan's (six words at most, the full sentence for screen readers). `InspectorSections`: `printer` (open), `pages` (copies, range, two-sided; open), `layout` (pages per side, booklet, scaling, borders), `paper` (paper, quality, color), `photos` (size, fill, cut marks; opened by the photo tasks); a collapsed header summarizes what is on ("2 per side · Borders"). `PrintText` holds the sentences both apps show: "Sent 3 sheets to HP LaserJet", "Printing 2 of 5", "Printed", "Load the backs", errors titled by their problem.

## Render/ (Swift), the Windows renderer

A `SheetSide` is drawn the same way everywhere: each placement's page, cropped, turned by its quarter turns and scaled into its frame; page borders as 0.5 pt gray lines; a blank back's mark dot; `TestPageItem`s for the test page, the two-sided check and cut marks. The Mac and the iPhone draw with CoreGraphics (`Render/SheetRenderer.swift`: `CGPDFPage` and `CGImage` sources, into a `CGPDFContext` for a PDF of the sheets, or a bitmap context a band of rows at a time for raster). Windows draws with WPF (`LazyPrint.App/Printing/SheetRenderer.cs`: each placement's page asked of an `IPageRenderer`, PDF pages by `Windows.Data.Pdf` and pictures by WIC, at most 1200 dpi; a canvas per side for the spooler at 300 dpi, built only when the XPS writer asks for that page, or the whole side as a bitmap for raster, read out 64 rows at a time). The blank-back dot sits 8 pt inside the printable area's top-left corner, and all drawing is clipped to the printable area.

## The demo printer

As Lazy Scan's Demo Scanner, a printer that is always there (last in the list, never counted as found), so every task can be tried without one: it takes any format, prints both sides or not (a switch on it), has Letter, A4 and 4×6 photo paper with 0.17 in margins, and "prints" by writing each sheet side as a PNG to `Documents/Lazy Print/Demo prints/<job>/`, which the Jobs tab opens. Its ink goes down a little with each job, and "Out of paper" can be set from its menu, to try the troubleshooter and the two-sided card.

## The Windows app (windows/LazyPrint.App)

Lazy Scan's shell, with its look: `Styles/Tokens.xaml` and `Controls.xaml`, `ThemeService` (light, dark and the system's accent), `Icon` (Segoe Fluent glyphs), `InfoButton`, `ShortText` and `CardGridInsets`, copied (`FileActionMenu` comes with the phone link) from `windows/LazyScan.App` with the names changed. Code-behind and an `AppViewModel` split into partial files by feature, as there; the view model takes its system services as interfaces (`IPrinterSystem`, `INetworkPrinters`, `IDocumentLoader`, `ISheetPrinter`, `ISystemDiagnostics`) so `LazyPrint.App.Tests` can pass stand-ins. The exe is `LazyPrint.exe` (`AssemblyName` LazyPrint, `Product` "Lazy Print"), one instance per user session (`Local\LazyPrint.App`); a second start hands its command line (files to print) to the first over the named pipe `LazyPrint.Open.<session id>` (one message per connection: a UTF-8 JSON array of full paths; an empty one only brings the window forward) and quits. When the first can't be reached it runs on its own with the files.

`MainWindow`: the bars (error with Troubleshoot, "Sent" with Jobs, "From your phone") above a sidebar and three tabs.
- Sidebar (216 DIP): "Printers", each row the printer's name (the demo printer's with "Demo (no hardware)" under it), a state dot, a one-line problem when it has one ("Out of paper") and its ink or toner as thin bars under the name; the demo printer last, and "No other printer found" under it when it is alone; its row's menu has the demo switches; rows are updated in place so focus stays; Add by address (+) and the troubleshooter (?) next to the heading; the Phone button at the bottom.
- Start: `TaskStartView`, the tiles of `TaskCatalog` in their groups, greyed with their reason when unavailable. A tile that opens files asks for them (or takes what was dropped). Test page, Scan and print and From your phone act at once and are never kept as the task; the test page needs a printer, and the demo printer counts once the list has been read.
- Print: the sheet preview in the middle (the current sheet's front, or its back, drawn by `SheetRenderer` at screen resolution, with "Sheet 2 of 5", previous and next, Front/Back), the documents in a strip under it (thumbnail, name, page count; reorder, remove, Add files…; files dropped anywhere on the window are added); the inspector on the right (280 DIP, `InspectorSections`, Lazy Scan's collapsible sections with summaries), and at its foot the Print button, which says what it does ("Print 5 sheets", "Print the fronts").
- Jobs: this session's `JobRecord`s, newest first, with their state, Cancel while they run, Print again, and Show for the demo printer's folder.
- The two-sided card (an in-window overlay, Lazy Scan's dialog card): the step, the reload picture and sentence from `ManualDuplexText` (counting every printed front, copies included), Print the backs, Check with one sheet, Cancel. Escape only moves to Cancel: the fronts are already printed. The check sheet's back is drawn half-turned when the current `PaperPath` turns backs, so the check tests that guess.
- Windows: `TroubleshooterWindow`, `AddPrinterWindow` (an address, checked with Get-Printer-Attributes before it is added to `ipp-hosts.json`), `CertificateTrustWindow` (a new certificate is trusted on first use, as in Lazy Scan; a changed one is asked about only when the user picks the printer, prints to it or adds it, never from a background read, and a print is sent again once trusted), `PhoneWindow` (see "The phone link").

Services (`LazyPrint.App/Services`, `Printing`):
- `WindowsPrinters` (`IPrinterSystem`), with `WindowsSystemStatus` (spooler service and network category, kept in the app because it needs the Windows target): the spooler's queues through `System.Printing` (`LocalPrintServer`, `PrintQueue`: name, driver, port, default, `QueueStatus`, jobs), as `SystemPrinter`s, and their `PrintCapabilities` turned into `PrinterCapabilities` (papers with their imageable area, duplex, color, copies, collation); polled every 5 s while the window is open; clearing stuck jobs and resuming a paused queue.
- `IppDiscovery` and `NetworkPrinters` (`INetworkPrinters`): printers on the network by DNS-SD (`_ipp._tcp`, `_ipps._tcp`) with a WinRT `DeviceWatcher`, as Lazy Scan's `EsclDiscovery`, handing over `IppService`s; the addresses in `ipp-hosts.json` checked at start and every minute while they don't answer, each one that answers made an `IppService` with id `address:<address>` and its UUID, so the merge joins it to its discovered twin. Status, problems and supplies of network rows are read every 30 s.
- `DocumentLoader` (`IDocumentLoader`, `IPageRenderer`, `IOriginalFiles` for sending a PDF or upright JPEG as it is): PDFs with `Windows.Data.Pdf` (page sizes with their rotation applied; a page rendered at a given size), images with WIC (JPEG, PNG, TIFF, BMP, GIF, HEIC when the extension is installed; turned upright by their orientation tag). A password-protected PDF is refused with "This PDF is locked. Open it in a PDF app and print it from there." A PDF with only an owner password opens, but always goes as drawn sheets. A file of another kind gets "Lazy Print prints PDFs and pictures. Save it as a PDF first." A multi-frame TIFF or GIF is its first frame. A picture is sized by its own dpi when that is 72 or more, else as 300 dpi.
- `SheetRenderer`: see "Render/".
- `SpoolerPrinter` (`ISheetPrinter`): the sheet sides through a `DocumentPaginator` that builds each page when asked, written with `XpsDocumentWriter` to the queue under the forced ticket of "Printing through the system", merged over the queue's `DefaultPrintTicket` and patched in Print Schema XML so a driver's own booklet, N-up or scaling can't come back (`JobBindAllDocuments`, `DocumentBinding` and `PageScaling` None, `DocumentNUp` 1); the paper is the driver's own named size when one is within `FitTolerance`. `PrintTicket` has no booklet setting of its own. The same document can be written to an XPS file, which is what the tests check.
- `IppSheetPrinter` (`ISheetPrinter`): a document as it is, or the sheets as PWG or URF raster at the resolution Core picks (gray when the printer lists only gray raster types), spooled by `IppSpool`, sent with `IppClient`; the job then followed with Get-Job-Attributes every 2 s until it ends, canceled with Cancel-Job.
- `RoutingSheetPrinter`: sends a job to one of the three by `PrinterInfo.route`. `ISheetPrinter` is one call, `PrintAsync(job, pass, progress, token)`; the view model drives the passes of a two-sided job itself, and the test page and the check sheet are jobs carrying `TestPageItem`s, as cut marks are for photo sheets. A stop from the printer's condition ("Out of paper") reaches the error bar with its problem's title and Troubleshoot.
- `DemoPrinter` (`ISheetPrinter`): see "The demo printer".
- `SystemDiagnostics` (`ISystemDiagnostics`): the Print Spooler service's state and the network's category, as Lazy Scan's.
- Settings and printer preferences in `%APPDATA%\Lazy Print`, logs in `%LOCALAPPDATA%\Lazy Print\Logs\printers.txt` (the printer list, how rows were merged, the troubleshooter's report).

`LazyPrint.App.Tests` checks the app's own code without a window or a printer: the renderer's pixels for a plan (the documents it draws are made by `scripts/make_document_fixtures.py` into `Tests/Fixtures/Documents/`), the XPS a job writes (its pages, sizes and ticket), the IPP printer against the loopback printer, the demo printer's files, the view model's flows with stand-in services (a task sets its settings, a printer without duplex gets the two-sided card, a failed job puts its problem in the error bar). It links `LoopbackIppPrinter`, `IppFixtures` and `RasterReader` from the Core tests. The Jobs tab keeps Print again for the last 10 jobs.

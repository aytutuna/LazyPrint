# Lazy Print — module contracts

Native printing app for Windows, macOS, the iPhone and the iPad, the sister of Lazy Scan (whose layout, conventions and much of whose code it shares). SwiftUI, macOS 14+ and iOS 18+, `swift-tools-version: 6.0` with the Swift 5 language mode (`swiftLanguageModes: [.v5]`), SwiftPM, **system frameworks only** (AppKit, SwiftUI, Combine, PDFKit, CoreGraphics, CoreText, ImageIO, UniformTypeIdentifiers, CryptoKit, Security, Network and the DNS-SD library; libcups on the Mac; UIKit on iOS). The Windows app is .NET 10 and WPF, with a Core library whose one dependency is Microsoft's `System.Security.Cryptography.ProtectedData`, which keeps the phone link's sync keys under DPAPI as in Lazy Scan. No third-party code anywhere except ZXing.Net for the pairing QR code on Windows, as in Lazy Scan. UIKit only in `LazyPrintIOS`; AppKit, SwiftUI and UIKit never in `LazyPrintKit`, and `LazyPrintKit` keeps CoreGraphics and CoreText to the files that draw and the app state (`Render/`, `App/`, `Printing/`) Network to `Printing/` and `Companion/`, dnssd to `Printing/` and Security and CryptoKit to `Companion/`, so its protocol and layout code needs Foundation alone. Combine is for `ObservableObject` only.

The package's targets:
- `LazyPrintKit` (`Sources/LazyPrintKit/`): everything the Mac and the iPhone share: `Core` (tasks, settings, printers, problems, the troubleshooter), `Layout` (paper, page placement, N-up, booklets, photo sizes, two-sided by hand, the test page), `Ipp` (driverless printers: the IPP codec, attributes, jobs, PWG raster, addresses, trust, the client), `Companion` (the phone link, from Lazy Scan's), `Persistence`, `Render` (drawing a sheet with CoreGraphics), `Printing` (the printers that draw and the discovery that browses: `IppSheetPrinter`, `NWBrowserPrinters`, the demo printer, `RoutingSheetPrinter`, `JobSides`), `App` (`AppState` and the protocols of the system services an app shell passes in).
- `LazyPrintMac` (`Sources/LazyPrintMac/`): the Mac's views and its system services (printing to the printers macOS has set up, the troubleshooter's system checks, file actions). Every file is wrapped whole in `#if os(macOS)`.
- `LazyPrintIOS` (`Sources/LazyPrintIOS/`): the iPhone and iPad views and services. Every file is wrapped whole in `#if os(iOS)`.
- `LazyPrint` (`Sources/LazyPrint/main.swift`): the Mac app.
- `ios/`: the iPhone and iPad app's Xcode project, written by XcodeGen from `ios/project.yml` (not checked in); its app target `LazyPrintiOS` only starts `LazyPrintIOSApp`.
- Tests: `Tests/LazyPrintTests` (shared, `@testable import LazyPrintKit`), `Tests/LazyPrintMacTests`, `Tests/LazyPrintIOSTests`; fixtures both suites read in `Tests/Fixtures/`.

The Windows solution (`windows/LazyPrint.sln`):
- `LazyPrint.Core` (`net10.0`, `ProtectedData` the only package): the twins of `LazyPrintKit`'s Core, Layout, Ipp, Companion and Persistence, plus the protocol logic only Windows has (the print spooler's states and the Windows service checks).
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
4. Errors thrown across modules are `PrintError` (C# `PrintException` carrying a `PrintError`), which has `unreadable(sentence)` and `noPrinter` beside the IPP cases. The sentences for files that can't be printed are Core's `DocumentText` (`lockedPdf`, `notSupported`, `unreadable`, `noPages`), used by both document loaders.
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
    public var scale: Int = 100                    // percent, 10...400, for a page alone on its side under shrinkToFit or actualSize
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
    /// The cut marks of a photo sheet's side, which `Imposition` planned as a grid: at the corners of its photos' frames, none for one photo.
    public static func frameMarks(_ side: SheetSide) -> [TestPageItem]
}
```

### Layout/PageRange

`PageRange.parse("1-3, 5, 8-", pageCount:) -> Result<[Int], PageRangeError>` (C#: `PageRangeResult` with `Pages` and `Error`) (0-based indices, in the order typed, repeats kept; separators are commas, semicolons or spaces, a range takes a hyphen, en dash or em dash, "3-" runs to the last page and "5-2" gives 5, 4, 3, 2); errors name the problem ("Page 9 is past the end (8 pages)", "Type pages like 1-3, 5").

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
- Errors: `PrintError.unreachable(name, reason)`, `.lostContact(name)`, `.refused(status, message)`, `.needsDriver`, `.busy`, `.needsSignIn` (HTTP 401, or a job held with `job-password-wait`, which is cancelled: "This printer asks for a sign-in, which Lazy Print can't do yet"), `.badRaster(line, length, expected)`, `.badResponse`. A refused or changed certificate is `IppCertificateError` (C# `IppCertificateException`), which the app turns into its trust prompt, as Lazy Scan does.
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

What each task sets: `document` one per side, shrink to fit, two-sided when the printer can; `twoSided` long edge (by hand when the printer can't); `booklet`; `handouts` 2 per side, page borders; the first four also put quality back to normal, as `photos` sets it to best, and leave colour alone; `photos` the photo size 4×6, fill, best quality, color; `photoSheet` 4 per side, fill, cut marks (at the corners of the photos' frames, `PhotoLayout.frameMarks`); `testPage` prints `TestPage` at once on the chosen printer; `scanAndPrint` hands off to Lazy Scan (see "Hand-off"); `fromPhone` opens the phone window. A first launch, with no settings saved, starts in the `document` task, so a new user gets two-sided printing without opening the Task menu; leaving the task is saved like any other change, and the next launch starts in none. A `document` picked before the printer's capabilities are read (the printers not listed yet) can only choose one side. It remembers that choice and chooses again each time the printer in use is read or changes (a demo printer that was chosen stays the printer in use after real ones are listed), until the user changes the sides; a change the user made stands. Both view models do this (`sidesPickedBlind` and `chooseSidesAgain` in Swift, `_sidesPickedBlind` and `ChooseSidesAgain` in C#).

### Core/PrintSettings (settings.json), PrinterPrefs (printers.json)

```swift
public enum ColorChoice: String, Codable, CaseIterable, Sendable { case color, gray }
public enum QualityChoice: String, Codable, CaseIterable, Sendable { case normal, draft, best }   // print-quality 4, 3, 5
public struct PrintSettings: Codable, Equatable, Sendable {
    public var taskId: String? = nil            // the PrintTask raw value, kept as a string so a newer task survives
    public var printerId: String? = nil         // PrinterInfo.id; nil = the system's default printer
    public var copies: Int = 1                  // 1...99 (PrintCopies.clamp); not saved, each launch starts at 1
    public var collate: Bool = true
    public var color: ColorChoice = .color
    public var quality: QualityChoice = .normal
    public var sides: Sides = .oneSided
    public var pagesPerSheet: Int = 1
    public var booklet: Bool = false
    public var rightToLeft: Bool = false
    public var pageBorders: Bool = false
    public var scaling: Scaling = .shrinkToFit
    public var scale: Int = 100
    public var paperId: String = "auto"         // PaperSize raw value; auto = what the printer has loaded, else the regional default
    public var photoSizeId: String = "4x6"
    public var photoFill: Bool = true
    public var cutMarks: Bool = true
}
public struct PrinterPrefs: Codable, Equatable, Sendable {
    public var paperPath: PaperPath = PaperPath()
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
    public var notes: [String]              // "2 blank pages added", "Edges cut off (3 mm)", "Printed in gray: this printer has no color" (color asked for, printer lists monochrome only); a page made smaller to fit goes unsaid
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

Checks (ids are stable): `lastFailure`; `network` (offline; Public: "Windows won't find network printers on a Public network."); `spooler` (Windows: not running, disabled, missing); `discovery` and `localNetwork` (the iPhone's Local Network access off, with Open Settings); `printer:<id>` for each printer with a problem ("Out of paper: HP LaserJet", its advice); `stuckJobs:<id>` ("3 jobs stuck on HP LaserJet", Clear stuck jobs); `paused:<id>` (Resume; on the iPhone, which cannot resume a printer, and for a printer with no queue of the system's (found on the network only), "Press Resume on the printer to let its jobs print." and no button); `manualHost:<address>`; tips `usb` ("Connected by USB?": the maker's driver, or the one Windows offers), `asleep` ("Printer asleep? Press any button on it, then Refresh."), `wifiDirect` (a printer's own Wi-Fi is another network), `otherApps`. The headline is "No printer found", "1 printer found", "3 printers found" (the demo printer not counted). `clearStuckJobs` and `resumePrinter` change something, so they ask first and say what they did; every other action only reads.

### Core/StatusLine, InspectorSections, PrintText

`StatusLine` is Lazy Scan's (six words at most, the full sentence for screen readers). `InspectorSections`: `printer` (open), `pages` (copies, range, two-sided; open), `layout` (pages per side, booklet, scaling, borders), `paper` (paper, quality, color), `photos` (size, fill, cut marks; opened by the photo tasks); a collapsed header summarizes what is on ("2 per side · Borders"). `PrintText` holds the sentences both apps show: "Sent 3 sheets to HP LaserJet", "Printing 2 of 5", "Printed", "Load the backs", errors titled by their problem.

## Render/ (both platforms)

A `SheetSide` is drawn the same way everywhere: each placement's page, cropped, turned by its quarter turns and scaled into its frame; page borders as 0.5 pt gray lines; a blank back's mark dot; `TestPageItem`s for the test page, the two-sided check and cut marks. The Mac and the iPhone draw with CoreGraphics (see "Render/ (drawing a sheet, Swift)"). Windows draws with WPF (`LazyPrint.App/Printing/SheetRenderer.cs`: each placement's page asked of an `IPageRenderer`, PDF pages by `Windows.Data.Pdf` and pictures by WIC, at most 1200 dpi; a canvas per side for the spooler at 300 dpi, built only when the XPS writer asks for that page, or the whole side as a bitmap for raster, read out 64 rows at a time). The blank-back dot sits 8 pt inside the printable area's top-left corner, and all drawing, the marks and items included, is clipped to the printable area.

## The demo printer

As Lazy Scan's Demo Scanner, a printer that is always there (last in the list, never counted as found), so every task can be tried without one: it takes any format, prints both sides or not (a switch on it), has Letter, A4 and 4×6 photo paper with 0.17 in margins, and "prints" by writing each sheet side as a PNG to `Documents/Lazy Print/Demo prints/<job>/`, which the Jobs tab opens. Its ink goes down a little with each job, and "Out of paper" can be set from its menu, to try the troubleshooter and the two-sided card.

## The Windows app (windows/LazyPrint.App)

Lazy Scan's shell, with its look: `Styles/Tokens.xaml` and `Controls.xaml`, `ThemeService` (light, dark and the system's accent), `Icon` (Segoe Fluent glyphs), `InfoButton` and `ShortText`, copied from `windows/LazyScan.App` with the names changed. Code-behind and an `AppViewModel` split into partial files by feature, as there; the view model takes its system services as interfaces (`IPrinterSystem`, `INetworkPrinters`, `IDocumentLoader`, `ISheetPrinter`, `ISystemDiagnostics`) so `LazyPrint.App.Tests` can pass stand-ins. The exe is `LazyPrint.exe` (`AssemblyName` LazyPrint, `Product` "Lazy Print"), one instance per user session (`Local\LazyPrint.App`); a second start hands its command line (files to print) to the first over the named pipe `LazyPrint.Open.<session id>` (one message per connection: a UTF-8 JSON array of full paths; an empty one only brings the window forward) and quits. When the first can't be reached it runs on its own with the files.

`MainWindow`: the bars (error with Troubleshoot, "Sent" with Jobs, "From your phone") above a sidebar and two tabs, Print first.
- Sidebar (216 DIP): "Printers", each row the printer's name (the demo printer's with "Demo (no hardware)" under it), a state dot, a one-line problem when it has one ("Out of paper") and its ink or toner as thin bars under the name; the demo printer last, and "No other printer found" under it when it is alone; its row's menu has the demo switches; rows are updated in place so focus stays; Add by address (+) and the troubleshooter (?) next to the heading; the Phone button at the bottom.
- Print: the task bar on top, a Task button whose menu lists `TaskCatalog` in its groups (the current one checked, an unavailable one disabled with its reason) and, once one is picked, its title and a button to leave it. A task that opens files asks for them when there are none. Test page, Scan and print and From your phone act at once and are never kept as the task; the test page needs a printer, and the demo printer counts only when the user has chosen it. Under it the sheet preview (the current sheet's front, or its back, drawn by `SheetRenderer` at screen resolution, with "Sheet 2 of 5", previous and next, Front/Back), the documents in a strip under it (thumbnail, name, page count; reorder, remove, Add files…; files dropped anywhere on the window are added; a drop or paste of nothing but folders names each one in the error bar with "Lazy Print prints PDFs and pictures. Save it as a PDF first.", as on the Mac); the inspector on the right (280 DIP, `InspectorSections`, Lazy Scan's collapsible sections with summaries), and at its foot the Print button, which says what it does ("Print 5 sheets", "Print 5 sheets × 3" with three copies, as the Jobs row says it, "Print the fronts"); the "Sent" bar says the same ("Sent 5 sheets × 3 to HP LaserJet").
- Jobs: this session's `JobRecord`s, newest first, with their state, Cancel while they run, Print again, and Show for the demo printer's folder.
- The two-sided card (an in-window overlay, Lazy Scan's dialog card): the step, the reload picture and sentence from `ManualDuplexText` (counting every printed front, copies included), Print the backs, Check with one sheet, Cancel. Escape only moves to Cancel: the fronts are already printed. The check sheet's back is drawn half-turned when the current `PaperPath` turns backs, so the check tests that guess.
- Windows: `TroubleshooterWindow`, `AddPrinterWindow` (an address, checked with Get-Printer-Attributes before it is added to `ipp-hosts.json`), `CertificateTrustWindow` (a new certificate is trusted on first use, as in Lazy Scan; a changed one is asked about only when the user picks the printer, prints to it or adds it, never from a background read, and a print is sent again once trusted), `PhoneWindow` (see "The phone link").

Services (`LazyPrint.App/Services`, `Printing`):
- `WindowsPrinters` (`IPrinterSystem`), with `WindowsSystemStatus` (spooler service and network category, kept in the app because it needs the Windows target): the spooler's queues through `System.Printing` (`LocalPrintServer`, `PrintQueue`: name, driver, port, default, `QueueStatus`, jobs), as `SystemPrinter`s, and their `PrintCapabilities` turned into `PrinterCapabilities` (papers with their imageable area, duplex, color, copies, collation); polled every 5 s while the window is open; clearing stuck jobs and resuming a paused queue.
- `IppDiscovery` and `NetworkPrinters` (`INetworkPrinters`): printers on the network by DNS-SD (`_ipp._tcp`, `_ipps._tcp`) with a WinRT `DeviceWatcher`, as Lazy Scan's `EsclDiscovery`, handing over `IppService`s; the addresses in `ipp-hosts.json` checked at start and every minute while they don't answer, each one that answers made an `IppService` with id `address:<address>` and its UUID, so the merge joins it to its discovered twin. Status, problems and supplies of network rows are read every 30 s.
- `DocumentLoader` (`IDocumentLoader`, `IPageRenderer`, `IOriginalFiles` for sending a PDF or upright JPEG as it is): PDFs with `Windows.Data.Pdf` (encrypted when the file has `/Encrypt`, because `IsPasswordProtected` misses an owner password; page sizes with their rotation applied; a page rendered at a given size), images with WIC (JPEG, PNG, TIFF, BMP, GIF, HEIC when the extension is installed; turned upright by their orientation tag). A password-protected PDF is refused with "This PDF is locked. Open it in a PDF app and print it from there." A PDF with only an owner password opens, but always goes as drawn sheets. A file whose extension names neither is a PDF when "%PDF-" is in its first 1024 bytes, else a picture when WIC opens it; otherwise it gets "Lazy Print prints PDFs and pictures. Save it as a PDF first." A multi-frame TIFF is a document of that many pages, one to a frame, each at its own size; a GIF is its first frame. A picture is sized by its own dpi when that is 72 or more, else as 300 dpi.
- `SheetRenderer`: see "Render/".
- `SpoolerPrinter` (`ISheetPrinter`): the sheet sides through a `DocumentPaginator` that builds each page when asked, written with `XpsDocumentWriter` to the queue under the forced ticket of "Printing through the system", merged over the queue's `DefaultPrintTicket` and patched in Print Schema XML so a driver's own booklet, N-up or scaling can't come back (`JobBindAllDocuments`, `DocumentBinding` and `PageScaling` None, `DocumentNUp` 1); the paper is the driver's own named size when one is within `FitTolerance`. `PrintTicket` has no booklet setting of its own. The same document can be written to an XPS file, which is what the tests check.
- `IppSheetPrinter` (`ISheetPrinter`): a document as it is, or the sheets as PWG or URF raster at the resolution Core picks (gray when the printer lists only gray raster types), spooled by `IppSpool`, sent with `IppClient`; the job then followed with Get-Job-Attributes every 2 s until it ends, canceled with Cancel-Job. Three missed answers in a row, the last one `.unreachable`, end it with `PrintError.lostContact(name)`, not `.unreachable`, since the printer has the job (any other error on the third miss is thrown as it is): the error bar is titled "Lost contact with <printer>" (`PrintText.lostContactTitle`), says "The job was sent before the printer stopped answering. Check the printer before printing it again.", and offers Troubleshoot.
- `RoutingSheetPrinter`: sends a job to one of the three by `PrinterInfo.route`. `ISheetPrinter` is one call, `PrintAsync(job, pass, progress, token)`; the view model drives the passes of a two-sided job itself, and the test page and the check sheet are jobs carrying `TestPageItem`s, as cut marks are for photo sheets. A stop from the printer's condition ("Out of paper") reaches the error bar with its problem's title and Troubleshoot.
- `DemoPrinter` (`ISheetPrinter`): see "The demo printer".
- `SystemDiagnostics` (`ISystemDiagnostics`): the Print Spooler service's state and the network's category, as Lazy Scan's.
- Settings and printer preferences in `%APPDATA%\Lazy Print`, logs in `%LOCALAPPDATA%\Lazy Print\Logs\printers.txt` (the printer list, how rows were merged, the troubleshooter's report).

`LazyPrint.App.Tests` checks the app's own code without a window or a printer: the renderer's pixels for a plan (the documents it draws are made by `scripts/make_document_fixtures.py` into `Tests/Fixtures/Documents/`), the XPS a job writes (its pages, sizes and ticket), the IPP printer against the loopback printer, the demo printer's files, the view model's flows with stand-in services (a task sets its settings, a printer without duplex gets the two-sided card, a failed job puts its problem in the error bar). It links `LoopbackIppPrinter`, `IppFixtures` and `RasterReader` from the Core tests. The Jobs tab keeps Print again for the last 10 jobs.

### The Store package

`store/windows/Package.appxmanifest` is the package manifest: `runFullTrust` and no other capability (a full-trust process is not in an app container, so the listener and the printer traffic need none), minimum Windows 10.0.19041.0, English only, `uap3:Protocol` for `lazyprint` (Lazy Scan and Lazy PDF hand files over through it), and `.pdf` and the picture types of `DocumentLoader.PictureExtensions` as file associations, which the app already opens through `App.FilesOf`. All three carry `Parameters="&quot;%1&quot;"`, so a path with spaces is one argument (`makeappx` accepts it; the activation itself was not run). A file association adds an Open with entry; Windows keeps the default. The identity is three names taken from Partner Center (`PartnerCenterIdentityName`, `CN=PartnerCenterPublisher`, `PartnerCenterPublisherDisplayName`) that `scripts/make_msix.ps1` replaces; the version is `Version` in `windows/Directory.Build.props` with `.0` added. `scripts/make_store_assets.py` draws the tiles and logos in `store/windows/Assets` and the listing images in `store/windows/Listing` from the same drawing as `AppIcon-1024.png` (`scripts/make_ios_icon.py`). The `store` job of `release.yml` publishes x64 and arm64 self-contained and packs them with the runner's `makeappx`.

Running packaged changes these things.
- `FileAssociation.RegisterForCurrentUser` does nothing (`Packaging.IsPackaged`, from `GetCurrentPackageFullName`): a key written from inside the package would only be the package's own copy, and the manifest registers the address.
- Writes under `%APPDATA%` and `%LOCALAPPDATA%` (settings, printer preferences, `ipp-hosts.json`, `ipp-trust.json`, the phone link's paired devices and inbox, and `Logs\printers.txt`) go to the package's store for the user. The app reaches them at the same paths and they go with an uninstall, but Explorer at `%LOCALAPPDATA%\Lazy Print` does not show them; `printers.txt` is under `%LOCALAPPDATA%\Packages\<package family name>\LocalCache\Local\Lazy Print\Logs`. Nothing in the app tells the user to open these folders. Files that other programs read stay outside: the demo printer writes to Documents, which is not redirected, and the files Lazy Scan and Lazy PDF hand over are read by the path in the address (under their `%TEMP%`, which a package is believed not to redirect; not tried). The phone link's certificate (`CompanionCertificateStore`, `CurrentUser\My`) and its persisted CNG key are not app files: Windows keeps them in the user's certificate store and key storage, so they probably survive an uninstall. Whether the package's registry redirection touches that store was not checked.
- `lazyScanInstalled` reads `HKCR\lazyscan`; the packaged app, and only it, then also asks `Launcher.QueryUriSupportAsync` and waits at most 2 seconds, a timeout meaning not installed. It is a precaution: a Store Lazy Scan's `lazyscan:` handler was seen under `HKCR` on Windows 11, and Windows 10 is not checked. The direct build asks the registry only.

The companion server's firewall rule is keyed to the exe's path, which is under `WindowsApps\<package full name>` and changes with each version, so the first phone link after an update may ask Windows Firewall again. `PhoneWindow` reads the rules for `Environment.ProcessPath`, so what it shows (Windows will ask) stays right; nothing was changed for it.

The package has been built with `makeappx` but not installed or signed, so the activation through the address and the AppData redirection are known from the documentation, not from a run. The x64 and arm64 packages and the bundle have been packed, but nothing has run on arm64. `THIRD-PARTY-NOTICES.txt` (ZXing.Net's Apache-2.0 text and the runtime's notices) is a content file of the app, so it is in the publish folder, the zip and the package.

## Render/ (drawing a sheet, Swift)

A `SheetSide` is drawn the same way on both platforms: each placement's page, cropped, turned by its quarter turns and scaled to fill its frame (the planner made the frame the shape of the turned page, so nothing is centred or fitted here); page borders as 0.5 pt gray (128) lines around each frame; a blank back's dot, gray 250, radius 0.5 pt, 8 pt inside the printable area's top-left corner; `TestPageItem`s for the test page, the two-sided check and cut marks, drawn half a turn about the middle of the paper when the side is `turned`. Everything is clipped to the printable area. Global rule 3 holds: the callers pass top-left points and the renderer flips once.

Files, all in `Sources/LazyPrintKit/Render/`, using CoreGraphics, CoreText (the test page's text), ImageIO and UniformTypeIdentifiers only, so the iPhone uses them unchanged:

```swift
/// A document opened for drawing, kept beside its LoadedDocument so SourcePage.document indexes both.
public struct OpenedDocument: @unchecked Sendable {
    public var loaded: LoadedDocument
    public var url: URL
    public var source: Source
    public let drawing = DrawingLock()                       // a class box: copies of the struct share it
    public enum Source { case pdf(CGPDFDocument), picture(CGImageSource) }
}
public final class DrawingLock: @unchecked Sendable { /* an NSLock; drawing a placement of this document takes it */ }

public struct SheetRenderer {
    public init(documents: [OpenedDocument])
    /// Draws one side into a context whose user space is the paper in points, bottom-left as CoreGraphics has it.
    /// Pictures are decoded at no more than `imageDpi` and never enlarged. No white fill: the paper is white.
    public func draw(_ side: RenderedSide, area: PrintableArea, imageDpi: Double = 300, in context: CGContext)
    /// A PDF with one page per side, each page the paper's size in points, written to `url` as it is drawn.
    public func writePDF(_ sides: [RenderedSide], area: PrintableArea, imageDpi: Double = 300, to url: URL) throws
    /// One side as pixels, white behind it, 8-bit gray or RGB.
    public func bitmap(_ side: RenderedSide, area: PrintableArea, dpi: Double, gray: Bool) throws -> SheetBitmap
}
public struct RenderedSide: Equatable, Sendable {      // what SheetSide leaves out, as the Marked list and C#'s DrawnItems
    public var side: SheetSide; public var items: [TestPageItem] = []; public var marked = false; public var turned = false
}
public struct SheetBitmap: Sendable {
    public let width: Int, height: Int, bytesPerPixel: Int           // 1 or 3
    public func row(_ y: Int) -> [UInt8]                             // the rows closure PwgRaster.writePage takes
    public func image() -> CGImage?                                  // for the screen
}
```

- The preview is `bitmap(side, area:, dpi: scale * 72, gray: false).image()`, `scale` being pixels per paper point (zoom times the screen's backing scale), so it is white behind the page in Dark Mode too and there is one path to the pixels.
- A bitmap is made by a `CGContext` of 8-bit gray (`CGColorSpaceCreateDeviceGray`) or RGB (`noneSkipLast`, sRGB) for the whole side, filled white first; `row` copies one line out and drops the pad byte. Letter at 300 dpi is 34 MB in RGB (2550 × 3300 × 4), which is one sheet, as on Windows. The context is released when the `SheetBitmap` is.
- Memory rule, as on Windows: one sheet at a time. `writePDF` and raster printing draw a side, hand it on and let it go before the next, and check for cancellation before each. A picture is decoded for its placement alone with `CGImageSourceCreateThumbnailAtIndex` (`kCGImageSourceCreateThumbnailFromImageAlways`, `kCGImageSourceCreateThumbnailWithTransform` so the EXIF orientation is applied, `kCGImageSourceThumbnailMaxPixelSize` the larger side in pixels at `imageDpi`, capped at the picture's own size). With `crop` set that size is the whole page's size on the sheet (the frame scaled up by the crop), not the frame's, or the shown part would come out soft. PDF pages are drawn as vectors with `CGContext.drawPDFPage`, so a PDF of sheets keeps its text.
- Coordinates: the renderer flips the context once (translate to the paper's height, scale y by -1) and everything is laid out top-left. In that space `CGContext.draw(image)` and `drawPDFPage` come out upside down, so each placement flips back locally (translate to the frame's centre, rotate `turns * 90` degrees clockwise, which is positive in the flipped space, then scale y by -1) before it draws. Text sets the `textMatrix` to a flip as well, and `TestPageItem.text`'s `at` is the top-left of the line box, as in WPF, while `CTLineDraw` draws at the baseline: the baseline is `at.y` plus the font's ascent (`CTFontGetAscent`).
- A placement is clipped to the printable area and to its frame, then draws the page, or the cropped part of it, into the unturned rectangle. Interpolation is `.high`.
- The PDF transform is built by hand. `CGPDFPage.getDrawingTransform` only scales down, never up, so an A5 page fitted on Letter, a small page with Scaling `fit` and a photo sheet's crop would print at their natural size inside their frame. The page's crop box (`getBoxRect(.cropBox)`) has its origin moved to zero, `/Rotate` (normalised to 0, 90, 180 or 270) is applied as a quarter turn that puts the result back in the first quadrant, the shown part (the whole page, or the `crop` in the page's shown, top-left points) is scaled to the unturned rectangle in x and y separately, and a `crop` offsets by its origin. Tests: A5 on Letter with `fit`, a rotated page, and a cropped photo, by the shared pixel probes.
- Text is CoreText (`CTLineDraw`, Helvetica and Helvetica-Bold, sized in points). The arrow is the same seven-point shape as Windows (`ArrowShape`).
- Drawing a document takes its `DrawingLock`: `CGPDFDocument` may be read from any thread, but drawing one from two threads at once (the preview while a job runs) is not documented as safe. The lock sits on the opened document because a `SheetRenderer` is built per use, one for the preview and one inside each printer. It is held for one placement, not for a side, so the preview is not kept waiting for a sheet.
- Contract with Windows: both renderers are tested with the same documents (`Tests/Fixtures/Documents/`) and the same pixel probes (a coloured cell's centre, a border pixel, the dot, outside the clip) in `SheetRendererTests`.

### Render/DocumentLoader

```swift
public final class DocumentLoader: DocumentLoading {          // DocumentLoading: see "App state (Swift)"
    public init()
    public func load(_ url: URL) throws -> OpenedDocument      // PrintError.unreadable(sentence) for the refusals
    public func originalFile(_ document: OpenedDocument) -> URL?    // a PDF, or an upright JPEG; nil for the rest
}
```

- Kind is decided by the file's `UTType` first (`UTType(filenameExtension:)`, `conforms(to: .pdf)` and then `.image`), because ImageIO also reads PDF on macOS and `CGImageSourceCreateWithURL` returns a source for almost any file. When the extension names neither, "%PDF-" in the first 1024 bytes makes it a PDF and anything else goes to the picture check. A picture is refused when `CGImageSourceGetType` is nil or `CGImageSourceGetCount` is 0, and so is a file that is neither: `DocumentText.notSupported`, "Lazy Print prints PDFs and pictures. Save it as a PDF first.". A file that cannot be opened at all is `DocumentText.unreadable`.
- PDF: `CGPDFDocument(url as CFURL)`. If `isEncrypted`, `unlockWithPassword("")` is tried: it fails for a document with a user password, which is refused with `DocumentText.lockedPdf`; it succeeds for one with an owner password only, which opens with `.pdf(encrypted: true)` and always goes as drawn sheets. `isUnlocked` is checked before the page count, so a locked file never comes out as "This PDF has no pages." (`DocumentText.noPages`, for a PDF that is open and empty). `allowsPrinting` is read and ignored, as on Windows; a test must confirm that `drawPDFPage` draws a page of each owner-password fixture (RC4 and AES), with the locked one beside them. Page numbers are 1-based in CoreGraphics and 0-based in `SourcePage`. A page's size is its crop box (which CoreGraphics already limits to the media box) with the normalised `rotationAngle` applied, so 90 and 270 swap width and height.
- Picture: `CGImageSourceCreateWithURL`, a page to a frame for a TIFF and frame 0 only for any other type (a multi-frame GIF is its first frame); `SourcePage.index` is the frame drawn. Size of each frame from `kCGImagePropertyPixelWidth` and `Height`, swapped for the orientation values 5 to 8 (`kCGImagePropertyOrientation`), by `kCGImagePropertyDPIWidth` when that is 72 or more, else as 300 dpi. HEIC reads where the system decodes it; a format the system cannot decode falls under the same refusal.
- `LoadedDocument` is built from these; the handles stay in the `OpenedDocument`, so the state keeps the array and a `SheetJob` carries it.

## App state (Swift)

`Sources/LazyPrintKit/App/`: `@MainActor public final class AppState: ObservableObject`, in extension files as the Windows `AppViewModel`, which has four: `AppState.swift` (published state, the inits, settings, documents, plan and preview), `+Print` (jobs, passes, the two-sided card, errors), `+Printers` (the list, network, trust, the troubleshooter) and `+Tasks`. Where the two differ, the Windows file is the reference and the Swift test says so. Nothing in `App/` imports AppKit, UIKit or SwiftUI.

```swift
@MainActor public protocol PrinterSystem: AnyObject {              // default NoPrinterSystem: no queues
    func queues() async -> [SystemPrinter]                          // virtual ones included; the merge drops them
    func capabilities(ofQueue name: String) async -> PrinterCapabilities?
    func clearJobs(ofQueue name: String) async throws
    func resume(queue name: String) async throws
}
@MainActor public protocol NetworkPrinters: AnyObject {            // default NoNetworkPrinters: nothing found, discovery .unavailable
    var onChange: (() -> Void)? { get set }
    var services: [IppService] { get }
    var discovery: DiscoveryStatus { get }
    var discoveryDetail: String? { get }
    var hosts: [ManualHostStatus] { get }
    func start(); func restart()
    func read(_ endpoint: IppEndpoint) async -> AddressCheck
    func check(_ address: PrinterAddress, firstUse: String?) async -> AddressCheck
    func add(_ address: PrinterAddress, capabilities: PrinterCapabilities)
    func trust(_ certificate: IppCertificateError, deviceUuid: String?, name: String)
}
public struct AddressCheck: Sendable {                             // twin of the Windows record
    public var address: PrinterAddress; public var capabilities: PrinterCapabilities?
    public var certificate: IppCertificateError?                   // refused, and the user can decide
    public var error: String?                                      // no answer, in words; nil with capabilities or a certificate
}
public struct CertificateRequest: Equatable, Sendable {            // what the alert asks about
    public var certificate: IppCertificateError; public var address: PrinterAddress?; public var name: String; public var deviceUuid: String?
}
public protocol SheetPrinter: Sendable {                            // default NoSheetPrinter throws PrintError.noPrinter
    /// One pass: returns when the printer has it all (a queue or network printer: has finished). Task cancellation stops the job.
    func print(_ job: SheetJob, pass: Int, progress: @Sendable (JobStatus) -> Void) async throws
}
public protocol DocumentLoading: Sendable { func load(_ url: URL) throws -> OpenedDocument; func originalFile(_ d: OpenedDocument) -> URL? }
@MainActor public protocol FileActionService: AnyObject {         // default UnavailableFileActions
    func open(_ url: URL) throws; func reveal(_ url: URL) throws; func openWith(_ url: URL) throws
    func copyText(_ text: String) throws; func lazyScanInstalled() -> Bool; func openLazyScan() throws
}
@MainActor public protocol TroubleshooterService: AnyObject {     // default UnavailableTroubleshooterService
    func open(_ action: TroubleshootAction) throws                   // openPrinterSettings, openNetworkSettings, openAppSettings
    func addSystemStatus(to snapshot: inout PrinterSnapshot) async   // the network; the spooler stays unknown (the iPhone's Local Network refusal is `discovery` `.denied`)
}
@MainActor public protocol PlatformLifecycle: AnyObject {          // Lazy Scan's
    func observeWillTerminate(_ handler: @escaping @MainActor () -> Void)
    func observeDidBecomeActive(_ handler: @escaping @MainActor () -> Void)
}
@MainActor public protocol CompanionHosting: AnyObject {          // default NoCompanionHosting: nothing ever arrives
    var onChange: (@MainActor () -> Void)? { get set }              // set by AppState; a file arrived or a batch was taken
    func batches(now: Date) -> [PhoneBatch]                         // the inbox, oldest first, whole or not
    func take(batch: String) async -> [URL]                         // moves the files out of the inbox (off the main actor), in the order sent
    func discard(batch: String)                                     // deletes the batch's files that wait in the inbox
}
public struct DrawnItems: Equatable, Sendable { public var items: [TestPageItem]; public var turned = false }
/// A job as it goes to a printer: what the plan laid out, and what it was laid out from.
public struct SheetJob: Sendable {
    public var name: String; public var printer: PrinterInfo; public var capabilities: PrinterCapabilities?
    public var settings: PrintSettings; public var plan: JobPlan
    public var documents: [OpenedDocument]                          // indexed by SourcePage.document
    public var id = ""                                              // the record's, so a printer that keeps files finds them for pass 2
    public var items: [DrawnItems]?                                 // a job made of drawing items alone: one sheet each
    public var marks: PhotoOptions?                                 // cut marks of photo prints (`cutMarks`)
    public var frameMarks = false                                   // cut marks of a photo sheet (`frameMarks`)
    /// A one-sided job of sides drawn from items alone (the test page, the two-sided check).
    public static func ofItems(name: String, printer: PrinterInfo, capabilities: PrinterCapabilities?, area: PrintableArea,
                               sides: [DrawnItems], id: String = "") -> SheetJob
}
public enum JobSides {                                              // twin of windows/LazyPrint.App/Printing/JobSides.cs
    public static func repeats(_ job: SheetJob) -> Int
    public static func copies(_ job: SheetJob) -> Int               // max(repeats, plan.copiesInJob)
    public static func of(_ job: SheetJob, pass: Int) -> [RenderedSide]    // the pass's sides with the repeats in the file
}
public struct JobStatus: Equatable, Sendable { public var state: JobState; public var sidesDone: Int; public var detail: String? }
public struct PrinterProblemError: Error, Sendable { public var problem: PrinterProblem }   // a stop from the printer's condition
public struct AppError: Equatable, Sendable {
    public var title: String; public var detail: String; public var problem: PrinterProblem?
    public var suggestsTroubleshooter: Bool     // the error is about reaching a printer: the bar offers Troubleshoot
    public var isNotice: Bool                   // something that cannot be done, not something that failed: the info glyph
}
public enum DuplexStep: Equatable, Sendable { case reload, checkBack, checkAnswer }     // the Windows DuplexStep without None
public struct DuplexCard: Equatable, Sendable { public var step: DuplexStep; public var text: String; public var sheets: Int }   // text from ManualDuplexText, as Windows
public struct AppStateFiles { public var settingsDirectory: URL; public var logsDirectory: URL?; public var demoPrints: URL
    public static var standard: AppStateFiles { get }; public static func all(in folder: URL) -> AppStateFiles }
```

Every protocol has a no-op default in `App/`, picked with `service ?? Default()` as in Lazy Scan, so `AppState()` is a working state with no printers and a Mac or iPhone shell passes what it has. The demo printer is not a protocol: `AppState` owns a `DemoPrinterState` and `DemoPrinter` (see "The demo printer") and `RoutingSheetPrinter` (`Printing/`) sends a job by `PrinterInfo.route` to the system printer the shell passed in, to `IppSheetPrinter` or to the demo printer. A shell passes `systemPrinter: (any SheetPrinter)?`; `ipp` and `demo` are built by `AppState`.

```swift
public convenience init(printerSystem: (any PrinterSystem)? = nil, network: (any NetworkPrinters)? = nil,
                        systemPrinter: (any SheetPrinter)? = nil, documents: (any DocumentLoading)? = nil,
                        fileActions: (any FileActionService)? = nil, troubleshooter: (any TroubleshooterService)? = nil,
                        lifecycle: (any PlatformLifecycle)? = nil, background: (any BackgroundActivity)? = nil,
                        companion: (any CompanionHosting)? = nil, platform: AppPlatform = .mac)
public init(..., files: AppStateFiles)                             // tests, and the iPhone's -demoPrinter: every file in a temp folder, no polling started
```

Published state, `public private(set)` unless said: `printers: [PrinterInfo]` (the merge of `printerSystem.queues()`, `network.services` and the demo printer, last); `selectedPrinter`; `capabilities` of the selected one (the system's for a queue, IPP's when the queue would not say; IPP's for a printer found only on the network); `settings: PrintSettings` (settable; saves to `settings.json` after 0.5 s and when the lifecycle says it will terminate); `printerPrefs`; `task: PrintTask?`; `documents: [OpenedDocument]` and `pageRange`; `jobPlan: JobPlan?` and `previewSide: Int`; `preview: CGImage?` (the current side, redrawn off the main actor, latest request wins; asked for again with the same side, area, scale and documents it is not drawn again, and a request that was cancelled before it began draws nothing); `duplexCard: DuplexCard?`; `jobs: [JobRecord]`; `error: AppError?` (for Troubleshoot) with `errorsShown`, a count that goes up each time an error or notice is put in the bar, which a screen compares before and after an action (`errorDetail(since:)`) because a second identical error cannot be told by its value; `certificateRequest: CertificateRequest?`; `status: String` and `statusAccessible` (`StatusLine`); `snapshot: PrinterSnapshot` and `troubleshootChecks`; `isBusy`.

- Printers: `refreshPrinters()` merges and keeps rows' identity so views update in place; a call that comes while a read runs returns at once, and the read runs once more when it ends. A system row with no capabilities of its own takes IPP's from its address, whether or not the queue was asked; the queue's win once they come. While the window is open (`setActive(true)` when it opens, `setActive(false)` when it closes, as the Windows polling) the system queues are read every 5 s and network rows' status every 30 s; `network.onChange` refreshes at once. A system row with an IPP twin takes its supplies and problems from IPP and its own state from `queue`. The saved `printerId` is chosen when it exists, else the default queue, else the first printer that is not the demo printer; the demo printer is in use only when it is the saved choice, so with no other printer there is none and Print says "needs a printer". `selectPrinter(_:)` takes the printer's capabilities at once (nil for one not read or that would not say, never the previous printer's), reads them if not yet read and re-plans, and a list change that changes the selected printer's re-plans too; the capability read of a changed certificate is never started from the background (`certificateRequest` is set only for a user action), as on Windows.
- Tasks and documents: `startTask(_:)` (`TaskCatalog.apply`; Test page, Scan and print and From your phone act at once and are not kept), `addFiles(_ urls:)` loads each off the main actor and appends in order (the files that fail are named with their sentences in one error bar message, "Photo 2.heic: Lazy Print can't read this file.", a line each, three at most and then "and 2 more"; the others still load), `reportUnreadable(_ names:)` (files that never reached `addFiles`, said the same way), `remove` (clears the page range when it empties the list), `move`, `setPageRange(_:)` (`PageRange.parse`, the message under the field). Every change to settings, documents, range or printer calls `replan()`, which runs `PrintJobs.plan` and starts a preview redraw.
- Printing: `print()` collects the job's inputs (printer, capabilities, settings, task, documents, range, name), plans, builds a `SheetJob` and a `JobRecord` (`JobState` follows the printer's `JobStatus`) and runs the pass in a `Task`. The tasks live in `AppState`, keyed by record id (`JobRecord` is an `Equatable`, `Sendable` struct in Core and holds none), and Cancel cancels the one for its record. A one-pass job ends with "Sent 3 sheets to HP LaserJet" (`PrintText`).
- Print again keeps the inputs of the last 10 jobs, not the jobs: `printAgain(_ record:)` plans again with the printer's capabilities and preferences as they are now, as Windows does. When the inputs are gone it shows the notice "This job is too old to print again. Add its files again." (title "Print again").
- Two-sided by hand, the Windows steps in `+Print`, driven by the view model (the printer prints one pass per `print` call):
  - A manual job prints its fronts (pass 0). A failed or stopped fronts pass shows no card. When it succeeds the card is on `.reload` and the record says `PrintText.LoadBacks`.
  - `printBacks()` on `.reload` runs pass 1; on success the card goes away and the job is Sent. A failed or stopped backs pass leaves the card on `.reload`.
  - `checkDuplex()` on `.reload` prints the check sheet's front (`ManualDuplex.checkSheet`, as `SheetJob.ofItems`, not announced) and moves to `.checkBack`. `printCheckBack()` prints the check's back, `turned` when the printer's `PaperPath.turnBacks` says so, and moves to `.checkAnswer`. Each is one sheet job, so a printer that prints one side needs no second job inside a pass.
  - `answerDuplexCheck(_ DuplexCheckAnswer)` learns the paper path (`ManualDuplex.learn`), saves it in `printers.json`, plans the job again with it and goes back to `.reload`.
  - `cancelManualDuplex()` ends the card; the fronts stay printed and the record is canceled.
  - Print is greyed ("Finish the two-sided job first") while a card is open.
- Errors: `PrinterProblemError` and `PrintError` become `error` (title by what is wrong, advice as detail, `problem` set when Troubleshoot applies). An `IppCertificateError` that can be trusted becomes `certificateRequest`; `trustCertificate()` pins it and sends the job again.
- Troubleshooter: `openTroubleshooter()` builds the `PrinterSnapshot` (printers, `troubleshooter.addSystemStatus`, `network.discovery`, `network.hosts`, stuck jobs from the queues, `lastFailure` from the last failed job or connection), runs `Troubleshooter.diagnose` and keeps the checks; `perform(_ action:)` runs the action (only `clearStuckJobs` and `resumePrinter` ask first and say what they did). The report goes to `printers.txt` in `logsDirectory`.
- Status line: from `StatusLine` over the state of printing, planning and the printer list; the full sentence for screen readers.

Tests (`Tests/LazyPrintTests/AppStateSeamTests.swift`, the Swift twin of the `AppViewModel` tests in `LazyPrint.App.Tests`): stand-in services record calls; a task sets its settings; a printer without duplex gets the card; the card's passes go fronts then backs; a failed fronts pass shows no card and a failed backs pass stays on `.reload`; the check goes `.reload`, `.checkBack`, `.checkAnswer`, and the answer plans again with the learned path; a failed job puts its problem in the error bar; the system and network lists merge into one row; a changed certificate is asked about only for a user action; settings survive a restart from the same `AppStateFiles`; Print again plans again with the printer's current capabilities, and says "too old" when the inputs are gone. No test starts a timer: polling is started by the shell calling `setActive(true)`, which the tests do not.

## Printing on the Mac

The Mac lists and prints to its queues with libcups, not with `NSPrinter`, `PrintCore` or `NSPrintOperation`. Reasons: libcups is in the SDK and links without entitlements or a sandbox exception; one source gives the queue list, state reasons, device URI, marker levels, papers with their imageable areas and duplex and colour support, all as IPP attributes the Kit already knows how to read; and a job is IPP attributes sent straight to the scheduler, so nothing in the settings of a print panel, the last-used preset or the driver's defaults can come back. `NSPrintOperation` is used nowhere.

`import CUPS` may not exist as a module in the macOS SDK, and `.linkedLibrary("cups")` fixes linking, not importing. The fallback is named now so the first CI failure has a known next step: a `systemLibrary` target `CCups` (`Sources/CCups/module.modulemap` with `module CCups [system] { header "shim.h"; link "cups"; export * }`, `shim.h` including `<cups/cups.h>`), and the Mac target imports `CCups`. Either way, `CUPS_HTTP_DEFAULT` is a macro with a cast, which Swift does not import: every call passes `nil` as the connection.

Files in `Sources/LazyPrintMac/App/`: `CupsQueues.swift` (`PrinterSystem`), `CupsStates.swift` (pure: reasons to `SystemQueueState`), `CupsOptions.swift` (pure: the job's options), `CupsPrinter.swift` (`SheetPrinter`). Every libcups call is made on a serial `DispatchQueue`, wrapped by an async function. A serial queue does not pin a thread, and `cupsLastErrorString` and the default connection are per thread, so a failed call's error is read in the same block as the call. A long `cupsPrintFile2` would hold up the 5 s queue listing, so the sending has a queue of its own.

- Listing: `cupsGetDests2(nil, &dests)`, freed with `cupsFreeDests`. Each destination's options carry `printer-state` (3 idle, 4 processing, 5 stopped), `printer-state-reasons`, `printer-is-accepting-jobs`, `device-uri`, `printer-make-and-model`, `printer-info`, `printer-type`, `marker-names`, `-levels`, `-colors`, `-low-levels`, `-types` and `printer-uuid` when the scheduler reports it; the scheduler's default is `is_default`. A listing that comes back empty with an error status (0x0400 or more) is a scheduler that did not answer: the queues read last are kept, as on Windows. A destination that is a class or has no queue is skipped. Instances (`name/instance`) are skipped, they are saved option sets, not queues; when the default destination is an instance, the default flag goes to its base queue. `SystemPrinter.port` is `device-uri`; its `uuid` is `printer-uuid`, else the `uuid` query item of a `dnssd://` device URI (driverless queues carry it there; a test on sample strings pins this, a real queue confirms it). `isVirtual`: the device URI's scheme is `cups-pdf`, `file` or `fax`, or `printer-type` has `CUPS_PRINTER_FAX` (0x40000). 0x4 is `CUPS_PRINTER_BW`, so a black-and-white printer is a real one: `CupsQueuesTests` has a mono `printer-type` that must not be virtual.
- States (`CupsStates.describe(state:, reasons:, accepting:) -> [SystemQueueState]`): a reason's `-error`, `-warning` and `-report` suffix is dropped, then `paused` and state 5 give `paused` (not accepting jobs does too), `offline` and `connecting-to-device` `offline`, `media-empty` and `media-needed` `paperOut`, `media-jam` `paperJam`, `door-open` and `cover-open` `doorOpen`, `toner-low`, `marker-supply-low` and `marker-waste-almost-full` `tonerLow`, `toner-empty` and `marker-supply-empty` `noToner`, state 4 `busy`, any other `-error` reason `error`. Jobs: `cupsGetJobs2(nil, &jobs, name, 0, CUPS_WHICHJOBS_ACTIVE)`, `cups_job_t.state` (IPP_JSTATE_STOPPED 6 and ABORTED 8 count as error) and `creation_time` for the oldest. Supplies of a queue come from its IPP twin; a queue with no twin shows none yet, since `SystemPrinter` has nowhere to carry the `marker-*` options.
- Capabilities for a queue with no IPP twin: `cupsCopyDestInfo(nil, dest)`; papers by `cupsGetDestMediaCount` and `cupsGetDestMediaByIndex` (`CUPS_MEDIA_FLAGS_DEFAULT`, again with `_BORDERLESS`), each `cups_size_t` (hundredths of a millimetre, with `left`, `bottom`, `right`, `top` margins) one `MediaEntry`; duplex by `cupsCheckDestSupported(..., CUPS_SIDES, "two-sided-long-edge")`; colour by the values of `print-color-mode` from `cupsFindDestSupported`; copies by `copies`. The `PrintableArea` of a paper is the entry's margins, as with IPP. Queues made from a PPD answer through CUPS' PPD-to-IPP mapping; a test on a Mac with a PPD queue must confirm that papers and duplex come back (the CI runner has no printers, so those tests skip with their reason).
- Clear stuck jobs: `cupsCancelJob2(nil, name, CUPS_JOBID_ALL, 0)`. Cancelling other users' jobs needs an administrator, and so does Resume (a Resume-Printer request through `cupsDoRequest(..., "/admin/")`); Resume sends Resume-Printer and then CUPS-Accept-Jobs (0x4008), since a queue that refuses jobs is `paused` too and Resume-Printer alone leaves it refusing; when the scheduler answers forbidden or not authenticated the app opens Printers & Scanners instead and says so. Both confirm on a real Mac.

### A job to a queue, with the settings forced

`CupsPrinter` writes the pass's sheets as a PDF (`SheetRenderer.writePDF`, one page per side, each the paper's size; the Kit decided the copies already, so `JobSides` puts the repeats in the file) and sends it with `cupsPrintFile2(nil, queue, path, title, count, options)`, which returns the job id (0, and the error read at once, on failure). `cupsPrintFile2` over `cupsCreateDestJob` and `NSPrintOperation`: it is one call with the options as a dictionary, which the pure function builds and a test compares.

```swift
enum CupsOptions {
    /// `copies` is what the queue makes (JobPlan.copiesInJob); `media` is the PWG or PPD name of the paper's closest size in the queue.
    static func forJob(sides: Sides, copies: Int, collate: Bool, color: ColorChoice, quality: QualityChoice,
                       media: String?, duplexPass: Bool) -> [String: String]
}
```

It always sets `document-format=application/pdf`, `orientation-requested=3` (portrait: the page is already the sheet), `print-scaling=none` with the older `fit-to-page=false` and `scaling=100` (Apple's PDF filters read the old names, cups-filters the new one; sending both costs nothing), `number-up=1`, `outputorder=normal`, and `sides=two-sided-long-edge` or `one-sided` (manual passes are one-sided). `copies` only when above 1, with `multiple-document-handling=separate-documents-collated-copies` or, collate off, `separate-documents-uncollated-copies`; `print-color-mode=color|monochrome`; `print-quality=3|4|5` for draft, normal and best, so a queue's own default does not come back; `media=` from `cupsGetDestMediaBySize(nil, dest, info, widthHundredths, heightHundredths, CUPS_MEDIA_FLAGS_EXACT or default, &size)`. Booklets and N-up are imposed by Lazy Print, never by the queue. Why this forces the settings: CUPS applies job attributes over the queue's defaults, and these are the attributes its PDF filter chain reads for layout, so the sheets are printed as drawn. What no test on the CI runner can prove is that Apple's `cgpdftopdf`/`pdftopdf` honours each one for a PDF with a driver in the way; the first run on a real queue (print the fixture of 4 sheets, check that nothing is scaled, 1-up and in order, and the backs of a two-sided job land correctly) decides, and `CupsOptions` is the one place to change.

Tracking: after the job id comes back, a Get-Job-Attributes request for that one job (`cupsDoRequest`, `requested-attributes` `job-state`, `job-state-reasons`, `job-impressions-completed`) every 2 s, so the queue's job history is never read. The mapping is `pending` to `waiting`, `pending-held` to `needsUser`, `processing` to `printing`, `processing-stopped` to `needsUser`, `completed` to `done`, `canceled` to `canceled` and `aborted` to `failed`; a job the scheduler no longer knows counts as done. `job-impressions-completed` is `sidesDone`. Cancel (task cancellation) calls `cupsCancelJob2(nil, queue, id, 0)`. A queue stopped or not accepting before the send throws `PrinterProblemError`.

Difference from Windows, deliberate: `SpoolerPrinter` returns once the XPS is in the spooler, while `CupsPrinter.print` returns when CUPS reports the job completed. The two-sided card must not ask for the stack before the fronts are out, and a job held for sign-in then shows as `needsUser` in the Jobs tab with Cancel working, instead of the pass ending at once on a job that never prints. A job held for ever blocks the pass until the user cancels.

### The demo printer (Swift)

`Sources/LazyPrintKit/Printing/DemoPrinter.swift`, with `DemoPrinterState` (`@MainActor ObservableObject`: `duplex`, `outOfPaper`, four inks that fall 2 points a job, the folders by job id, `root`) as the C# types of the same names: Letter, A4 and 4 × 6 in with 0.17 in margins, `printColorMode`, copies and `separate-documents-collated-copies` supported. Each side is drawn with `SheetRenderer.bitmap` at 150 dpi (gray for a gray job) and written with `CGImageDestination` (`UTType.png`) into `<root>/yyyy-MM-dd HH.mm.ss <job name>[ n]/`, files named "Sheet 2 front", "Sheet 2 back", "Sheet 2", "Fronts 2", "Backs 2" as on Windows (`DemoPrinterTests` shares the cases). A gray job uses only the black ink, as on Windows. `DemoPrinter` is `Sendable`, so it reads the state's switches once at the start of a pass and hops to the main actor (`await MainActor.run`) for that read and for the one ink drop after the files are written. The date is formatted with `en_US_POSIX`. `root` is `~/Documents/Lazy Print/Demo prints` (`FileManager.urls(for: .documentDirectory)`; in the sandboxed build that Documents is the app container's, and Show in Finder opens it); in the direct build (`make_app.sh`, unsandboxed) the first write there makes macOS ask once for access to Documents, and `NSDocumentsFolderUsageDescription` in its plist is what the prompt shows; the sandboxed store build writes to its container's Documents and asks nothing. Tests give a temp folder.

### IPP printers from the Mac

`IppSheetPrinter` (`Sources/LazyPrintKit/Printing/IppSheetPrinter.swift`, Kit, so the iPhone has it too) is the twin of the Windows class: `DocumentFormats.choose(supported:, kind:, canWritePDF: true)`; a PDF or upright JPEG that prints as it is goes as the original (`DocumentLoading.originalFile`, ticket `asIs`); otherwise `application/pdf` from `writePDF` when the printer lists it, else PWG raster, else URF, drawn with `SheetRenderer.bitmap` at the resolution Core picks and fed to `PwgRaster.writePage` a row at a time into an `IppSpool`; then `IppClient.print`, and `IppClient.job` every 2 s until the job ends, `IppClient.cancel` on task cancellation. A refusal of the format is retried once as raster, as the Ipp section says. Three missed answers in a row end the job with `PrintError.lostContact(name)` when the last was `.unreachable` (the printer has the job, so the error bar is titled "Lost contact with <printer>" and says to check the printer before printing again), and with the error itself otherwise, such as `.needsSignIn`.

`NWBrowserPrinters` (`Sources/LazyPrintKit/Printing/NWBrowserPrinters.swift`, Kit, Network framework and dnssd, so the iPhone has it too; implements `NetworkPrinters`): one `NWBrowser(for: .bonjourWithTXTRecord(type: "_ipp._tcp", domain: nil), using: .tcp)` and a second for `_ipps._tcp`; `browseResultsChangedHandler` gives `NWBrowser.Result`s whose `endpoint` is `.service(name:type:domain:interface:)` and whose `metadata` is `.bonjour(NWTXTRecord)`; the TXT entries (`NWTXTRecord.dictionary`) become `IppService.textAttributes`. `NWBrowser` does not resolve, and an `NWConnection` gives only the one address that connected, no host name, and a TCP connection to every printer. Each new service is resolved with `DNSServiceResolve` (host name and port) and `DNSServiceGetAddrInfo` (every address, IPv4 and IPv6, a link-local one with its interface index as the zone), on the dnssd dispatch queue (`DNSServiceSetDispatchQueue`), and the references are deallocated when the answer is in or after 5 s; a service without an answer stays without addresses and is retried on the next change. So `IppService.hostName` is set and the IPv4-then-`.local` order in `IppEndpoint.choose` works. A browser in `.failed` or `.waiting` with `NWError.dns(kDNSServiceErr_PolicyDenied)` (`import dnssd`) sets `discovery = .denied` and the detail; `.ready` with no results is `.running`. The conversion from result to `IppService` is a pure function (`IppServices.from(name:type:txt:)`), and the browser sits behind a small seam (`Browsing`, with `Resolving` for the resolver) so `NWBrowserPrintersTests` feeds it results; real discovery is checked by hand. `ipp-hosts.json` is read by `IppHostList` at start and every minute while an address does not answer, each answering address made an `IppService` with id `address:<address>` and its UUID, as on Windows; `read` and `check` call `IppClient` with the app's `IppCertificateValidator` and `IppTrustStore`. A read that gets an answer moves the address that answered to the front of that printer's `ippEndpoint` (`IppEndpoint.preferring`, on both platforms), and jobs, their polls and Cancel-Job go to the first address, so they reach the address the status came from. A plain ipp address never goes ahead of an ipps one: the ipps address of the same host goes first, and the order is left alone when there is none.

## The Mac app (Sources/LazyPrintMac)

Lazy Scan's Mac app, with the screens of the Windows one. Every file is wrapped whole in `#if os(macOS)`. `Sources/LazyPrint/main.swift` is the launcher (`LazyPrintApp.main()`).

- `App/`: `LazyPrintApp` (a `WindowGroup`; `ContentView` has `.onOpenURL` and `.handlesExternalEvents(preferring: ["*"], allowing: ["*"])`, as Lazy Scan's, so open-file events go to the window there is and do not multiply it; commands remove New Window and add File > Add Files… (Cmd-O, off while a job runs or one of the window's sheets is up; the window opens its panel on a notification), Print… (Cmd-P, on while `canPrint` and no sheet is up, as the Print button) and Cancel Printing (Cmd-., on while a job runs, as the status bar's Cancel); Help links to the product site once there is one; the `AppState` is made in its `init`, so no URL arrives before it exists), `AppDelegate` (quit with a job running asks first, and quit with a two-sided job waiting for its backs asks too; for the first, when told to quit waits (`terminateLater`) until the job's task has ended, which is after the printer was asked to drop the job; the app quits after its last window; no `application(_:open:)`: once the delegate implements it AppKit sends it every URL and `.onOpenURL` never fires), `AppKitLifecycle` (as Lazy Scan's), `CupsQueues`, `CupsPrinter`, `SystemFileActions` (`NSWorkspace` open, open with, reveal; `NSPasteboard`; `lazyscan:` through `NSWorkspace.urlForApplication(toOpen:)`), `SystemTroubleshooterService` (System Settings through `x-apple.systempreferences:com.apple.Print-Scanner-Settings.extension` and the Network pane; the network's state from an `NWPathMonitor` read once), and `AppState.makeForMac()`.
- `UI/`: `ContentView` (`NavigationSplitView`, the sidebar and a segmented picker Print, Jobs; the error bar, the status bar and the "Sent" bar above it), `SidebarView` (`List` with `.sidebar` style: printers with a state dot, a one-line problem and supply bars, the demo printer last with "Demo (no hardware)" under its name and its menu of switches, "No other printer found" when it is alone, + for Add by address and ? for the troubleshooter), `TaskSymbols` (mapping `iconKey` to SF Symbols), `PrintView` (a bar on top with a Task menu, `TaskCatalog` in a section per group, the current task checked, an unavailable one disabled with its reason, and once a task is picked its title and Leave the task; the preview with "Sheet 2 of 5", previous, next and Front/Back; `DocumentStrip` under it; `InspectorView` on the right with `InspectorSections` as collapsible sections stored in `@AppStorage`; the Print button that says what it does), `JobsView` (records newest first, Cancel, Print again, Show for the demo folder), `DuplexSheet` (the two-sided card as a `.sheet` with its own certificate alert, since the window's would not show over it; Escape moves to Cancel only; Cancel stays live while a pass runs and stops it, the other buttons wait), `TroubleshooterView` (a `.sheet`), `AddPrinterView` (a `.sheet`, the address checked before it is added), and `.alert` for the certificate (Trust, Cancel; the wording as Lazy Scan's). The preview image is `Image(decorative:scale:)` of `AppState.preview` at the view's size times the screen's backing scale.
- Files in: `.dropDestination(for: URL.self)` on the main content adds PDFs and pictures from anywhere on the window (a drop of nothing but folders says "Lazy Print prints PDFs and pictures. Save it as a PDF first." in the error bar); a task that opens files, picked with no documents, uses `.fileImporter` (an open panel) with `[.pdf, .image]`. `Package.swift` and `make_app.sh` declare the app as a viewer of `com.adobe.pdf` and `public.image` (`CFBundleDocumentTypes`, `CFBundleTypeRole` Viewer, `LSHandlerRank` Alternate, so it is offered in Open With and never takes over a default). Files from Open With, the Dock icon and `open` arrive in `.onOpenURL` with the `lazyprint:` URLs, which are told apart by scheme: a file URL is added, a `lazyprint:` URL brings the window forward and adds the files it names (`LazyPrintUrl`, absolute paths only; "Hand-off"). The scheme is registered with `CFBundleURLTypes`.
- The phone link: `App/MacCompanionHosting` (an `ObservableObject` and the `CompanionHosting` of `AppState`; it builds the `CompanionService` from `CompanionCertificateStore`, `MacNetworkSource`, `MacDnsSdAdvertiser` and `MacCompanionSyncKeys` when a phone is paired at launch or the phone sheet opens, and holds a lock file in the data folder so only one copy of the app receives, the others being told `.elsewhere`). `UI/PhoneView` is a sheet from the iPhone button in the sidebar header and from the task From your phone (`AppState.phoneWindowRequested`, set by `ContentView`); `UI/PhoneBarView` is the bar above the tabs that offers the oldest whole batch (Add to this job, Start a new job, Dismiss, the first two off while a job runs), and the Dock icon bounces once when the app is in the background.
- `Package.swift` gains the targets `CCups` only if the fallback is needed, `LazyPrintMac` (depends on `LazyPrintKit`), the executable `LazyPrint` (depends on `LazyPrintMac`; the product `.executable(name: "LazyPrint")`) and `LazyPrintMacTests`, all with explicit paths.

`scripts/make_app.sh` is Lazy Scan's with the names changed: `swift build -c release`, `dist/Lazy Print.app` (bundle id `local.lazyprint.app`, executable `LazyPrint`, `LSMinimumSystemVersion` 14.0, version 1.0), the icon (the PNG `scripts/make_ios_icon.py` draws, scaled with `sips` and packed with `iconutil` as Lazy Scan's script does), `codesign --force --deep -s -` ad hoc, no entitlements and no sandbox. Info.plist keys beyond the usual: `CFBundleDocumentTypes`, `CFBundleURLTypes`, `NSDocumentsFolderUsageDescription`, `NSLocalNetworkUsageDescription` ("Lazy Print looks for printers on your local network, so you can print to them, and receives files from your paired phone.") and `NSBonjourServices` (`_ipp._tcp`, `_ipps._tcp`, `_lazyprint._tcp`). The last two are not needed for the code to work: macOS 14 does not ask, but macOS 15 and later can ask for Local Network access when an app browses or connects to local hosts, and the two keys are what that prompt shows and allows. The phone link adds no key and no entitlement: an app that is not sandboxed may listen and use the legacy keychain, and the first connection from a phone can bring up the system firewall's "accept incoming connections" question, which belongs to the system. Whether an ad-hoc signed app is asked at all on 15 can only be seen on a Mac; `discovery = .denied` and its troubleshooter line cover the answer "no".

App Transport Security: `NSAllowsArbitraryLoads` is set. ATS exempts IP addresses, unqualified names and `.local` hosts, but a printer added by hand by its name on a home or office network (`printer.lan`, `printer.example.com`) over `ipp://` would be refused, and `NSAllowsLocalNetworking` does not cover it. Printers answer plain HTTP by design and the app makes no other requests, so lifting ATS costs nothing here; the iPhone decides for itself.

### LazyPrintMacTests

No window and no printer. `CupsOptionsTests` (the options for each combination of sides, copies, collate, colour, quality, compared as dictionaries; the forced ones always present), `CupsStatesTests` (reasons to states, with suffixes), `CupsQueuesTests` (device URI to port and UUID on sample strings; virtual queue detection, with a mono `printer-type` that is not virtual; a call to `cupsGetDests2` that passes with zero or more destinations, so linking is proved on the runner; the tests that need a real queue use `XCTSkipUnless` with the reason, and `LAZYPRINT_REQUIRE_CUPS_QUEUE=1` makes the skip a failure), `SystemFileActionsTests` (how the URLs are built, as pure functions; `NSWorkspace` itself is not wrapped or tested), `AppKitLifecycleTests` (posting notifications on a private centre). The services against the loopback IPP printer (`IppSheetPrinterTests`: the PDF the printer receives, its pages and sizes, the ticket; the raster fallback decoded with the test `RasterReader`; cancel), `NWBrowserPrintersTests` (TXT and endpoint to `IppService`, denied and failed states, through the seam), `DemoPrinterTests`, `SheetRendererTests`, `DocumentLoaderTests` and the AppState flows are in `Tests/LazyPrintTests`, since the iPhone runs them too.

`ScreenshotTests` (Mac tests, skipped with the reason unless `LAZYPRINT_SHOTS` names a folder): `NSApplication.shared` is touched first (a window cannot be built without it under xctest; a guess the first run confirms). It builds an `AppState` on a temp `AppStateFiles` with the demo printer and a fixture PDF, hosts `ContentView` in an `NSHostingView` inside an off-screen `NSWindow` (1280 × 800, `appearance` set to aqua and darkAqua in turn), calls `layoutSubtreeIfNeeded()`, and writes a bitmap at twice the points (2560 × 1600, a Mac App Store size) after `cacheDisplay(in:to:)` as PNG `mac-<screen>-<light|dark>.png` for: print with a 2-up plan, print with a photo sheet, jobs after a demo job, the two-sided card, the troubleshooter with "No printer found" and with a stopped printer, add printer. These are not assertions of pixels; they exist so the screens can be looked at without a Mac. Open: `NavigationSplitView`, `List` and `Form` may draw empty when hosted off-screen; if the first CI run shows that, the fallback is one hosted view per column and `ImageRenderer` for the cards, and the test file says which.

## CI

`.github/workflows/ci.yml`, job `macos` (it already runs `swift build` and `swift test --parallel` on `macos-15` with Xcode 16.4, which now include `LazyPrintMac`, `LazyPrint` and the shared Render and App tests). Added after Build:

```yaml
      - name: Test
        run: swift test --parallel
        env:
          LAZYPRINT_SHOTS: ${{ runner.temp }}/shots
      - name: Screens
        if: always()
        uses: actions/upload-artifact@v7
        with:
          name: mac-screens
          path: ${{ runner.temp }}/shots
          if-no-files-found: warn
      - name: Build the app
        run: |
          bash scripts/make_app.sh
          plutil -lint "dist/Lazy Print.app/Contents/Info.plist"
          codesign --verify --deep "dist/Lazy Print.app"
          ditto -c -k --keepParent "dist/Lazy Print.app" "$RUNNER_TEMP/LazyPrint-mac.zip"
      - name: App
        uses: actions/upload-artifact@v7
        with:
          name: lazyprint-mac
          path: ${{ runner.temp }}/LazyPrint-mac.zip
```

The test step replaces the present one. The folder `LAZYPRINT_SHOTS` names is made by the test. The built app is ad-hoc signed and unnotarised; downloaded from the artifact it needs Control-click, Open once. `ScreenshotTests` run with the other tests, in debug as now; if debug tests turn slow as Lazy Scan's did, the step moves to `swift test -c release -Xswiftc -enable-testing --parallel` as there. The `windows` job runs the new C# cases (`DocumentText`, `PrintError`, the `DrawMarks` clip) and is otherwise unchanged. The iPhone jobs come with the iPhone app.

Confirmed only by the first CI run (each is a test that fails loudly, none is assumed): `import CUPS` (else `CCups`) and the libcups symbols above link on the runner; `drawPDFPage` draws the owner-password PDFs; `NSHostingView` renders the sidebar and inspector off-screen; `cupsGetDests2` returns on a runner with no queues.

## The iPhone app (Sources/LazyPrintIOS)

The screens and flows of the Mac app, in Lazy Scan's iPhone idiom: one column, `NavigationStack`s, sheets. iPhone and iPad (`TARGETED_DEVICE_FAMILY` 1,2, all four orientations on the iPad, no `UIRequiresFullScreen`), iOS 18. A regular-width window (the iPad) lays the Print screen out as landscape does, the sheet on the left and the rest on the right, and the Jobs list keeps to a readable width (`readableWidth`). Every file is wrapped whole in `#if os(iOS)`. `AppState`, the printers, the renderer and the document loader are the Kit's, unchanged: nothing here plans, draws or speaks IPP. Lazy Scan's `Sources/LazyScanIOS` is the model for structure, naming and idiom (`IOSLaunchOptions`, a caseless `IOSShell`, `...Text` enums of static strings, dotted accessibility identifiers such as `print.copies`).

### What prints

Printers come from two places.

- Network printers: `NWBrowserPrinters` and `IppSheetPrinter`, from the Kit, as on the Mac. They need Local Network access. There is no API to ask for it or read it; the first browse brings up the prompt, and a refusal is inferred as Lazy Scan's `IOSLocalNetworkProbe` does (TN3179).
- An AirPrint printer the user picks: iOS will not list printers, so `IOSPrinterSystem` (`PrinterSystem`) has one queue at most, the printer last chosen with `UIPrinterPickerController` ("Choose an AirPrint printer…" in the Printers screen). Its URL is kept in `UserDefaults` and rebuilt with `UIPrinter(url:)`. This route needs no Local Network access, which is why it exists: a phone that refused it can still print.

`IOSPrinterSystem.capabilities` calls `contactPrinter` and reads `supportsDuplex` and `supportsColor`; copies are left to the job (`copiesSupported` stays 1), since `UIPrintPageRenderer` has no copy count. The papers are the region's default (Letter in the US and Canada, A4 elsewhere) plus the other, with 0.25 in margins, which is what Lazy Scan assumes. An AirPrint printer that can't be reached is `offline`. The queue is listed at once, `offline` until the printer has answered (the contact takes up to 5 s and runs after `queues()` has returned). An answer is kept for 30 s (`recheckAfter`): `queues()` and `capabilities(ofQueue:)` contact the printer only when it is older, so an offline printer is not contacted on every poll; `isReachable()`, which a job asks before it is sent, always asks. On the iPhone `AppState` asks for the capabilities of a system printer that gave none again until it answers; on the Mac it asks once (`cupsCopyDestInfo` has no timeout and runs one at a time). `IOSAirPrintPrinter` sends a job only to the queue it was planned for, and only after the printer has answered; a two-sided pass of a job done by hand goes out one-sided; the wait for the print ends at the completion handler, at a refusal to start, or at Cancel, whichever comes first.

`IOSAirPrintPrinter` (`SheetPrinter`, the `systemPrinter` the shell passes) writes the pass with `SheetRenderer.writePDF` and sends it through `UIPrintInteractionController.print(to:)`, with a `UIPrintPageRenderer` drawing each page 1:1 and `UIPrintInteractionControllerDelegate` choosing the paper with `bestPaper(forPageSize:withPapersFrom:)`, as Lazy Scan's `IOSPrintService`. `printInfo.duplex` is `.longEdge` or `.none`, `outputType` `.general` or `.grayscale`. The completion handler means the system took the job, so the job ends as sent; iOS gives no further status. Copies are repeated in the job (`UIPrintPageRenderer` has no collate). Cancel before the completion dismisses the controller and then ends the wait; what the print uses (the renderer, which holds the pages in memory, the print info and the paper chooser) stays set until the completion handler or a refusal to start, and is cleared only while the controller still holds that pass's renderer. iOS has no call to take back a job it took, so Cancel cannot stop a job the printer already has.

### Files

- `Package.swift` gains `LazyPrintIOS` (library product and target, depends on `LazyPrintKit`) and `LazyPrintIOSTests`.
- `LazyPrintIOSApp.swift`: builds its objects in `init`, as Lazy Scan's; `.onOpenURL` (a file URL goes through `IOSFileInbox`; `lazyprint:open?handoff=<uuid>` takes Lazy Scan's files, see "Hand-off"; any other `lazyprint:` URL only brings the app forward).
- `IOSShell.swift`: `IOSLaunchOptions` (`-demoPrinter`: the demo printer only, settings in a temp folder, no network browse; `-openFixture <file name>`: opens a file from the UI test bundle as if shared, as Lazy Scan's import fixtures: the test passes the file's bytes, base64, in `LAZYPRINT_FIXTURE`, since the app cannot read the test bundle), `AppState.makeForIOS(options:)`.
- `IOSFileInbox.swift`: what the pickers and Open In hand over is security-scoped or may go away, so each file is copied to `tmp/lp-files/<uuid>/<name>` with `startAccessingSecurityScopedResource` around a coordinated read (`NSFileCoordinator`, so a file still in iCloud comes down first), off the main actor, and those URLs go to `state.addFiles`. A file that can't be copied is reported by name with the ones the loader refuses, never passed on. While files or photos are coming in the print bar says "Adding files…" and Add files is disabled. The folder is emptied at launch.
- `IOSPrinterSystem.swift`, `IOSAirPrintPrinter.swift`, `IOSFileActions.swift`, `IOSTroubleshooterService.swift` (`addSystemStatus` fills the network; a refusal of Local Network is the snapshot's `discovery` (`.denied`, from `NWBrowserPrinters`); `openAppSettings` opens the app's page in Settings; `openPrinterSettings` and `openNetworkSettings` open Settings too, since iOS has no deep link for them), `IOSLocalNetworkProbe.swift`, `UIKitLifecycle.swift`, `UIKitBackgroundActivity.swift`: Lazy Scan's with the names changed.
- `Views/`:
  - `IOSRootView`: the Print screen, with no tab bar; Jobs is a panel that slides in from the left, opened by the button at the top left of Print and by Jobs on the "Sent" bar, closed by its Close, a tap beside it or a drag to the left. The printer in use is a button at the top of Print with its state dot and one-line problem, opening `PrintersScreen`. The error bar and the "Sent" bar sit at the bottom (a `safeAreaInset` of Print). The root also presents the sheets that hang off the state (the printers, the troubleshooter, `DuplexSheet`), the share sheet and Quick Look that `IOSFileActions` asks for, and the files that come in: `.onOpenURL` (a file URL goes through `IOSFileInbox`, `lazyprint:open?handoff=<uuid>` adds the files Lazy Scan left, any other `lazyprint:` URL does nothing), the Add files menu (`FileSources`) and `-openFixture`. It calls `state.setActive(true)` while the scene is active, and `state.refreshNetwork()` on `UIApplication.willEnterForegroundNotification` (the scene goes background, inactive, active on its way back, so a change of the phase cannot tell a return from the background). A job's certificate question closes what cannot show an alert (the share sheet, Quick Look, the Files and Photos choice, the root's troubleshooter); the printers and the card stay open, since they show the alert themselves. Open In removes the delivered file only when the inbox copied it, and a hand-off's folder is removed only when every file in it was copied, so a hand-off with a failed copy can be tried again.
  - `FileSources`: the modifier that holds the Files importer (`.fileImporter`, `[.pdf, .image]`, several at once) and the Photos picker (`PhotosPicker`, which needs no permission; items are written to `IOSFileInbox` as their file data, named `Photo 1.heic` by their type, `PhotoNames`; photos that can't be downloaded or written are reported together, by name, as ones that can't be read). A task that `opensFiles`, picked with no documents, opens Files; the tasks for photos open Photos. Add files is a menu of Files and Photos, and Lazy Scan while `availability(of: .scanAndPrint)` allows it (`AddFilesMenu`; it starts Scan and print, and the scan comes back by the hand-off), on the Print screen, the document line and the documents sheet; it sets the source at once, with no dialog in between.
  - `PrintScreen`: a Task menu in the toolbar (`TaskCatalog.tasks(for: .ios)`, a section per group, the current task checked, an unavailable one disabled with its reason under the title) and Leave the task once one is picked, with the Jobs button at the top left; the preview, which on a two-sided job is two decks (`PageDecksView`: `UIPageViewController`'s curl with the spine in the middle, the sheets to come front up on the right and the turned ones back up on the left, so a sheet turned over shows both sides; a pinch outward on a page opens that page alone) and otherwise, or once opened, one page (`PageFoldView`: every side in turn, front then back, as paper that a drag folds flat along a line under the finger, drawn with layers since `UIPageViewController`'s curl takes only one page with the spine at the edge and so has no back; the flap is the sheet's other side as printed (plain paper on a one-sided sheet), mirrored across the sheet and reflected over the fold, and the next side is under it; let go and it turns or falls back, and the arrows turn it the same way; a pinch zooms it up to four times in a scroll view that pans only while zoomed, a double tap zooms in or out, and on a two-sided job a pinch inward at full size goes back to the decks; it takes each side from `AppState.previewImage(ofSide:)` and draws the sides next to the current one ahead) with "Page 3 · Sheet 2", the side when the sheet has two ("Pages 2–3 · Sheets 1–2" across the decks), under it, and previous and next as round buttons on the page's edges that fade to a quarter a few seconds after the page was last touched (`PreviewPosition` turns `previewSide` into a sheet and side and names the pages on it); `DocumentBar` under that, one line with the count, Edit and the plus (`DocumentsSheet` with `DocumentRow` reorders and removes, with the plus in its bar since a menu in a list row in edit mode doesn't open). The Add files menu shows a plus alone, with "Add files…" as its spoken label; "Options" opens `OptionsSheet` (a grouped `Form` with the inspector's sections, `.presentationDetents([.medium, .large])`, where Layout has a Margins switch, on for shrink to fit and off for actual size, and a Scale stepper beside it in place of the Mac's scaling list; the summaries `InspectorSections` makes are on that Options row, since a form has no collapsed headers); the Options row sits in the bar fixed at the bottom, directly above the Print button (`.borderedProminent`, with the label the Mac's has; nothing is written under it, and why it is greyed out is in its spoken label). The printer button at the top draws `PrinterLabel` as the list does, with "Demo (no hardware)" under the name when the printer is the demo one. With no documents it shows the empty state with Add files. In landscape (compact height) and on an iPad the page is on the left, in three fifths of the width, and the rest scrolls on the right; in portrait the page takes the height the rest leaves, and the screen scrolls only when large text fills it. Options, the printer button and the other controls that open a sheet are disabled while a job runs, and the sheets close when the two-sided card or a certificate question is to be shown.
  - `PrintersScreen`: the printers with state dot, problem and supply bars (`PrinterLabel`, `SupplyBars`); the row picks the printer and closes, the info button opens `PrinterScreen`; demo printer last; "Choose an AirPrint printer…" (the picker is presented from the front view controller, else on its own; if the system refuses both, a sentence under the row says so); Add by address (pushed); Troubleshoot (a sheet). When Local Network is refused a row says so and opens the app's settings. `PrinterScreen` has the name, state, model, address, problems, supplies, Print a test page, the demo printer's two switches, and for the printer in use whether the two-sided check was done. It has no "reset the two-sided check" and no "Forget": `AppState` and `NetworkPrinters` have no calls for either (the Mac and Windows have none), and adding them would be a shared change.
  - `JobsScreen`: the records, Cancel while running, Print again, Show for the demo printer's PNGs (`IOSFileActions.share`). Show, like Add files on the Print screen, waits while a job prints, so no sheet opens over it.
  - `DuplexSheet`: the card as a sheet with `.interactiveDismissDisabled()` and its own certificate alert; the text and the picture from `state`, as on the Mac. Its Cancel stops a running pass, as the Mac's does, and an error alert on it can open the troubleshooter. Its filled buttons are tinted `PrintFill`.
  - `TroubleshooterScreen` (a sheet with its own stack; Add by address is pushed on it), `AddPrinterScreen`, `CertificateAlert`, `ErrorAlert` (an alert for the screens that cover the error bar, the printers and the two-sided card: it shows an error that arrives while it is on screen, OK clears it, Troubleshoot opens the troubleshooter; the bar stays the way errors show elsewhere). `AddPrinterText` holds the sentence for a name the system would refuse over plain `ipp://`: a bare name goes straight to `ipps://`, and the screen says it before trying only where there is no ipps to try (a port or a path was typed); a -1022 reads the same. After an address does not answer, a refusal of Local Network access (`discovery` `.denied`, or `IOSLocalNetworkProbe`) is named, with a button for Settings.
  - `TaskSymbols` is shared with the Mac only in idea: the same `iconKey` map, copied (a third target for one switch is not worth it).

### Background

`AppState`'s init gains `background: (any BackgroundActivity)? = nil` (`App/PlatformLifecycle.swift`, Lazy Scan's protocol: `beginActivity(_ name: String, expired: @escaping @MainActor () -> Void) -> Int?`, `endActivity(_:)`; the default does nothing). A pass runs inside one activity. When the time runs out the job is stopped as Cancel stops it and the record is canceled and the error bar, titled "Printing stopped", says "Lazy Print ran out of time in the background. Print again to finish." (`PrintText.backgroundExpired`, C# twin included so the words stay in one place; the backs of a two-sided job, which the card still holds, say "Print the backs again to finish.", `PrintText.backgroundExpiredBacks`; a pass of the card's one-sheet check, while Print and Print again wait for the card, says "Print the check sheet again from the card.", `PrintText.backgroundExpiredCheck`.) The app starts the network search again when it comes back from the background. A two-sided card waiting for the user holds no activity.

### Info.plist and the project

`ios/project.yml` is Lazy Scan's with the names changed: targets `LazyPrintiOS` and `LazyPrintiOSUITests`, product `LazyPrintIOS` from the package, `PRODUCT_NAME` LazyPrint, display name "Lazy Print", bundle ids `com.lazyprint.lazyprint` and `.uitests`, the same `SUPPORTS_*` lines. `ios/LazyPrintiOS/main.swift` only starts `LazyPrintIOSApp`. `Assets.xcassets` holds `AppIcon` (the PNG `scripts/make_ios_icon.py` draws), `AccentColor` (the lighter blue in dark mode, since it is used as text and symbols on dark rows) and `PrintFill` (the accent in light mode, #2A74B8 in dark), which the views use through `Color("PrintFill")` for fills that carry white text (the Print button, the card's prominent buttons, the "Current" badge). The views live in a package, but the catalog is the app's, and a name with no bundle is looked up in the main bundle.

Info.plist keys:
- `NSBonjourServices`: `_ipp._tcp`, `_ipps._tcp`, `_lazyprint._tcp`. `NSLocalNetworkUsageDescription`: "Lazy Print looks for printers and for your computer on your local network, so you can print to them and send files." (the Mac's sentence names printers only, and the phone also connects to the computer). `NSCameraUsageDescription`: "Lazy Print reads the pairing code on your computer's screen."
- `NSAppTransportSecurity`: `NSAllowsLocalNetworking` only. Addresses and `.local` names are covered; unlike the Mac there is no `NSAllowsArbitraryLoads`, which App Review asks to have justified. A printer added by a dotted name over plain `ipp://` is refused by the system, so `AddPrinterScreen` says "Use the printer's IP address or its .local name." and a -1022 from the session reads the same.
- `CFBundleDocumentTypes`: `com.adobe.pdf` and `public.image`, role Viewer, `LSHandlerRank` Alternate, which is what puts Lazy Print in the share sheet. No share extension: it needs a provisioned team for little gain. The App Group `group.com.alazy.handoff` is only for a file from Lazy Scan on the phone (see "Hand-off").
- `LSSupportsOpeningDocumentsInPlace` false: Open In copies, so the inbox rule above covers it.
- `CFBundleURLTypes`: `lazyprint`. `LSApplicationQueriesSchemes`: `lazyscan`, for `lazyScanInstalled()`.
- `ITSAppUsesNonExemptEncryption` false. `PrivacyInfo.xcprivacy` is Lazy Scan's, with only the reasons this app uses.

### The Mac App Store build

`mac/project.yml` (XcodeGen, the iPhone project's twin) writes `mac/LazyPrintMacApp.xcodeproj` with one target, `LazyPrintMacApp`: product `LazyPrintMac` from the package (a library product for this), `PRODUCT_NAME` "Lazy Print" (so the bundle is `Lazy Print.app`, as `make_app.sh` makes, and the menus say Lazy Print), bundle id `com.lazyprint.lazyprint` (the iPhone's record), macOS 14, hardened runtime, sandbox. `mac/LazyPrintMacApp/main.swift` only starts `LazyPrintApp`. `scripts/make_app.sh` is unchanged: unsandboxed, id `local.lazyprint.app`, for development and the direct download.

Entitlements, and nothing else: `com.apple.security.app-sandbox`; `network.client` (printers by address, the phone sheet's checks); `network.server` (the phone link's listener); `print` (CUPS jobs); `files.user-selected.read-write` (open panel, drops and Open With files, and the cloud folder, which phones write into and the Mac deletes from); `files.bookmarks.app-scope` (the cloud folder's bookmark, kept across launches). No temporary exceptions.

Info.plist: everything `make_app.sh` writes, plus `ITSAppUsesNonExemptEncryption` false, `LSApplicationCategoryType` productivity and `NSHumanReadableCopyright`. `NSDocumentsFolderUsageDescription` is gone: the demo printer writes to the container's Documents. `NSAllowsArbitraryLoads` stays: `NSAllowsLocalNetworking` covers IP addresses, unqualified names and `.local`, not a printer typed in by a dotted name (`printer.lan`) over plain `ipp://`, which `AddPrinterView` accepts. `PrivacyInfo.xcprivacy` declares UserDefaults (CA92.1), file timestamps (C617.1 for the container, 3B52.1 for files the user picked) and the boot time (35F9.1, `ProcessInfo.systemUptime`).

Sandbox rules in the code:
- The cloud folder is a security-scoped bookmark (`MacSyncFolder`, as the iPhone's `IOSBookmarkedFolder`), kept in companion-devices.json as `syncFolderBookmark` beside the path (shown to the user). A file with a path and no bookmark loads; the folder is then read as a path, and works unsandboxed. When the bookmark does not resolve, the saved path is watched meanwhile (it works unsandboxed), `onSyncFolderProblem` says "The cloud folder could not be opened. Choose it again in the phone window.", and the service tries the bookmark again every `syncFolderRetryInterval` (5 s) until it opens, then clears the problem (`onSyncFolderProblem(nil)`) and restarts the watcher. The panel starts in the user's real home (`getpwuid`), since `homeDirectoryForCurrentUser` is the container.
- A `lazyprint:open?file=` address names a path the sandbox does not grant. `ContentView` opens the files it can read and tells the user plainly about the others ("Not added", with the way round it), in the same bar as any file that fails to open (`AppState.addFiles(_:alsoNotAdded:)`), after the files are added. Files the system opens for the app (Open With, the Dock, `open`) arrive as file URLs and are granted.
- Settings, the inbox, logs and the demo printer's pictures live in the container. No released Mac build exists, so nothing is moved. printers.txt is in the container's Library/Logs.
- A queue change the print system refuses (an admin request) says so and opens Printers & Scanners. Printing itself goes through `cupsPrintFile2` (the `print` entitlement) and the IPP path through URLSession (`network.client`).

`.github/workflows/ci.yml` gains the job `mac-store` (`needs: macos`, macos-26 and Xcode 26.6, as the upload uses, XcodeGen 2.46.0 by the same SHA-256, an ad-hoc signed Release build, then checks of the plists, all five entitlements by name, that `get-task-allow` is absent, the hardened runtime, the bundle id and the bundle name; `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` keeps the debugging entitlement out of the ad-hoc build). `.github/workflows/macappstore.yml` is `testflight.yml` for the Mac, run by hand: ad-hoc signed archive (with the same flag), export with `app-store-connect` and `upload`, automatic signing through the API key, which makes the installer package. Confirmed only by CI: the build. Not confirmed anywhere: the sandboxed app's behaviour on a Mac, and the cloud-managed export.

### Tests

`Tests/LazyPrintIOSTests` (run in the `LazyPrint-Package` scheme on the simulator): `IOSPrinterSystemTests` (the region's paper, the saved URL round trip, no saved printer means no queue), `IOSFileInboxTests` (copies keep names, two files of one name stay apart, a file that can't be copied is reported by name, the folder is emptied), `IOSFileActionsTests`, `OneShotTests`, `IOSTroubleshooterServiceTests`, `UIKitLifecycleTests`, `UIKitBackgroundActivityTests`, `IOSLaunchOptionsTests` (with the state `makeForIOS` makes for `-demoPrinter`), `PreviewPositionTests`, `SupplyColorTests`, `AddPrinterTextTests` and `PhotoNamesTests` (the pure parts of the views), and `IOSAirPrintPrinterTests` with `XCTSkipUnless(UIPrintInteractionController.isPrintingAvailable)` around what needs a printer. A skip that has to pass by accident is a failure: pure parts (paper choice, duplex and output type from the job) are functions and tested without a printer.

`ios/LazyPrintiOSUITests`, on `-demoPrinter` with `Fixtures/report.pdf` (four Letter pages, drawn by `scripts/make_ios_ui_fixture.py`) opened through `-openFixture`: `PrintFlowTests` (a task, a fixture document, the preview says the right sheet count, Print, Jobs shows Sent), `TwoSidedTests` (the demo printer without duplex: the card appears, Print the backs ends it, a swipe does not dismiss it), `PrintersTests` (the screen, the demo's switches reach the troubleshooter), `ScreenshotTests` (print, options, printers, the printer's page, jobs, two-sided, troubleshooter, add printer, the print screen in landscape and in large text, in light and dark (`-darkAppearance`, which the launch options read and the root view applies), a run each; a missing button leaves the screen out with a `skipped-` shot, as Lazy Scan's). `PrintFlowTests` also looks at large text and landscape: the preview, Options and Print must be reachable.

### CI

`.github/workflows/ci.yml` gains the job `ios`, Lazy Scan's with the names changed and the corner model step left out: `needs: macos`, `macos-26`, Xcode 26.6, the simulator pick, `xcodebuild test -scheme LazyPrint-Package` on the simulator, XcodeGen 2.46.0 by the same pinned SHA-256, `build-for-testing` and `test-without-building` for the app, the export of attachments to the artifact `ios-screenshots`, the result bundles on failure. A second leg, `ios-ipad`, runs the app's UI and screenshot tests on an iPad Pro 13-inch simulator (the package tests run on the iPhone leg only) and exports to `ios-screenshots-ipad`. Confirmed only by CI: everything here. Nothing about the Simulator can show Local Network prompts, AirPrint or a real printer, so those stay unverified until the app runs on a phone.

## The phone link (Companion/, both platforms)

Lazy Scan's phone link (its CONTRACTS.md, the companion section), so a phone can send files to the computer to print. The desktop is the server and the phone the client, over HTTP/1.1 on TLS, the phone pinning the desktop's self-signed certificate by SPKI SHA-256 from the pairing code. The two apps do not share pairings, ports or files: both can run on one computer and a Lazy Scan code is refused here, as any other text.

Ported with the names changed and the logic and tests kept, C# in `windows/LazyPrint.Core/Companion`, Swift in `Sources/LazyPrintKit/Companion`, each file naming its twin: `SpkiFingerprint`, `PairingUri`, `PairingSession`, `PairedDeviceStore`, `CompanionHttp`, `CompanionRateLimiter`, `CompanionServer`, `CompanionHost`, `CompanionNetworks`, `CompanionRouter`, `CompanionService`, `CompanionInbox`, `SyncPackage`, `SyncFolderWatcher`, `CompanionTroubleshooter` (reworded for printing), and on the Swift side `SelfSignedCertificate`. Windows also takes `CompanionCertificateStore`, `WindowsNetworkSource`, `WindowsDnsSdAdvertiser`, `FirewallReader`, `CompanionFirewall`; the phone takes `CompanionClient`, `PairedDesktop`, `PairedDesktopStore`, `PhoneOutbox`. Lazy Scan's `AppState+Companion` and `AppState+CompanionHost` keep their shape, cut down to what follows; its `CompanionPackage`, `CompanionOutbox` and `CompanionPages` have no port, `PrintPackage` takes their place.

Renames: `ServiceType` `_lazyprint._tcp`, `ServiceName` `lazyprint`, default port 52732, `lazyprint://pair?`, sync files `.lpsync` with the magic `LPSYNC01`, `%LOCALAPPDATA%\Lazy Print\Companion\Inbox`, `%APPDATA%\Lazy Print\companion-devices.json` and `companion-networks.json` (Application Support on the Mac), the mutex `Local\LazyPrint.PhoneLink`, the certificate "Lazy Print phone link" with `CN=<machine> Lazy Print`, the Keychain service `com.lazyprint.companion`.

Left out because nothing sends that way: the desktop-to-phone outbox and its routes (`GET /v1/outbox`, `GET` and `DELETE /v1/outbox/{id}`), which Lazy Scan's app never fills; `X-Target`; `HelloResponse.QueuedPages`. Routes: `GET /v1/health`, `POST /v1/pair`, `GET /v1/hello`, `PUT /v1/inbox/{packageId}`, `DELETE /v1/devices/self`. `CompanionProtocol.Version` is 1.

### The print package

One file for the computer to print. Lazy Scan's `.lsdoc` is a zip of pages with OCR and capture facts, none of which applies, and Foundation has no zip, so this is a header and the file:

```
offset 0   8 bytes  "LPPKG01\0"
offset 8   4 bytes  header length, unsigned little endian, 1 ... 65536
offset 12  n bytes  header: UTF-8 JSON, keys in this order
                    {"name":"Report.pdf","contentType":"application/pdf","batch":"<id>","index":0,"count":3,"from":"Aytu's iPhone"}
then                the file's bytes, to the end
```

Twin `PrintPackage` (`Make(name, contentType, batch, index, count, from, bytes)`, `Read(stream or file)`), read leniently as Lazy Scan reads JSON: unknown keys ignored. A golden file `Tests/Fixtures/Companion/print-package.lppkg` is written by C# and checked by Swift. `contentType` is one of `application/pdf`, `image/jpeg`, `image/png`, `image/heic`, `image/tiff`. `Read` refuses a package whose magic or header is wrong, whose `name` has a path separator or is longer than 255 UTF-8 bytes, or whose first bytes do not match `contentType` (`%PDF-`, `FF D8 FF`, `89 50 4E 47`, `ftyp` at 4, `II*\0` or `MM\0*`): the desktop opens what arrives, so it decides by the bytes, not the sender's word. A batch is the files sent together: `index` from 0, `count` the same on each. `MaxPackageBytes` is 512 MiB plus the header.

`PUT /v1/inbox/{packageId}` takes it as `application/vnd.lazyprint.package`, idempotent by id, written to `<id>.part` and renamed once `PrintPackage.Read` accepts it (201, or 200 with `duplicate:true`), as `CompanionInbox.ReceiveAsync`. The sync fallback seals the same bytes as `<packageId>.lpsync`. A phone may have 100 files and 2 GiB waiting (`MaxWaitingFiles`, `MaxWaitingBytes`): past that `ReceiveAsync` refuses before it reads the body, and the router answers 409 `inboxFull`, which the phone treats as any refusal that is not about the file (it keeps the file). The inbox keeps a file 7 days after it arrives. `CompanionInbox.Take(batch, now)` moves a batch's files to `Inbox/<batch>/<name>` and returns them in `index` order, stamped `now`, so a taken file is kept 7 days from then; a file that cannot be moved stays in the inbox and the others are still taken. The name is the sender's word, so it is made safe: characters Windows does not allow become `_`, trailing dots and spaces go, a Windows device name (`NUL`, `CON`, `PRN`, `AUX`, `COM0`-`COM9`, `LPT0`-`LPT9`, `CONIN$`, `CONOUT$`, with any extension) gets `_` in front, the extension is the one `contentType` says (`.pdf`, `.jpg`/`.jpeg`, `.png`, `.heic`/`.heif`, `.tif`/`.tiff`) and is appended when the name has another, and the stem is cut so the name is at most 240 UTF-8 bytes (room for ` (2)`). `CompanionInbox.Discard(batch)` deletes a batch without copying it. The `from` of a batch is the name the phone paired as (`CompanionInbox.NameOf`), or its own word cleaned as `CleanName` when unknown. Forgetting a phone, its own `DELETE /v1/devices/self` and Reset pairing delete what it sent that still waits. A refused request's unread body (up to 1 MiB) is dropped before the connection closes, for at most 5 s in all. The server takes 8 connections, Lazy Scan's limit, and at most 4 from one address (`MaxConnectionsPerPeer`, as in Lazy Scan; an IPv4-mapped address counts as its IPv4 address), so a peer on the same network that keeps reconnecting leaves room for the phones. A peer that uses two or more addresses can still hold all 8, and what the phones send then waits in their outboxes. A batch counts as whole when all `count` packages are in, or 30 s after the last one arrived, so a phone that lost the link does not hold back what got through.

### The computer

`CompanionService` runs only while a phone is paired or a code is shown, on trusted networks only, as Lazy Scan's.

Windows, `AppViewModel.Companion.cs` and `MainWindow.Phone.cs`:
- The Phone button sits by the printers (the task From your phone opens the same window). `PhoneWindow` is Lazy Scan's: the QR (`ZXingQrEncoder` behind `IQrEncoder`, ZXing.Net in the App project only, black on white, four-module quiet zone), the check code, the paired phones with Forget, Reset pairing, the trusted networks, the troubleshooter.
- Pairing asks first, as `ApprovePairing`: 120 s, default decline (a code is only shown where someone can answer). The router checks that a pairing session is open before it reads the body of `POST /v1/pair`.
- A whole batch brings up the "From your phone" bar: "3 files from Aytu's iPhone", Add to this job, Start a new job, Dismiss. Nothing prints by itself. The taskbar flashes when the window is in the background. Add puts them in the job and goes to Print; New clears the job (the documents and the page range) once at least one of the files has opened, and when none does the job stays as it was and the error bar names the files that failed; Dismiss deletes them (`Discard`). Taking copies the files off the UI thread, and a second click while one runs does nothing. Several batches queue behind the bar, one at a time. A batch that has been offered stays offered, in its place in the queue, when more of its files arrive later (a phone that lost the link and found it again), so the bar neither goes away for another 30 s nor gives way to a newer batch; its words then change ("2 files" to "3 files"). The bar is announced for each batch by its id and its words, so two batches that read the same are both announced.
- A problem with the cloud folder (a file in it that could not be read) is kept for the Phone window (`SyncFolderProblem`) and put in the main window's error bar as a notice titled "Phone sync" (`ReportSyncProblem`), unless a failure is showing there; another notice is replaced, and the "sent" message stays. The notice leaves when the folder is chosen again.

Mac: Lazy Scan's `App/CompanionCertificateStore`, `App/MacCompanionSyncKeys`, `UI/PhoneView` and `UI/PhoneBarView` with the names changed: the same as Windows, a sheet instead of a window, the QR from `CIQRCodeGenerator`, the bar in `ContentView`, the certificate in the Keychain. `AppState` gains `phoneBatches` (the whole batches, and partial ones already offered, in the order offered), `takeBatch(_:startNew:)` (the files into the job, or into a new one, cleared first once a file has opened; the settings are left as they are, with or without a task), `reportSyncProblem(_:)` (the Windows `ReportSyncProblem`; nil takes the notice away; `ContentView` calls it when `MacCompanionHosting.syncFolderProblem` changes) and `dismissBatch(_:)` (the files deleted) behind a `CompanionHosting` protocol with a no-op default (see "App state"), which the Mac shell fills with the `CompanionService` it builds from its own certificate store, interfaces and DNS-SD. The Kit stays free of the server's platform pieces. A batch that is not whole is listed when 30 s have passed since its last file.

### The phone

`Sources/LazyPrintIOS/Companion`: `IOSCompanionBrowser`, `IOSCompanionModel`, `IOSCompanionSecrets`, `IOSSyncFolder`, `PairingScannerView` (AVFoundation; `NSCameraUsageDescription` "Lazy Print reads the pairing code on your computer's screen."), `Views/CompanionScreen`. `PrintersScreen` gains the section My computer (pair, the paired computer's state, Forget, which asks first in a dialog titled with the computer's name). `PrintScreen` gains "Send to <computer>" beside Print once a computer is paired, sending the files of the job's documents as one batch through `PhoneOutbox`, which retries and falls back to the sync folder as Lazy Scan's. Every document is a file the user gave and goes as it is; a file that is not a PDF, JPEG, PNG, HEIC or TIFF (a GIF, a BMP) is left out, not converted, and the others are sent. The error bar, said after the files went, names what was left out ("Scan.gif cannot be sent: only PDF, JPEG, PNG, HEIC and TIFF files can."; three names, then "and 2 more") next to the "sent" message, and the left-out file stays in the job. Where the sending said something too (the computer cannot be reached, a file refused), that comes first on the line above. A job with nothing the link carries sends nothing and says the same. When files wait because the computer cannot be reached, a notice says so, or the error bar above when a file was left out. In `AppState`: `setUpCompanion(in:secrets:)`, `pairDesktop(uri:phoneName:)`, `unpairDesktop()`, `checkDesktop()`, `sendJobToDesktop(from:)` (the phone's name goes in each package's `from`), `drainOutbox()`, the sync folder calls of Lazy Scan, and `CompanionText` for the words. `From your phone` stays off the iPhone's task list.

Tests: the Lazy Scan tests with the same renames, `CompanionLoopbackTests` through a whole send, `PrintPackageTests` in both languages (the golden file, each refusal, the sniffing table), `CompanionInboxTests` for batches.

## Hand-off

The two apps open each other by URL scheme, so neither names the other's folder or install path. Nothing here is automatic: a hand-off opens the other app with something ready, and the user prints or scans there.

Lazy Print opens Lazy Scan: the task Scan and print calls `lazyscan:` (`FileActionService.openLazyScan`). Lazy Print sends nothing; the scan comes back through the other direction. The task is greyed with "Needs Lazy Scan" when `lazyScanInstalled()` is false (Windows: the scheme's key exists in `HKCR`, or `Launcher.QueryUriSupportAsync` finds a handler, for a Store-installed Lazy Scan; Mac: `NSWorkspace.urlForApplication(toOpen:)`; iPhone: `canOpenURL`).

Lazy Scan opens Lazy Print: "Print with Lazy Print" beside its Print commands writes the scan to a PDF in its temp folder and calls:

```
lazyprint:open?file=<percent-encoded full path>&file=<...>
```

`LazyPrintUrl.Parse` (Core, twins, `LazyPrintUrlTests`): scheme `lazyprint`, path `open` or empty, repeated `file`, unknown parameters ignored. It only ever adds files to the job. Windows refuses a path that is not a rooted local drive path: a UNC or device path (`\\server\share`, `\\?\`) is dropped, because the URL can come from a web page and reading a share would send the user's credentials there. The Mac refuses anything but an absolute path. A file that isn't a PDF or picture is refused by the loader as usual.

Windows registers the scheme under `HKCU\Software\Classes\lazyprint` at each start, pointing at the running exe, as Lazy Scan's `FileAssociation` (the Store package declares it in its manifest instead and the app writes nothing, see "The Store package"); `App.OnStartup` treats an argument starting `lazyprint:` as a URL (when the first argument is one, it is the only one read: the command is `"exe" "%1"`, so an address with a quote in it could add arguments, such as a UNC path), and `InstanceChannel` passes the files on to a running instance. The Mac app declares it in `CFBundleURLTypes` (done) and `.onOpenURL` adds the files. The iPhone cannot hand a path across sandboxes, so Lazy Scan copies the scan to `Handoff/<uuid>/<name>` in the App Group `group.com.alazy.handoff` (in both apps' entitlements; `testflight.yml` signs the unsigned archive ad hoc with `ios/LazyPrintiOS/LazyPrint.entitlements` so the export keeps it) and opens `lazyprint:open?handoff=<uuid>`. `LazyPrintUrl.parseHandoff` takes the value only if it is a UUID, since it becomes a folder name; `parse` gives no files for that address. `IOSRootView` copies the files into `IOSFileInbox` as Open In files are and removes the hand-off folder when every file copied; when one did not, the folder is left for the day-old cleanup below, and the files that did copy are in the job. With no folder, or none in it, the error bar says "Not added" and names Lazy Scan. At launch `IOSFileInbox.removeOldHandoffs` removes hand-off folders over a day old. Lazy Scan's share sheet also lists Lazy Print through its document types.

In the LazyScan repository, on its own branch and in its own commits: the `lazyscan:` scheme where it is missing, and "Print with Lazy Print" (shown only when `lazyprint:` is registered) on Windows and the Mac, with its tests. Its working tree may hold someone's unfinished work: use a separate worktree from its `HEAD`, never touch those files, and do not merge.

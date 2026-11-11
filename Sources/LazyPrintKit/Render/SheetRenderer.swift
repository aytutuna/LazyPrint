import CoreGraphics
import CoreText
import Foundation
import ImageIO

// Twin of windows/LazyPrint.App/Printing/SheetRenderer.cs: draws a SheetSide the way every platform does.
// Layout coordinates are points, top-left; the context is flipped once in `draw`.

/// What SheetSide leaves out: the items of a test page, the blank-back dot and a half turn.
public struct RenderedSide: Equatable, Sendable {
    public var side: SheetSide
    public var items: [TestPageItem]
    public var marked: Bool
    public var turned: Bool

    public init(side: SheetSide, items: [TestPageItem] = [], marked: Bool = false, turned: Bool = false) {
        self.side = side
        self.items = items
        self.marked = marked
        self.turned = turned
    }
}

/// One side as pixels, 8-bit gray or RGB, row 0 at the top. The context is released with the value.
public struct SheetBitmap: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerPixel: Int
    private let context: CGContext

    fileprivate init(context: CGContext, bytesPerPixel: Int) {
        self.context = context
        self.width = context.width
        self.height = context.height
        self.bytesPerPixel = bytesPerPixel
    }

    /// One line, `width * bytesPerPixel` bytes (R, G, B for color, the context's pad byte dropped).
    public func row(_ y: Int) -> [UInt8] {
        guard y >= 0, y < height, let base = context.data else { return [] }
        let line = base.advanced(by: y * context.bytesPerRow).assumingMemoryBound(to: UInt8.self)
        if bytesPerPixel == 1 { return Array(UnsafeBufferPointer(start: line, count: width)) }
        var out = [UInt8](repeating: 0, count: width * 3)
        for x in 0..<width {
            out[x * 3] = line[x * 4]
            out[x * 3 + 1] = line[x * 4 + 1]
            out[x * 3 + 2] = line[x * 4 + 2]
        }
        return out
    }

    public func image() -> CGImage? { context.makeImage() }
}

public struct SheetRenderer {
    private static let borderWidth = 0.5
    private static let markRadius = 0.5
    private static let markInset = 8.0
    private static let cannotDraw = PrintError.unreadable("Lazy Print can't draw this page.")

    private let documents: [OpenedDocument]

    public init(documents: [OpenedDocument]) {
        self.documents = documents
    }

    /// Draws one side into a context whose user space is the paper in points, bottom-left as CoreGraphics has it.
    /// Pictures are decoded at no more than `imageDpi` and never enlarged. No white fill: the paper is white.
    public func draw(_ side: RenderedSide, area: PrintableArea, imageDpi: Double = 300, in context: CGContext) {
        context.saveGState()
        context.translateBy(x: 0, y: area.paper.height)
        context.scaleBy(x: 1, y: -1)
        for placement in side.side.placements {
            drawPlacement(placement, area: area, imageDpi: imageDpi, in: context)
        }
        drawMarks(side, area: area, in: context)
        context.restoreGState()
    }

    /// A PDF with one page per side, each page the paper's size in points, written to `url` as it is drawn. `onPage` is
    /// told how many pages are written, after each.
    public func writePDF(_ sides: [RenderedSide], area: PrintableArea, imageDpi: Double = 300, to url: URL,
                         onPage: (Int) -> Void = { _ in }) throws {
        var box = CGRect(x: 0, y: 0, width: area.paper.width, height: area.paper.height)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw Self.cannotDraw }
        for (i, side) in sides.enumerated() {
            try Task.checkCancellation()
            autoreleasepool {
                context.beginPDFPage(nil)
                draw(side, area: area, imageDpi: imageDpi, in: context)
                context.endPDFPage()
            }
            onPage(i + 1)
        }
        context.closePDF()
    }

    /// One side as pixels, white behind it, 8-bit gray or RGB.
    public func bitmap(_ side: RenderedSide, area: PrintableArea, dpi: Double, gray: Bool) throws -> SheetBitmap {
        let width = max(1, Int((area.paper.width * dpi / 72).rounded()))
        let height = max(1, Int((area.paper.height * dpi / 72).rounded()))
        let space = gray ? CGColorSpaceCreateDeviceGray() : (CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB())
        let info = gray ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: info) else { throw Self.cannotDraw }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: Double(width) / area.paper.width, y: Double(height) / area.paper.height)
        draw(side, area: area, imageDpi: dpi, in: context)
        return SheetBitmap(context: context, bytesPerPixel: gray ? 1 : 3)
    }

    // MARK: Placements

    private func drawPlacement(_ placement: Placement, area: PrintableArea, imageDpi: Double, in context: CGContext) {
        guard documents.indices.contains(placement.page.document) else { return }
        let document = documents[placement.page.document]
        let frame = placement.frame
        let sideways = placement.turns % 2 != 0
        // The page as it lies before turning: the frame's shape, turned back.
        let width = sideways ? frame.height : frame.width
        let height = sideways ? frame.width : frame.height
        guard width > 0, height > 0 else { return }

        document.drawing.locked {
            context.saveGState()
            context.clip(to: CGRect(area.printable))
            context.clip(to: CGRect(frame))
            context.translateBy(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            context.rotate(by: Double(placement.turns) * .pi / 2)
            // Images and PDF pages come out upside down in the flipped space; flip back here.
            context.scaleBy(x: 1, y: -1)
            context.clip(to: CGRect(x: -width / 2, y: -height / 2, width: width, height: height))
            context.interpolationQuality = .high
            switch document.source {
            case .pdf(let pdf):
                if let page = pdf.page(at: placement.page.index + 1) {
                    drawPDF(page, crop: placement.crop, width: width, height: height, in: context)
                }
            case .picture(let source):
                let index = placement.page.index
                if document.loaded.pages.indices.contains(index) {
                    drawPicture(source, index: index, size: document.loaded.pages[index], crop: placement.crop, width: width,
                                height: height, imageDpi: imageDpi, in: context)
                }
            }
            context.restoreGState()
        }
    }

    /// Built by hand: `getDrawingTransform` never scales up, and a page must fill its frame.
    private func drawPDF(_ page: CGPDFPage, crop: LayoutRect?, width: Double, height: Double, in context: CGContext) {
        let box = page.getBoxRect(.cropBox)
        let turn = ((Int(page.rotationAngle) % 360) + 360) % 360
        let sideways = turn == 90 || turn == 270
        let shownWidth = sideways ? box.height : box.width
        let shownHeight = sideways ? box.width : box.height

        // /Rotate is clockwise; each result is put back in the first quadrant.
        let rotation: CGAffineTransform
        switch turn {
        case 90: rotation = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: box.width)
        case 180: rotation = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: box.width, ty: box.height)
        case 270: rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: box.height, ty: 0)
        default: rotation = .identity
        }
        let shown = crop ?? LayoutRect(x: 0, y: 0, width: shownWidth, height: shownHeight)
        guard shown.width > 0, shown.height > 0 else { return }

        let transform = CGAffineTransform(translationX: -box.minX, y: -box.minY)
            .concatenating(rotation)
            .concatenating(CGAffineTransform(translationX: -shown.x, y: -(shownHeight - shown.y - shown.height)))
            .concatenating(CGAffineTransform(scaleX: width / shown.width, y: height / shown.height))
            .concatenating(CGAffineTransform(translationX: -width / 2, y: -height / 2))
        context.concatenate(transform)
        context.clip(to: box)
        context.drawPDFPage(page)
    }

    private func drawPicture(_ source: CGImageSource, index: Int, size: LayoutSize, crop: LayoutRect?, width: Double, height: Double,
                             imageDpi: Double, in context: CGContext) {
        let shown = crop ?? LayoutRect(x: 0, y: 0, width: size.width, height: size.height)
        guard shown.width > 0, shown.height > 0 else { return }
        let scaleX = width / shown.width, scaleY = height / shown.height
        // The whole page is decoded at the size it has on the sheet, so a crop is not soft.
        let longSide = max(size.width * scaleX, size.height * scaleY) * imageDpi / 72
        guard let image = Self.decode(source, index: index, longSide: longSide) else { return }
        context.draw(image, in: CGRect(x: -width / 2 - shown.x * scaleX, y: height / 2 + shown.y * scaleY - size.height * scaleY,
                                       width: size.width * scaleX, height: size.height * scaleY))
    }

    /// A frame, upright by its orientation tag, at most `longSide` pixels on the longer side and never larger than itself.
    private static func decode(_ source: CGImageSource, index: Int, longSide: Double) -> CGImage? {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let own = max((properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0,
                      (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0)
        let wanted = max(1, Int(longSide.rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: own > 0 ? min(wanted, own) : wanted,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    // MARK: Borders, items and the dot

    private func drawMarks(_ side: RenderedSide, area: PrintableArea, in context: CGContext) {
        let printable = area.printable
        context.saveGState()
        context.clip(to: CGRect(printable))
        if side.side.borders {
            context.setStrokeColor(Self.color(.gray(128)))
            context.setLineWidth(Self.borderWidth)
            for placement in side.side.placements {
                context.stroke(CGRect(placement.frame))
            }
        }
        // A turned side (the back of the two-sided check) is drawn half a turn about the middle of the paper.
        context.saveGState()
        if side.turned {
            context.translateBy(x: area.paper.width / 2, y: area.paper.height / 2)
            context.rotate(by: .pi)
            context.translateBy(x: -area.paper.width / 2, y: -area.paper.height / 2)
        }
        for item in side.items {
            drawItem(item, in: context)
        }
        context.restoreGState()
        if side.marked {
            context.setFillColor(Self.color(.gray(250)))
            let centre = CGPoint(x: printable.x + Self.markInset, y: printable.y + Self.markInset)
            context.fillEllipse(in: CGRect(x: centre.x - Self.markRadius, y: centre.y - Self.markRadius,
                                           width: Self.markRadius * 2, height: Self.markRadius * 2))
        }
        context.restoreGState()
    }

    private func drawItem(_ item: TestPageItem, in context: CGContext) {
        switch item {
        case .rect(let bounds, let fill):
            context.setFillColor(Self.color(fill))
            context.fill(CGRect(bounds))
        case .line(let from, let to, let width, let color):
            context.setStrokeColor(Self.color(color))
            context.setLineWidth(width)
            context.move(to: CGPoint(x: from.x, y: from.y))
            context.addLine(to: CGPoint(x: to.x, y: to.y))
            context.strokePath()
        case .text(let value, let at, let size, let bold):
            let font = CTFontCreateWithName((bold ? "Helvetica-Bold" : "Helvetica") as CFString, size, nil)
            let string = NSAttributedString(string: value, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            context.setFillColor(Self.color(.black))
            // `at` is the top of the line box and CTLineDraw draws on the baseline; the context is flipped, so the text is too.
            context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            context.textPosition = CGPoint(x: at.x, y: at.y + CTFontGetAscent(font))
            CTLineDraw(CTLineCreateWithAttributedString(string as CFAttributedString), context)
        case .arrow(let bounds, let up):
            context.setFillColor(Self.color(.black))
            context.addLines(between: Self.arrowShape(bounds, up: up))
            context.closePath()
            context.fillPath()
        }
    }

    private static func color(_ color: TestColor) -> CGColor {
        CGColor(srgbRed: Double(color.r) / 255, green: Double(color.g) / 255, blue: Double(color.b) / 255, alpha: 1)
    }

    /// A head over a stem, filling the bounds; pointing down when it is not `up`.
    private static func arrowShape(_ b: LayoutRect, up: Bool) -> [CGPoint] {
        let head = b.height * 0.45, stem = b.width * 0.4, centre = b.x + b.width / 2
        let points = [
            CGPoint(x: centre, y: b.y), CGPoint(x: b.x + b.width, y: b.y + head), CGPoint(x: centre + stem / 2, y: b.y + head),
            CGPoint(x: centre + stem / 2, y: b.y + b.height), CGPoint(x: centre - stem / 2, y: b.y + b.height),
            CGPoint(x: centre - stem / 2, y: b.y + head), CGPoint(x: b.x, y: b.y + head),
        ]
        return up ? points : points.map { CGPoint(x: $0.x, y: 2 * b.y + b.height - $0.y) }
    }
}

private extension CGRect {
    init(_ rect: LayoutRect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}

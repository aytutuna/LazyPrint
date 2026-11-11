#if os(macOS)
import CoreGraphics
import ImageIO
import LazyPrintKit
import PDFKit
import SwiftUI

/// The documents under the preview, in print order: a thumbnail of the first page, the name and the page count, and the
/// buttons that move or remove one. Add files opens the panel the caller owns. Twin of the Windows strip.
struct DocumentStrip: View {
    @EnvironmentObject var state: AppState
    var addFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    addFiles()
                } label: {
                    Label("Add files\u{2026}", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(state.isBusy)
                .help("Add PDFs, pictures and text")
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(state.documents.enumerated()), id: \.offset) { index, document in
                        card(index, document)
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }

    private var summary: String {
        let documents = state.documents.count
        let pages = state.pageCount
        return "\(documents) document\(documents == 1 ? "" : "s") \u{00B7} \(pages) page\(pages == 1 ? "" : "s")"
    }

    private func card(_ index: Int, _ document: OpenedDocument) -> some View {
        let pages = document.loaded.pages.count
        let count = "\(pages) page\(pages == 1 ? "" : "s")"
        return VStack(alignment: .leading, spacing: 4) {
            Thumbnail(document: document)
                .frame(width: 96, height: 96)
            Text(document.loaded.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(count)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Button { state.move(at: index, by: -1) } label: { Image(systemName: "chevron.left") }
                    .disabled(index == 0)
                    .help("Earlier")
                    .accessibilityLabel("Move \(document.loaded.name) earlier")
                Button { state.remove(at: index) } label: { Image(systemName: "trash") }
                    .help("Remove")
                    .accessibilityLabel("Remove \(document.loaded.name)")
                Button { state.move(at: index, by: 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(index == state.documents.count - 1)
                    .help("Later")
                    .accessibilityLabel("Move \(document.loaded.name) later")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(state.isBusy)
        }
        .padding(8)
        .frame(width: 112, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(document.loaded.name), \(count)")
    }
}

/// The first page of a document, drawn off the main actor when the card appears.
private struct Thumbnail: View {
    let document: OpenedDocument
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .shadow(color: .black.opacity(0.25), radius: 2)
            } else {
                Color.clear
            }
        }
        .task(id: document.url) {
            let opened = document
            image = await Task.detached { Self.make(opened) }.value
        }
        .accessibilityHidden(true)
    }

    private nonisolated static func make(_ document: OpenedDocument) -> CGImage? {
        let side = 192
        switch document.source {
        case .picture(let source):
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        case .pdf(let pdf):
            return document.drawing.locked { () -> CGImage? in
                guard let page = pdf.page(at: 1) else { return nil }
                let box = page.getBoxRect(.cropBox)
                let turned = page.rotationAngle % 180 != 0
                let shown = turned ? CGSize(width: box.height, height: box.width) : box.size
                guard shown.width > 0, shown.height > 0 else { return nil }
                let scale = CGFloat(side) / max(shown.width, shown.height)
                let width = max(1, Int((shown.width * scale).rounded()))
                let height = max(1, Int((shown.height * scale).rounded()))
                guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                      let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                              space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
                let target = CGRect(x: 0, y: 0, width: width, height: height)
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(target)
                if let annotated = document.annotatedPage(0) {
                    context.scaleBy(x: target.width / shown.width, y: target.height / shown.height)
                    annotated.draw(with: .cropBox, to: context)
                } else {
                    context.concatenate(page.getDrawingTransform(.cropBox, rect: target, rotate: 0, preserveAspectRatio: true))
                    context.drawPDFPage(page)
                }
                return context.makeImage()
            }
        }
    }
}
#endif

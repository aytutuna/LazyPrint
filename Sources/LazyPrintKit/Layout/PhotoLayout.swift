import Foundation

// Twin of windows/LazyPrint.Core/Layout/PhotoLayout.cs: the print sizes a photo can be printed at.

/// A print size.
public struct PhotoSize: Equatable, Sendable {
    /// "4x6", "5x7", "8x10", "3.5x5", "wallet", "10x15cm", "13x18cm" or "page".
    public var id: String
    /// What a picker shows: "4 × 6 in", "10 × 15 cm", "Whole page".
    public var title: String
    /// Portrait, in points; nil is as large as the cell allows.
    public var size: LayoutSize?

    public init(id: String, title: String, size: LayoutSize?) {
        self.id = id
        self.title = title
        self.size = size
    }

    private static func inches(_ width: Double, _ height: Double) -> LayoutSize {
        LayoutSize(width: width * 72, height: height * 72)
    }

    private static func centimetres(_ width: Double, _ height: Double) -> LayoutSize {
        LayoutSize(width: width * 72 / 2.54, height: height * 72 / 2.54)
    }

    public static let all: [PhotoSize] = [
        PhotoSize(id: "4x6", title: "4 \u{00D7} 6 in", size: inches(4, 6)),
        PhotoSize(id: "5x7", title: "5 \u{00D7} 7 in", size: inches(5, 7)),
        PhotoSize(id: "8x10", title: "8 \u{00D7} 10 in", size: inches(8, 10)),
        PhotoSize(id: "3.5x5", title: "3.5 \u{00D7} 5 in", size: inches(3.5, 5)),
        PhotoSize(id: "wallet", title: "Wallet, 2.5 \u{00D7} 3.5 in", size: inches(2.5, 3.5)),
        PhotoSize(id: "10x15cm", title: "10 \u{00D7} 15 cm", size: centimetres(10, 15)),
        PhotoSize(id: "13x18cm", title: "13 \u{00D7} 18 cm", size: centimetres(13, 18)),
        PhotoSize(id: "page", title: "Whole page", size: nil),
    ]
}

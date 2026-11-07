#if os(macOS)
/// SF Symbols for the task icons (`TaskDefinition.iconKey`); the Windows app maps the same keys to Segoe Fluent glyphs.
enum TaskSymbols {
    static func systemImage(_ iconKey: String) -> String {
        switch iconKey {
        case "document": return "doc"
        case "twoSided": return "arrow.left.arrow.right.square"
        case "booklet": return "book"
        case "handouts": return "square.grid.2x2"
        case "photos": return "photo"
        case "photoSheet": return "photo.on.rectangle"
        case "testPage": return "printer"
        case "scanAndPrint": return "scanner"
        case "fromPhone": return "iphone"
        default: return "doc"
        }
    }
}
#endif

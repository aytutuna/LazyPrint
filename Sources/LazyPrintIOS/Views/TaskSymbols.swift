#if os(iOS)
import Foundation

/// SF Symbols for the task icons (`TaskDefinition.iconKey`). The Mac app's map, copied: a third target for one switch is
/// not worth it.
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

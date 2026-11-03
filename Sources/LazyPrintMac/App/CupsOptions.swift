#if os(macOS)
import Foundation
import LazyPrintKit

/// The options of a job sent to a queue with cupsPrintFile2. Lazy Print has laid the sheets out already, so every option
/// that would make CUPS lay them out again is forced off, whatever the queue's defaults say. The older names
/// (`fit-to-page`, `scaling`) are for Apple's PDF filters, `print-scaling` for cups-filters.
enum CupsOptions {
    /// `copies` is what the queue makes (JobPlan.copiesInJob); `media` is the PWG or PPD name of the paper's closest size
    /// in the queue. `duplexPass` is a pass of a two-sided job done by hand: it prints one side whatever `sides` says.
    static func forJob(sides: Sides, copies: Int, collate: Bool, color: ColorChoice, quality: QualityChoice,
                       media: String?, duplexPass: Bool) -> [String: String] {
        var options = [
            "document-format": "application/pdf",
            "orientation-requested": "3",
            "print-scaling": "none",
            "fit-to-page": "false",
            "scaling": "100",
            "number-up": "1",
            "outputorder": "normal",
            "sides": duplexPass || sides == .oneSided ? "one-sided" : "two-sided-long-edge",
            "print-color-mode": color == .gray ? "monochrome" : "color",
            "print-quality": quality == .draft ? "3" : quality == .best ? "5" : "4",
        ]
        if copies > 1 {
            options["copies"] = String(copies)
            options["multiple-document-handling"] = collate
                ? "separate-documents-collated-copies" : "separate-documents-uncollated-copies"
        }
        if let media { options["media"] = media }
        return options
    }
}
#endif

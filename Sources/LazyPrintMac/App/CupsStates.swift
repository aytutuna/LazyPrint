#if os(macOS)
import Foundation
import LazyPrintKit

/// What a CUPS queue's printer-state, printer-state-reasons and printer-is-accepting-jobs mean as `SystemQueueState`s.
/// Pure, so the table is tested without a printer.
enum CupsStates {
    private static let suffixes = ["-error", "-warning", "-report"]

    static func describe(state: Int, reasons: [String], accepting: Bool) -> [SystemQueueState] {
        var states = [SystemQueueState]()
        func add(_ found: SystemQueueState) {
            if !states.contains(found) { states.append(found) }
        }

        if state == 5 || !accepting { add(.paused) }
        for reason in reasons {
            var base = reason
            if let suffix = suffixes.first(where: { reason.hasSuffix($0) }) { base = String(reason.dropLast(suffix.count)) }
            switch base {
            case "none":
                break
            case "paused":
                add(.paused)
            case "offline", "connecting-to-device":
                add(.offline)
            case "media-empty", "media-needed":
                add(.paperOut)
            case "media-jam":
                add(.paperJam)
            case "door-open", "cover-open":
                add(.doorOpen)
            case "toner-low", "marker-supply-low", "marker-waste-almost-full":
                add(.tonerLow)
            case "toner-empty", "marker-supply-empty":
                add(.noToner)
            default:
                if reason.hasSuffix("-error") { add(.error) }
            }
        }
        if state == 4 { add(.busy) }
        return states
    }
}
#endif

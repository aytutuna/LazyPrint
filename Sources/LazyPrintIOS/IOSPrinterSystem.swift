#if os(iOS)
import LazyPrintKit
import Foundation
import UIKit

/// The printers iOS has set up, which is what iOS tells an app: none. It will not list printers, so this system has one
/// queue at most, the AirPrint printer the user chose last with `UIPrinterPickerController`. Its URL is kept in the
/// user's defaults and rebuilt with `UIPrinter(url:)`. Printing to it needs no Local Network access, which is why it is
/// here: a phone that refused that can still print.
@MainActor
public final class IOSPrinterSystem: PrinterSystem {
    /// Asks whether the printer answers, within the time `IOSPrinterSystem.contactTimeout` allows.
    public typealias Reach = @MainActor (UIPrinter) async -> Bool

    /// The user's defaults keys of the printer chosen last: its URL, and the name its queue has.
    public static let urlKey = "airprint.url"
    public static let nameKey = "airprint.name"
    /// How long a printer may take to answer before it counts as offline.
    public static let contactTimeout: TimeInterval = 5
    /// How long an answer is kept before the printer is asked again; the queues are read every 5 s.
    public static let recheckAfter: TimeInterval = 30

    /// The printer chosen last; nil until one is chosen.
    public private(set) var printer: UIPrinter?
    /// The name of its queue, which the printer list shows and a job is sent by.
    public private(set) var queueName = ""

    private let defaults: UserDefaults
    private let region: String?
    private let reach: Reach
    private let recheckAfter: TimeInterval
    private var reachable = false
    private var checked: Date?
    /// The contact in progress, started by `queues()`.
    private var contacting: Task<Void, Never>?

    /// `reach` nil: the printer is contacted (`UIPrinter.contactPrinter`). An answer is kept for `recheckAfter` seconds.
    public init(defaults: UserDefaults = UserDefaults.standard, region: String? = Locale.current.region?.identifier,
                reach: Reach? = nil, recheckAfter: TimeInterval = IOSPrinterSystem.recheckAfter) {
        self.defaults = defaults
        self.region = region
        self.recheckAfter = recheckAfter
        if let reach {
            self.reach = reach
        } else {
            self.reach = { (printer: UIPrinter) async -> Bool in
                await IOSPrinterSystem.contact(printer)
            }
        }
        if let text = defaults.string(forKey: IOSPrinterSystem.urlKey), let url = URL(string: text) {
            printer = UIPrinter(url: url)
            queueName = defaults.string(forKey: IOSPrinterSystem.nameKey) ?? IOSPrinterSystem.name(of: url, displayName: "")
        }
    }

    /// The picker could not be shown at all: neither from a place on the screen nor on its own.
    public struct PickerRefused: LocalizedError {
        public var errorDescription: String? { "The system's printer picker could not be opened." }
    }

    /// Shows the system's printer picker; true when the user chose a printer, which is then the one printed to. The
    /// caller reads the printers again. `source` is the view of the control that asked, which an iPad's popover points at. Throws when the system will not show the picker.
    public func choose(from source: UIView? = nil) async throws -> Bool {
        let picker: UIPrinterPickerController = UIPrinterPickerController(initiallySelectedPrinter: printer)
        let picked: UIPrinter? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIPrinter?, Error>) in
            let once: OneShot<UIPrinter?, Error> = OneShot(continuation)
            let handler: UIPrinterPickerController.CompletionHandler = { (controller: UIPrinterPickerController, completed: Bool, error: Error?) -> Void in
                once.resume(returning: completed && error == nil ? controller.selectedPrinter : nil)
            }
            // The printers' screen is a sheet, so the picker goes on top of whatever is in front.
            var shown: Bool = false
            if let source, source.window != nil {
                shown = picker.present(from: source.bounds, in: source, animated: true, completionHandler: handler)
            } else if let anchor = IOSPrinterSystem.topViewController() {
                shown = picker.present(from: anchor.view.bounds, in: anchor.view, animated: true, completionHandler: handler)
            }
            if !shown { shown = picker.present(animated: true, completionHandler: handler) }
            if !shown { once.resume(throwing: PickerRefused()) }
        }
        guard let picked else { return false }
        printer = picked
        queueName = IOSPrinterSystem.name(of: picked.url, displayName: picked.displayName)
        reachable = false
        checked = nil
        contacting = nil
        defaults.set(picked.url.absoluteString, forKey: IOSPrinterSystem.urlKey)
        defaults.set(queueName, forKey: IOSPrinterSystem.nameKey)
        return true
    }

    /// The queue as it was last known, at once: asking the printer takes up to `contactTimeout`, and the list must not
    /// wait for that (a printer not listed yet is not the one a job goes to). The answer comes by the next read.
    public func queues() async -> [SystemPrinter] {
        guard let printer else { return [] }
        contactSoon(printer)
        let model: String? = printer.makeAndModel
        return [SystemPrinter(name: queueName, model: model?.isEmpty == false ? model : nil, port: printer.url.absoluteString,
                              isDefault: true, isVirtual: false, states: reachable ? [] : [.offline], jobs: .none)]
    }

    public func capabilities(ofQueue name: String) async -> PrinterCapabilities? {
        guard let printer, name == queueName else { return nil }
        if let contacting {
            await contacting.value
        } else if !isFresh {
            await refreshReach(printer)
        }
        guard reachable else { return nil }
        return IOSPrinterSystem.capabilities(name: name, model: printer.makeAndModel, duplex: printer.supportsDuplex,
                                             color: printer.supportsColor, region: region)
    }

    public func clearJobs(ofQueue name: String) async throws {
        throw PrintError.unreadable("iOS does not let an app clear a printer's jobs.")
    }

    public func resume(queue name: String) async throws {
        throw PrintError.unreadable("iOS does not let an app resume a printer.")
    }

    /// True when the printer answers now; a job is not sent to one that does not.
    public func isReachable() async -> Bool {
        guard let printer else { return false }
        await refreshReach(printer)
        return reachable
    }

    /// The last answer is recent enough to be used as it is.
    private var isFresh: Bool {
        guard let checked else { return false }
        return Date().timeIntervalSince(checked) < recheckAfter
    }

    private func contactSoon(_ printer: UIPrinter) {
        if contacting != nil || isFresh { return }
        contacting = Task { @MainActor in
            await self.refreshReach(printer)
            self.contacting = nil
        }
    }

    private func refreshReach(_ printer: UIPrinter) async {
        let answer: Bool = await reach(printer)
        // The user may have chosen another printer while this one was asked.
        guard printer.url == self.printer?.url else { return }
        reachable = answer
        checked = Date()
    }

    /// The front-most view controller, which the picker is presented from.
    private static func topViewController() -> UIViewController? {
        let scenes: [UIWindowScene] = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let window: UIWindow? = scenes.flatMap { $0.windows }.first { $0.isKeyWindow } ?? scenes.first?.windows.first
        var controller: UIViewController? = window?.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

    // MARK: Pure

    /// The queue's name: what the picker called the printer, else its host.
    nonisolated static func name(of url: URL, displayName: String) -> String {
        let trimmed: String = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return url.host ?? "AirPrint printer"
    }

    /// The region's usual paper, then the other of Letter and A4, then 4x6, 5x7 and Legal, each with margins of 0.25 in.
    /// iOS does not say what a printer has in its trays; an IPP printer the app knows replaces this list with its own,
    /// and the paper picker takes every size on it.
    nonisolated static func papers(region: String?) -> [MediaEntry] {
        let usual: PaperSize = PaperSizes.defaultForRegion(region)
        let other: PaperSize = usual == .letter ? .a4 : .letter
        // 0.25 in in hundredths of a millimetre
        let edge: Int = 635
        let margins: MediaMargins = MediaMargins(top: edge, left: edge, bottom: edge, right: edge)
        return [usual, other, .photo4x6, .photo5x7, .legal].compactMap { (size: PaperSize) -> MediaEntry? in
            guard let points = PaperSizes.points(size) else { return nil }
            return MediaEntry(attributes: [], width: Int((points.width * 2540 / 72).rounded()),
                              height: Int((points.height * 2540 / 72).rounded()), isVariable: false, margins: margins,
                              type: nil, source: nil)
        }
    }

    /// What the printer's answer makes of it. Copies are not asked of the printer: `UIPrintPageRenderer` has no copy
    /// count, so the job carries them itself.
    nonisolated static func capabilities(name: String, model: String?, duplex: Bool, color: Bool, region: String?) -> PrinterCapabilities {
        var caps: PrinterCapabilities = PrinterCapabilities()
        caps.name = name
        caps.makeAndModel = model ?? ""
        caps.sidesSupported = duplex ? ["one-sided", "two-sided-long-edge", "two-sided-short-edge"] : ["one-sided"]
        caps.printColorModesSupported = color ? ["color", "monochrome"] : ["monochrome"]
        caps.mediaColDatabase = papers(region: region)
        return caps
    }

    /// Asks the printer whether it answers; no answer within `contactTimeout` counts as none.
    private static func contact(_ printer: UIPrinter) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once: OneShot<Bool, Never> = OneShot(continuation)
            printer.contactPrinter { (available: Bool) -> Void in
                once.resume(returning: available)
            }
            DispatchQueue.main.asyncAfter(deadline: DispatchTime.now() + contactTimeout) {
                once.resume(returning: false)
            }
        }
    }
}
#endif

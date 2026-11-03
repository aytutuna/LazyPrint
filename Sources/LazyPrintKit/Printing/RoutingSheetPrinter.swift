import Foundation

// Twin of windows/LazyPrint.App/Printing/RoutingSheetPrinter.cs.

/// Hands each job to the printer its route names: the system's queue, IPP, or the demo printer.
public struct RoutingSheetPrinter: SheetPrinter {
    private let system: any SheetPrinter
    private let ipp: any SheetPrinter
    private let demo: any SheetPrinter

    public init(system: any SheetPrinter, ipp: any SheetPrinter, demo: any SheetPrinter) {
        self.system = system
        self.ipp = ipp
        self.demo = demo
    }

    public func print(_ job: SheetJob, pass: Int, progress: @Sendable (JobStatus) -> Void) async throws {
        let printer: any SheetPrinter
        switch job.printer.route {
        case .system: printer = system
        case .ipp: printer = ipp
        case .demo: printer = demo
        }
        try await printer.print(job, pass: pass, progress: progress)
    }
}

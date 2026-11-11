import Foundation

// Twin of windows/LazyPrint.App/Services/PrinterQueue.cs: the jobs a printer holds, whoever sent them.

extension AppState {
    /// The printer has a queue to list: a queue the Mac's print system holds, or a printer reached over IPP. The demo
    /// printer has none, and neither has the iPhone's AirPrint printer.
    public func hasQueue(_ printer: PrinterInfo) -> Bool {
        switch printer.route {
        case .system: return platform == .mac
        case .ipp: return printer.ippEndpoint != nil
        case .demo: return false
        }
    }

    /// What the printer still has to print. Throws a `PrintError` when it cannot be asked.
    public func queuedJobs(of printer: PrinterInfo) async throws -> [QueuedJob] {
        if printer.route == .system {
            return try await printerSystem.jobs(ofQueue: Self.queueName(of: printer))
        }
        return try await queueClient(for: printer).jobs()
    }

    /// Cancels one of them; a refusal goes to the error bar.
    public func cancelQueuedJob(_ id: Int, of printer: PrinterInfo) async {
        do {
            if printer.route == .system {
                try await printerSystem.cancel(job: id, ofQueue: Self.queueName(of: printer))
            } else {
                try await queueClient(for: printer).cancel(id)
            }
        } catch {
            showFailure("Couldn't cancel the job", error.localizedDescription)
        }
    }

    private func queueClient(for printer: PrinterInfo) throws -> IppClient {
        guard let endpoint = printer.ippEndpoint, let address = endpoint.addresses.first else {
            throw PrintError.unreachable(name: printer.name, reason: "it has no network address")
        }
        let trust = IppTrustStore(directory: files.settingsDirectory)
        let validator = IppCertificateValidator(store: trust, deviceUuid: endpoint.uuid, deviceName: printer.name)
        return IppClient(address: address, printerName: printer.name, userName: platform.requestingUserName, validator: validator)
    }
}

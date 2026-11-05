import Foundation

// Twin of windows/LazyPrint.App/AppViewModel.Companion.cs: the computer's side of the phone link as the state
// sees it, the batches of files phones sent. Nothing prints by itself: the user adds a batch to the job, starts a
// new job with it, or dismisses it.

extension AppState {
    /// Brings `phoneBatches` up to date. A batch that is not whole yet is looked at again when it becomes so, so
    /// a phone that lost the link does not hold back what got through. A batch that is offered stays offered, in its
    /// place, when files of it arrive late; otherwise the bar would go away for another grace period, or give way to a
    /// newer batch, each time one did.
    func refreshPhoneBatches() {
        let now = Date()
        let all = companionHost.batches(now: now)
        let offered: [String] = phoneBatches.map { $0.id }
        let kept: [PhoneBatch] = offered.compactMap { (id: String) -> PhoneBatch? in all.first { $0.id == id } }
        let added: [PhoneBatch] = all.filter { $0.isWhole(now: now) && !offered.contains($0.id) }
        phoneBatches = kept + added
        phoneRetry?.cancel()
        phoneRetry = nil
        let wholeAt: [Date] = all.filter { (batch: PhoneBatch) -> Bool in !phoneBatches.contains { $0.id == batch.id } }
            .map { $0.lastReceived.addingTimeInterval(CompanionInbox.batchGrace) }
        guard let next = wholeAt.min() else { return }
        phoneRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(next.timeIntervalSince(now), 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshPhoneBatches()
        }
    }

    /// Adds the files of the batch to the job, or to a new job when `startNew` (the documents and the page range
    /// are cleared first, once at least one file has opened: when none does, the job stays as it was). A file that
    /// cannot be read or moved is reported and the others still go in. The document task starts when none is, once a file
    /// has opened, so a job left as it was keeps its settings too. Nothing happens while a job runs or another
    /// batch is being taken.
    public func takeBatch(_ id: String, startNew: Bool) async {
        guard !isBusy, !takingBatch else { return }
        takingBatch = true
        defer { takingBatch = false }
        let batch = phoneBatches.first { $0.id == id }
        let files = await companionHost.take(batch: id)
        refreshPhoneBatches()
        let missed = max((batch?.arrived ?? 0) - files.count, 0)
        let (opened, failed) = await openFiles(files)
        guard !opened.isEmpty else {
            if !failed.isEmpty {
                reportNotAdded(failed)
            } else if missed > 0 {
                reportMissed(batch, missed)
            }
            return
        }
        if startNew {
            documents = []
            pageRange = ""
        }
        if task == nil { await startTask(.document) }
        documents.append(contentsOf: opened)
        replan()
        if !failed.isEmpty {
            reportNotAdded(failed)
        } else if missed > 0 {
            reportMissed(batch, missed)
        }
    }

    /// Puts a problem with the cloud folder in the bar as a notice, so it is seen without the phone sheet open. A failure
    /// already in the bar is not replaced, and the sent message stays. nil is the problem gone: its notice leaves.
    public func reportSyncProblem(_ message: String?) {
        guard let message else {
            if error?.title == "Phone sync" { error = nil }
            return
        }
        if let error, !error.isNotice { return }
        let sent = sentMessage
        showNotice("Phone sync", message)
        sentMessage = sent
    }

    /// Deletes the batch's files.
    public func dismissBatch(_ id: String) {
        guard !takingBatch else { return }
        companionHost.discard(batch: id)
        refreshPhoneBatches()
    }

    private func reportMissed(_ batch: PhoneBatch?, _ missed: Int) {
        let from = batch.map { $0.from.isEmpty ? "your phone" : $0.from } ?? "your phone"
        showFailure("Not added", "\(missed) of the \(batch?.arrived ?? missed) files from \(from) could not be moved.")
    }
}

import Foundation

// Twin of windows/LazyPrint.App/AppViewModel.Companion.cs: the computer's side of the phone link as the state
// sees it, the batches of files phones sent. Nothing prints by itself: the user adds a batch to the job, starts a
// new job with it, or dismisses it.

extension AppState {
    /// Brings `phoneBatches` up to date. A batch that is not whole yet is looked at again when it becomes so, so
    /// a phone that lost the link does not hold back what got through.
    func refreshPhoneBatches() {
        let now = Date()
        let all = companionHost.batches(now: now)
        phoneBatches = all.filter { $0.isWhole(now: now) }
        phoneRetry?.cancel()
        phoneRetry = nil
        let wholeAt = all.filter { !$0.isWhole(now: now) }.map { $0.lastReceived.addingTimeInterval(CompanionInbox.batchGrace) }
        guard let next = wholeAt.min() else { return }
        phoneRetry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(next.timeIntervalSince(now), 0) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshPhoneBatches()
        }
    }

    /// Adds the files of the batch to the job, or to a new job when `startNew` (the documents and the page range
    /// are cleared first). A file that cannot be read or moved is reported and the others still go in. Nothing happens
    /// while a job runs or another batch is being taken.
    public func takeBatch(_ id: String, startNew: Bool) async {
        guard !isBusy, !takingBatch else { return }
        takingBatch = true
        defer { takingBatch = false }
        let batch = phoneBatches.first { $0.id == id }
        let files = await companionHost.take(batch: id)
        refreshPhoneBatches()
        let missed = max((batch?.arrived ?? 0) - files.count, 0)
        guard !files.isEmpty else {
            if missed > 0 { reportMissed(batch, missed) }
            return
        }
        if startNew {
            documents = []
            pageRange = ""
        }
        await addFiles(files)
        if missed > 0, error == nil { reportMissed(batch, missed) }
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

import Foundation

// Twin of windows/LazyPrint.App/Printing/JobSides.cs: the sides of a pass, with the copies the job carries itself.

public enum JobSides {
    /// How many times the pages go in the job one after the other: the copies the printer does not make itself
    /// (`JobPlan.copiesInJob` is 1 then).
    public static func repeats(_ job: SheetJob) -> Int {
        job.plan.copiesInJob > 1 || job.items != nil ? 1 : PrintCopies.clamp(job.settings.copies)
    }

    /// The times each side comes out, whoever makes the copies.
    public static func copies(_ job: SheetJob) -> Int {
        max(repeats(job), job.plan.copiesInJob)
    }

    /// The sides of a pass in the order they are sent, the pages repeated for the copies the job carries itself.
    public static func of(_ job: SheetJob, pass: Int) -> [RenderedSide] {
        let sent = job.plan.passes[pass]
        var once = [RenderedSide]()
        for (i, side) in sent.sides.enumerated() {
            let items = job.items?[i].items ?? cutMarks(job, side)
            once.append(RenderedSide(side: side, items: items, marked: sent.marked.contains(i),
                                     turned: job.items?[i].turned ?? false))
        }
        let times = repeats(job)
        return times == 1 ? once : (0..<times).flatMap { _ in once }
    }

    private static func cutMarks(_ job: SheetJob, _ side: SheetSide) -> [TestPageItem] {
        if let options = job.marks { return PhotoLayout.cutMarks(side, options: options, area: job.plan.plan.area) }
        return job.frameMarks ? PhotoLayout.frameMarks(side) : []
    }
}

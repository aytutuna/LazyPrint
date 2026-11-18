/// Which document pages are on a sheet side, for the caption under the preview.
public enum PageLabel {
    /// The pages placed, numbered over the documents in turn: "Page 3", "Pages 3-4", "Pages 1, 8". `pageCounts` is the pages
    /// of each document. Nothing placed is "Blank".
    public static func text(of placements: [Placement], pageCounts: [Int]) -> String {
        let numbers: [Int] = Set(placements.map { (placement: Placement) -> Int in
            pageCounts.prefix(placement.page.document).reduce(0, +) + placement.page.index + 1
        }).sorted()
        guard !numbers.isEmpty else { return "Blank" }
        var runs: [ClosedRange<Int>] = []
        for number in numbers {
            if let last = runs.last, last.upperBound + 1 == number {
                runs[runs.count - 1] = last.lowerBound...number
            } else {
                runs.append(number...number)
            }
        }
        let text: [String] = runs.map { (run: ClosedRange<Int>) -> String in
            run.count == 1 ? "\(run.lowerBound)" : "\(run.lowerBound)\u{2013}\(run.upperBound)"
        }
        return (numbers.count == 1 ? "Page " : "Pages ") + text.joined(separator: ", ")
    }
}

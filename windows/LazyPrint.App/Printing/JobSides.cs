using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App.Printing;

/// <summary>One side as it is drawn: the plan's side, what is drawn over it, and whether it gets the blank back's dot.</summary>
internal readonly record struct DrawnSide(SheetSide Side, IReadOnlyList<TestPageItem>? Items = null, bool Marked = false, bool Turned = false);

internal static class JobSides
{
    /// <summary>
    /// How many times the pages go in the job one after the other: the copies the printer does not make itself
    /// (<see cref="JobPlan.CopiesInJob"/> is 1 then).
    /// </summary>
    public static int Repeats(SheetJob job) =>
        job.Plan.CopiesInJob > 1 || job.Items is not null ? 1 : PrintCopies.Clamp(job.Settings.Copies);

    /// <summary>The times each side comes out, whoever makes the copies.</summary>
    public static int Copies(SheetJob job) => Math.Max(Repeats(job), job.Plan.CopiesInJob);

    private static IReadOnlyList<TestPageItem>? CutMarks(SheetJob job, SheetSide side) =>
        job.Marks is { } options ? PhotoLayout.CutMarks(side, options, job.Plan.Plan.Area)
        : job.FrameMarks ? PhotoLayout.FrameMarks(side) : null;

    /// <summary>The sides of a pass in the order they are sent, the pages repeated for the copies the job carries itself.</summary>
    public static List<DrawnSide> Of(SheetJob job, int pass)
    {
        var sent = job.Plan.Passes[pass];
        var once = sent.Sides
            .Select((side, i) => new DrawnSide(side, job.Items?[i].Items ?? CutMarks(job, side), sent.Marked.Contains(i), job.Items?[i].Turned ?? false))
            .ToList();
        int repeats = Repeats(job);
        return repeats == 1 ? once : [.. Enumerable.Repeat(once, repeats).SelectMany(sides => sides)];
    }
}

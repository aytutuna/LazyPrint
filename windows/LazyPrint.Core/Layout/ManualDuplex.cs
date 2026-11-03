namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/ManualDuplex.swift: two-sided printing on a printer that prints
// one side, in two passes.

/// <summary>
/// How a printer's paper path takes the stack back, learnt once per printer with one sheet (the
/// two-sided check). The defaults are the usual path.
/// </summary>
public sealed record PaperPath
{
    /// <summary>The user turns the stack over to reload it (false: reloads it as it lies).</summary>
    public bool TurnStackOver { get; set; } = true;
    /// <summary>Backs come out upside down unless turned 180°.</summary>
    public bool TurnBacks { get; set; }
    /// <summary>The two-sided check was printed and answered.</summary>
    public bool Checked { get; set; }
}

/// <summary>The sides of one pass, in the order sent to the printer.</summary>
/// <param name="Sides">The sides to print.</param>
/// <param name="Marked">Indices in <paramref name="Sides"/> of blank backs that get the near-white dot.</param>
public sealed record DuplexPass(IReadOnlyList<SheetSide> Sides, IReadOnlyList<int> Marked)
{
    public bool Equals(DuplexPass? other) =>
        other is not null && Sides.SequenceEqual(other.Sides) && Marked.SequenceEqual(other.Marked);

    public override int GetHashCode() => HashCode.Combine(Sides.Count, Marked.Count);
}

/// <summary>The answer to "Do the arrows on both sides point to the same edge?".</summary>
public enum DuplexCheckAnswer
{
    SameEdge,
    OppositeEdges,
    BothOnOneSide,
}

public static class ManualDuplex
{
    /// <summary>
    /// The fronts, then the backs. Sheets stack in the output tray in printing order and the tray feeds its
    /// top sheet first: turning the stack over puts the first sheet on top, so the backs go in sheet order;
    /// reloading it as it lies puts the last sheet on top, so they go in reverse, and each blank back
    /// then is marked so a driver that skips blank pages cannot put the backs out of step. Every front gets
    /// a back, and the backs are turned 180° when <see cref="PaperPath.TurnBacks"/>.
    /// </summary>
    public static (DuplexPass Fronts, DuplexPass Backs) Passes(SheetPlan plan, PaperPath path)
    {
        var fronts = plan.Sheets.Select(sheet => sheet.Front).ToList();
        var backs = plan.Sheets
            .Select(sheet => sheet.Back ?? new SheetSide([], false))
            .Select(back => path.TurnBacks ? Imposition.Turned(back, plan.Area.Paper) : back)
            .ToList();
        var marked = new List<int>();
        if (!path.TurnStackOver)
        {
            backs.Reverse();
            for (int i = 0; i < backs.Count; i++)
            {
                if (backs[i].Placements.Count == 0) marked.Add(i);
            }
        }
        return (new DuplexPass(fronts, []), new DuplexPass(backs, marked));
    }

    /// <summary>The check sheet's two sides: a big "1" on the front and "2" on the back, each with an arrow to its top edge.</summary>
    public static (IReadOnlyList<TestPageItem> Front, IReadOnlyList<TestPageItem> Back) CheckSheet(PrintableArea area) =>
        (CheckSide("1", area.Printable), CheckSide("2", area.Printable));

    /// <summary>
    /// The answer turned into a paper path. The same edge keeps it, opposite edges turn the backs,
    /// and both numbers on one side means the stack must be reloaded the other way: the check runs again.
    /// </summary>
    public static PaperPath Learn(DuplexCheckAnswer answer, PaperPath path) => answer switch
    {
        DuplexCheckAnswer.SameEdge => path with { Checked = true },
        DuplexCheckAnswer.OppositeEdges => path with { TurnBacks = !path.TurnBacks, Checked = true },
        _ => path with { TurnStackOver = !path.TurnStackOver, Checked = false },
    };

    private static IReadOnlyList<TestPageItem> CheckSide(string number, LayoutRect printable)
    {
        const double size = 240;
        double centre = printable.X + printable.Width / 2;
        return
        [
            new TestPageItem.Arrow(new(centre - 30, printable.Y + 24, 60, 100), true),
            new TestPageItem.Text(number, new(centre - size * 0.28, printable.Y + printable.Height / 2 - size * 0.6), size, true),
        ];
    }
}

/// <summary>The step card's words, the same on all three platforms.</summary>
public static class ManualDuplexText
{
    public const string FrontsTitle = "Printing the fronts";
    public const string BacksTitle = "Print the backs";
    public const string CheckTitle = "Check with one sheet";
    public const string CheckQuestion = "Do the arrows on both sides point to the same edge?";

    /// <summary>What to do with the printed fronts: "Take the 7 printed sheets out. Turn the stack over and put it back in the tray, top edge first."</summary>
    public static string Reload(int sheets, PaperPath path) => path.TurnStackOver
        ? $"Take the {sheets} printed sheet{(sheets == 1 ? "" : "s")} out. Turn the stack over and put it back in the tray, top edge first."
        : "Put the stack back in the tray as it is, top edge first.";

    /// <summary>The words on the button for an answer of the check.</summary>
    public static string Answer(DuplexCheckAnswer answer) => answer switch
    {
        DuplexCheckAnswer.SameEdge => "Yes, the same edge",
        DuplexCheckAnswer.OppositeEdges => "No, opposite edges",
        _ => "Both are on one side",
    };
}

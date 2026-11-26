using System.Text.Json.Nodes;
using LazyPrint.Core;

static class LayoutGen
{
    public static string Camel(object e) { var s = e.ToString()!; return char.ToLowerInvariant(s[0]) + s[1..]; }
    public static JsonArray Arr(params double[] v) { var a = new JsonArray(); foreach (var x in v) a.Add(x); return a; }
    static JsonArray Rect(LayoutRect r) => Arr(r.X, r.Y, r.Width, r.Height);

    static JsonObject Side(SheetSide s)
    {
        var placements = new JsonArray();
        foreach (var p in s.Placements)
        {
            placements.Add(new JsonObject
            {
                ["page"] = new JsonArray(p.Page.Document, p.Page.Index),
                ["frame"] = Rect(p.Frame),
                ["turns"] = p.Turns,
                ["crop"] = p.Crop is { } c ? Rect(c) : null,
            });
        }
        var cuts = new JsonArray();
        foreach (var c in s.CutCells) cuts.Add(Rect(c));
        return new JsonObject { ["borders"] = s.Borders, ["placements"] = placements, ["cutCells"] = cuts };
    }

    public static JsonObject Plan(SheetPlan plan)
    {
        var sheets = new JsonArray();
        foreach (var sh in plan.Sheets)
            sheets.Add(new JsonObject { ["front"] = Side(sh.Front), ["back"] = sh.Back is { } b ? Side(b) : null });
        var warnings = new JsonArray();
        foreach (var w in plan.Warnings)
        {
            warnings.Add(w switch
            {
                PlanWarning.Clipped c => new JsonObject { ["kind"] = "clipped", ["points"] = c.Points },
                PlanWarning.PaddedWithBlanks p => new JsonObject { ["kind"] = "padded", ["count"] = p.Count },
                _ => throw new InvalidOperationException(),
            });
        }
        return new JsonObject { ["duplex"] = plan.Duplex, ["printedScale"] = plan.PrintedScale, ["warnings"] = warnings, ["sheets"] = sheets };
    }

    public static JsonObject OptionsJson(LayoutOptions o) => new()
    {
        ["pagesPerSheet"] = o.PagesPerSheet, ["booklet"] = o.Booklet, ["rightToLeft"] = o.RightToLeft,
        ["scaling"] = Camel(o.Scaling), ["sides"] = Camel(o.Sides), ["pageBorders"] = o.PageBorders, ["scale"] = o.Scale,
        ["orientation"] = Camel(o.Orientation), ["margin"] = o.Margin,
        ["margins"] = o.Margins is { } m ? Arr(m.Top, m.Left, m.Bottom, m.Right) : null,
        ["backsTurnedAfter"] = o.BacksTurnedAfter, ["poster"] = o.Poster,
        ["cellSize"] = o.CellSize is { } c ? Arr(c.Width, c.Height) : null, ["cutMarks"] = o.CutMarks,
    };

    public static JsonArray PagesJson(List<SourcePage> pages)
    {
        var pg = new JsonArray();
        foreach (var p in pages) pg.Add(Arr(p.Document, p.Index, p.Size.Width, p.Size.Height));
        return pg;
    }

    public static JsonObject AreaJson(PrintableArea area) => new()
    {
        ["paper"] = Arr(area.Paper.Width, area.Paper.Height),
        ["margins"] = Arr(area.Margins.Top, area.Margins.Left, area.Margins.Bottom, area.Margins.Right),
    };

    static JsonNode Case(string name, List<SourcePage> pages, LayoutOptions o, PrintableArea area)
    {
        var plan = Imposition.Plan(pages, o, area);
        var fits = new JsonObject();
        foreach (var s in PhotoSize.All) if (s.Size is { } sz) fits[s.Id] = Imposition.SizeFits(o, area, sz);
        return new JsonObject
        {
            ["name"] = name, ["pages"] = PagesJson(pages), ["options"] = OptionsJson(o), ["area"] = AreaJson(area),
            ["edge"] = Imposition.Edge(area), ["sizeFits"] = fits, ["plan"] = Plan(plan),
        };
    }

    public static List<PrintableArea> Areas()
    {
        var letter = new LayoutSize(612, 792);
        var a4 = PaperSizes.Points(PaperSize.A4)!.Value;
        var a6 = PaperSizes.Points(PaperSize.A6)!.Value;
        return
        [
            new(letter, new LayoutInsets(0, 0, 0, 0)),
            new(letter, new LayoutInsets(18, 18, 18, 18)),
            new(a4, new LayoutInsets(8.5, 12, 30, 12)),
            new(a4, new LayoutInsets(0, 0, 0, 0)),
            new(a6, new LayoutInsets(12, 12, 12, 12)),
        ];
    }

    public static SourcePage P(int i, double w, double h, int d = 0) => new(d, i, new LayoutSize(w, h));

    public static List<List<SourcePage>> Mixes() =>
    [
        [],
        [P(0, 612, 792)],
        [P(0, 612, 792), P(1, 612, 792), P(2, 612, 792), P(3, 612, 792), P(4, 612, 792)],
        [P(0, 792, 612), P(1, 792, 612), P(2, 792, 612)],
        [P(0, 595, 842), P(1, 842, 595), P(2, 595, 842), P(3, 400, 400), P(4, 595, 842, 1), P(5, 595, 842, 1), P(6, 300, 200, 1)],
        [P(0, 1200, 1700), P(1, 100, 150)],
        [.. Enumerable.Range(0, 12).Select(i => P(i, 612, 792))],
        [P(0, 432, 288), P(1, 288, 432), P(2, 360, 504), P(3, 504, 360)],
    ];

    public static void Write(string path)
    {
        var areas = Areas();
        var mixes = Mixes();
        var rng = new Random(20261126);
        T Pick<T>(IReadOnlyList<T> items) => items[rng.Next(items.Count)];
        var cases = new List<JsonNode>();
        int n = 0;

        foreach (var area in areas.Take(2))
        {
            foreach (var pages in mixes.Skip(1).Take(4))
            {
                foreach (var scaling in Enum.GetValues<Scaling>())
                    foreach (var orient in Enum.GetValues<SheetOrientation>())
                        cases.Add(Case($"alone-{n++}", pages, new LayoutOptions { Scaling = scaling, Orientation = orient, Margin = 12 }, area));
                foreach (int per in new[] { 2, 6, 16, 3 })
                    foreach (var scaling in new[] { Scaling.Fit, Scaling.Fill })
                        cases.Add(Case($"grid-{n++}", pages, new LayoutOptions { PagesPerSheet = per, Scaling = scaling, PageBorders = per % 2 == 0 }, area));
                cases.Add(Case($"booklet-{n++}", pages, new LayoutOptions { Booklet = true }, area));
                cases.Add(Case($"booklet-rtl-{n++}", pages, new LayoutOptions { Booklet = true, RightToLeft = true, PageBorders = true, Margin = 20 }, area));
                foreach (int poster in new[] { 2, 3 })
                    cases.Add(Case($"poster-{n++}", pages.Take(2).ToList(), new LayoutOptions { Poster = poster, Margin = 6 }, area));
            }
        }
        var sizes = new LayoutSize?[] { null, new(288, 432), new(360, 504), new(144, 252), new(72 * 8, 72 * 10) };
        for (int i = 0; i < 130; i++)
        {
            var o = new LayoutOptions
            {
                PagesPerSheet = Pick(new[] { 1, 1, 2, 4, 6, 9, 16, 5 }),
                Booklet = rng.Next(8) == 0,
                RightToLeft = rng.Next(4) == 0,
                Scaling = Pick(Enum.GetValues<Scaling>()),
                Sides = Pick(Enum.GetValues<Sides>()),
                PageBorders = rng.Next(3) == 0,
                Scale = Pick(new[] { 100, 100, 50, 250, 5, 500 }),
                Orientation = Pick(Enum.GetValues<SheetOrientation>()),
                Margin = Pick(new[] { 0.0, 12, 34.015748031496, 60 }),
                Margins = rng.Next(3) == 0 ? new LayoutInsets(rng.Next(40), rng.Next(40), rng.Next(40), rng.Next(40)) : null,
                BacksTurnedAfter = rng.Next(5) == 0,
                Poster = Pick(new[] { 0, 0, 0, 0, 0, 2, 3, 4, 1, 5 }),
                CellSize = Pick(sizes),
                CutMarks = rng.Next(3) == 0,
            };
            var pages = Pick(mixes.Skip(1).ToList());
            if (o.Poster >= 2 && pages.Count > 3) pages = pages.Take(3).ToList();
            cases.Add(Case($"mixed-{n++}", pages, o, Pick(areas)));
        }
        File.WriteAllText(path, string.Join("\n", cases.Select(c => c.ToJsonString())) + "\n");
        Console.WriteLine($"imposition: {cases.Count} cases");
    }
}

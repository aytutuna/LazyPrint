using System.Text.Json.Nodes;
using LazyPrint.Core;
using static LayoutGen;

static class MiscGen
{
    static JsonArray Strs(IEnumerable<string> v) { var a = new JsonArray(); foreach (var s in v) a.Add(s); return a; }
    static JsonArray Ints(IEnumerable<int> v) { var a = new JsonArray(); foreach (var s in v) a.Add(s); return a; }

    public static void Write(string path)
    {
        var o = new JsonObject();

        var margins = new JsonArray();
        foreach (var choice in Enum.GetValues<MarginChoice>())
            foreach (double custom in new[] { 0, 3.456, 10, 49.999, 50, 80, -4, 0.05 + 0.1, double.NaN })
                foreach (double edge in new[] { 0, 4.3, 6.4 })
                    margins.Add(new JsonObject
                    {
                        ["choice"] = Camel(choice), ["custom"] = double.IsNaN(custom) ? null : custom, ["printerEdge"] = edge,
                        ["millimetres"] = MarginChoices.Millimetres(choice, double.IsNaN(custom) ? 0 : custom, edge),
                        ["points"] = MarginChoices.Points(choice, double.IsNaN(custom) ? 0 : custom, edge),
                    });
        o["margins"] = margins;
        var rounds = new JsonArray();
        foreach (double v in new[] { 0, 0.004, 0.005, 0.015, 12.345, 49.994, 50.006, -1, 0.05 + 0.1, 7.125 })
            rounds.Add(new JsonObject { ["in"] = v, ["out"] = MarginChoices.Round(v) });
        o["marginRound"] = rounds;

        var ranges = new JsonArray();
        foreach (var (text, count) in new (string, int)[]
        {
            ("1-3, 5", 8), ("8-", 8), ("5-2", 8), ("1 2 3", 8), ("1;3;5", 8), ("1–3", 8), ("1—3", 8), ("2 - 4", 8), ("3,3,3", 8),
            ("9", 8), ("9-12", 8), ("6-12", 8), ("", 8), ("abc", 8), ("0", 8), ("1-", 1), ("2-", 1), ("1,,2", 8), ("-3", 8),
            ("1-2-3", 8), ("  4 ", 8), ("1,2 , 4-6;8", 8), ("00003", 8), ("99999999999999999999", 8), ("2-9", 1), ("3", 1),
        })
        {
            var r = PageRange.Parse(text, count);
            ranges.Add(new JsonObject { ["text"] = text, ["pageCount"] = count, ["pages"] = Ints(r.Pages), ["error"] = r.Error?.Message });
        }
        o["pageRange"] = ranges;

        var labels = new JsonArray();
        foreach (var (pls, counts) in new (int[][], int[])[]
        {
            ([], [3]), ([[0, 2]], [3, 4]), ([[0, 0], [0, 1]], [3]), ([[0, 0], [0, 7]], [8]), ([[0, 0], [1, 0], [1, 1], [1, 3]], [2, 5]),
            ([[0, 2], [0, 1], [0, 0]], [3]), ([[0, 1], [0, 1]], [3]), ([[1, 0]], [2, 2]),
        })
        {
            var placements = pls.Select(p => new Placement(new SourcePage(p[0], p[1], new LayoutSize(1, 1)), new LayoutRect(0, 0, 1, 1), 0, null));
            labels.Add(new JsonObject { ["placements"] = new JsonArray(pls.Select(p => (JsonNode)new JsonArray(p[0], p[1])).ToArray()),
                ["pageCounts"] = Ints(counts), ["text"] = PageLabel.Text(placements, counts) });
        }
        o["pageLabel"] = labels;

        var picks = new JsonArray();
        foreach (var sel in Enum.GetValues<PageSelection>())
            foreach (bool rev in new[] { false, true })
                foreach (var pages in new[] { new int[0], [0], [0, 1, 2, 3, 4], [4, 3, 1, 0], [2, 2, 3] })
                    picks.Add(new JsonObject { ["pages"] = Ints(pages), ["selection"] = Camel(sel), ["reverse"] = rev, ["out"] = Ints(PagePicker.Apply(pages, sel, rev)) });
        o["pagePicker"] = picks;

        var copies = new JsonArray();
        foreach (int req in new[] { -3, 0, 1, 2, 5, 99, 100, 500 })
            foreach (int? max in new int?[] { null, 1, 5, 99 })
                foreach (int pages in new[] { 1, 3 })
                    foreach (bool collate in new[] { true, false })
                    {
                        var p = PrintCopies.Plan(req, max, pages, collate);
                        copies.Add(new JsonObject { ["requested"] = req, ["max"] = max, ["pageCount"] = pages, ["canCollate"] = collate,
                            ["ticketCopies"] = p.TicketCopies, ["documentRepeats"] = p.DocumentRepeats });
                    }
        o["copies"] = copies;

        var photos = new JsonArray();
        foreach (var s in PhotoSize.All)
            photos.Add(new JsonObject { ["id"] = s.Id, ["title"] = s.Title, ["size"] = s.Size is { } z ? Arr(z.Width, z.Height) : null });
        o["photoSizes"] = photos;

        var duplex = new JsonArray();
        var areas = Areas();
        int n = 0;
        foreach (var pages in Mixes().Skip(2).Take(4))
            foreach (var pp in new[] { new PaperPath(), new PaperPath { TurnBacks = true }, new PaperPath { TurnStackOver = false },
                         new PaperPath { TurnStackOver = false, TurnBacks = true } })
                foreach (var opts in new[] { new LayoutOptions { Sides = Sides.LongEdge }, new LayoutOptions { Booklet = true }, new LayoutOptions { Sides = Sides.ShortEdge, PagesPerSheet = 2, CutMarks = true } })
                {
                    var area = areas[n++ % areas.Count];
                    var plan = Imposition.Plan(pages, opts with { BacksTurnedAfter = pp.TurnBacks }, area);
                    var (fronts, backs) = ManualDuplex.Passes(plan, pp);
                    JsonObject Pass(DuplexPass p)
                    {
                        var sides = new JsonArray();
                        foreach (var s in p.Sides) sides.Add(Plan(new SheetPlan(area, [new Sheet(s, null)], false, [])).AsObject()["sheets"]![0]!["front"]!.DeepClone());
                        return new JsonObject { ["sides"] = sides, ["marked"] = Ints(p.Marked) };
                    }
                    duplex.Add(new JsonObject
                    {
                        ["pages"] = PagesJson(pages), ["options"] = OptionsJson(opts with { BacksTurnedAfter = pp.TurnBacks }), ["area"] = AreaJson(area),
                        ["path"] = new JsonObject { ["turnStackOver"] = pp.TurnStackOver, ["turnBacks"] = pp.TurnBacks, ["checked"] = pp.Checked },
                        ["fronts"] = Pass(fronts), ["backs"] = Pass(backs),
                    });
                }
        o["manualDuplex"] = duplex;

        var learn = new JsonArray();
        foreach (var ans in Enum.GetValues<DuplexCheckAnswer>())
            foreach (var turnStack in new[] { true, false })
                foreach (var turnBacks in new[] { true, false })
                    foreach (var done in new[] { true, false })
                    {
                        var start = new PaperPath { TurnStackOver = turnStack, TurnBacks = turnBacks, Checked = done };
                        var r = ManualDuplex.Learn(ans, start);
                        learn.Add(new JsonObject { ["answer"] = Camel(ans),
                            ["from"] = new JsonObject { ["turnStackOver"] = turnStack, ["turnBacks"] = turnBacks, ["checked"] = done },
                            ["to"] = new JsonObject { ["turnStackOver"] = r.TurnStackOver, ["turnBacks"] = r.TurnBacks, ["checked"] = r.Checked } });
                    }
        o["learn"] = learn;
        var reload = new JsonArray();
        foreach (int sheets in new[] { 1, 2, 7 })
            foreach (bool turn in new[] { true, false })
                reload.Add(new JsonObject { ["sheets"] = sheets, ["turnStackOver"] = turn, ["text"] = ManualDuplexText.Reload(sheets, new PaperPath { TurnStackOver = turn }) });
        o["reload"] = reload;

        File.WriteAllText(path, o.ToJsonString(new System.Text.Json.JsonSerializerOptions { WriteIndented = false }) + "\n");
        Console.WriteLine("layout misc written");
    }
}

using System.Text.Json.Nodes;
using LazyPrint.Core;
using static LayoutGen;

static class JobsGen
{
    static JsonArray Strs(IEnumerable<string> v) { var a = new JsonArray(); foreach (var s in v) a.Add(s); return a; }

    static JsonObject PrinterJson(PrinterCapabilities p)
    {
        var o = PaperGen.MediaJson(p);
        o["sidesSupported"] = Strs(p.SidesSupported);
        o["copiesUpper"] = p.CopiesSupported.Upper;
        o["multipleDocumentHandling"] = Strs(p.MultipleDocumentHandlingSupported);
        o["mediaTypes"] = Strs(p.MediaTypeSupported);
        o["mediaSources"] = Strs(p.MediaSourceSupported);
        o["colorModes"] = Strs(p.PrintColorModesSupported);
        o["mediaColSupported"] = Strs(p.MediaColSupported);
        o["printScalingSupported"] = Strs(p.PrintScalingSupported);
        o["printQualitySupported"] = new JsonArray(p.PrintQualitySupported.Select(q => (JsonNode)q).ToArray());
        return o;
    }

    static PrinterCapabilities Fixture(string name)
    {
        string dir = Path.Combine(Gen.Root, "Tests", "Fixtures", "Ipp", "printers");
        return PrinterCapabilities.From(IppMessage.Decode(File.ReadAllBytes(Path.Combine(dir, name + ".bin"))).Message);
    }

    static List<PrinterCapabilities?> Printers()
    {
        var list = new List<PrinterCapabilities?> { null };
        foreach (var n in new[] { "hp-laserjet", "epson-ecotank", "brother-laser", "canon-pixma" }) list.Add(Fixture(n));
        var epson = Fixture("epson-ecotank");
        list.Add(new PrinterCapabilities { SidesSupported = ["one-sided"], CopiesSupported = (1, 99), MediaColDatabase = epson.MediaColDatabase, MediaColReady = epson.MediaColReady });
        list.Add(new PrinterCapabilities { MediaReady = ["iso_a5_148x210mm"], MediaSupported = ["iso_a5_148x210mm", "na_letter_8.5x11in"], SidesSupported = ["two-sided-short-edge", "one-sided"], CopiesSupported = (1, 5),
            PrintColorModesSupported = ["monochrome"], MediaTypeSupported = ["stationery", "photographic-glossy"], MediaSourceSupported = ["main", "manual"] });
        list.AddRange(PaperGen.Printers().Skip(1).Take(2));
        static IppAttribute Dim(string n, double mm) => new(n, new IppValue.Integer((int)(mm * 100)));
        static MediaEntry Full(double wMm, double hMm, int margin, string type) => new(
            [new IppAttribute("media-size", new IppValue.Collection([Dim("x-dimension", wMm), Dim("y-dimension", hMm)])),
             new IppAttribute("media-bottom-margin", new IppValue.Integer(margin)), new IppAttribute("media-left-margin", new IppValue.Integer(margin)),
             new IppAttribute("media-right-margin", new IppValue.Integer(margin)), new IppAttribute("media-top-margin", new IppValue.Integer(margin)),
             new IppAttribute("media-type", new IppValue.Keyword(type)), new IppAttribute("media-source", new IppValue.Keyword("main"))],
            (int)(wMm * 100), (int)(hMm * 100), false, new MediaMargins(margin, margin, margin, margin), type, "main");
        list.Add(new PrinterCapabilities
        {
            MediaColDatabase = [Full(210, 297, 423, "stationery"), Full(210, 297, 0, "photographic-glossy"), Full(101.6, 152.4, 0, "photographic-glossy"), Full(215.9, 279.4, 635, "stationery")],
            MediaColReady = [Full(210, 297, 423, "stationery")],
            MediaColSupported = ["media-size", "media-type", "media-source", "media-bottom-margin"],
            MediaTypeSupported = ["stationery", "photographic-glossy", "labels"], MediaSourceSupported = ["main", "tray-2"],
            SidesSupported = ["one-sided", "two-sided-long-edge", "two-sided-short-edge"], CopiesSupported = (1, 99),
            MultipleDocumentHandlingSupported = ["separate-documents-collated-copies"],
            PrintQualitySupported = [3, 4, 5], PrintScalingSupported = ["auto", "auto-fit", "fit", "none"],
        });
        return list;
    }

    static JsonObject TicketJson(IppJobTicket t) => new()
    {
        ["jobName"] = t.JobName, ["documentFormat"] = t.DocumentFormat, ["copies"] = t.Copies, ["sides"] = t.Sides, ["colorMode"] = t.ColorMode,
        ["media"] = new JsonObject { ["entry"] = t.Media.Entry is { } e ? PaperGen.Attrs(e) : null, ["name"] = t.Media.Name },
        ["quality"] = t.Quality, ["scaling"] = t.Scaling, ["collatedCopies"] = t.CollatedCopies,
    };

    public static void Write(string path)
    {
        var rng = new Random(20261129);
        var printers = Printers();
        var o = new JsonObject();

        var plist = new JsonArray();
        foreach (var p in printers) plist.Add(p is null ? null : PrinterJson(p));
        o["printers"] = plist;

        var cases = new JsonArray();
        for (int i = 0; i < 100; i++)
        {
            var sj = SettingsGen.RandomSettings(rng, false);
            sj.Remove("layoutStyle"); sj.Remove("photoFill");
            sj["paperId"] = new[] { "auto", "a4", "letter", "photo4x6", "listed_sheet_100x150mm", "iso_a5_148x210mm", "legal", "custom_sheet_150x200mm" }[rng.Next(8)];
            sj["mediaType"] = new[] { "auto", "stationery", "photographic-glossy", "photographic-matte", "bond" }[rng.Next(5)];
            sj["mediaSource"] = new[] { "auto", "main", "tray-2" }[rng.Next(3)];
            SettingsGen.LoadSettings(sj.ToJsonString(), out var settings);
            settings!.Copies = new[] { 1, 1, 2, 5, 99 }[rng.Next(5)];
            settings.PageSelection = new[] { PageSelection.All, PageSelection.All, PageSelection.Odd, PageSelection.Even }[rng.Next(4)];
            settings.ReverseOrder = rng.Next(6) == 0;

            int docCount = rng.Next(1, 4);
            var docs = new List<LoadedDocument>();
            var docsJson = new JsonArray();
            var sizes = new[] { new LayoutSize(612, 792), new LayoutSize(595.2756, 841.8898), new LayoutSize(792, 612), new LayoutSize(432, 288), new LayoutSize(288, 432), new LayoutSize(400, 400) };
            for (int d = 0; d < docCount; d++)
            {
                int n = rng.Next(1, 5);
                var pages = Enumerable.Range(0, n).Select(_ => sizes[rng.Next(sizes.Length)]).ToList();
                var doc = new LoadedDocument("Doc" + d, new DocumentKind.Photo(), pages);
                var turns = new JsonArray();
                int turnsMade = rng.Next(3);
                for (int t = 0; t < turnsMade; t++)
                    doc = doc.Turned(rng.Next(3) == 0 ? null : rng.Next(n), rng.Next(2) == 0 ? 1 : -1);
                foreach (var t in doc.Turns) turns.Add(t);
                docs.Add(doc);
                var pj = new JsonArray();
                foreach (var pg in pages) pj.Add(Arr(pg.Width, pg.Height));
                docsJson.Add(new JsonObject { ["pages"] = pj, ["turns"] = turns });
            }
            int total = docs.Sum(x => x.Pages.Count);
            List<int>? range = rng.Next(3) == 0 ? Enumerable.Range(0, rng.Next(1, 8)).Select(_ => rng.Next(total + 2)).ToList() : null;
            var pp = new PaperPath { TurnStackOver = rng.Next(2) == 0, TurnBacks = rng.Next(2) == 0 };
            int pi = rng.Next(printers.Count);
            var printer = printers[pi];
            var prefs = new PrinterPrefs { PaperPath = pp };
            var job = PrintJobs.Plan(docs, range, settings, printer, prefs);
            var options = PrintJobs.LayoutOptions(settings, printer);
            var area = PrintJobs.Area(settings, printer);
            var passes = new JsonArray();
            foreach (var pass in job.Passes)
            {
                var sides = new JsonArray();
                foreach (var s in pass.Sides) sides.Add(LayoutGen.Plan(new SheetPlan(area, [new Sheet(s, null)], false, []))["sheets"]![0]!["front"]!.DeepClone());
                passes.Add(new JsonObject { ["sides"] = sides, ["marked"] = new JsonArray(pass.Marked.Select(m => (JsonNode)m).ToArray()) });
            }
            bool asIs = rng.Next(2) == 0;
            string format = new[] { "application/pdf", "image/jpeg" }[rng.Next(2)];
            var ticket = PrintJobs.Ticket(job, settings, format, printer, "Job " + i, asIs);
            var photoSizes = PrintJobs.PhotoSizes(settings, printer).Select(p => p.Id);
            cases.Add(new JsonObject
            {
                ["settings"] = sj, ["runtime"] = new JsonObject { ["copies"] = settings.Copies, ["pageSelection"] = Camel(settings.PageSelection), ["reverseOrder"] = settings.ReverseOrder },
                ["documents"] = docsJson, ["pageRange"] = range is null ? null : new JsonArray(range.Select(r => (JsonNode)r).ToArray()),
                ["printer"] = pi, ["paperPath"] = new JsonObject { ["turnStackOver"] = pp.TurnStackOver, ["turnBacks"] = pp.TurnBacks, ["checked"] = false },
                ["region"] = "CA",
                ["options"] = OptionsJson(options), ["area"] = AreaJson(area),
                ["printerEdge"] = PrintJobs.PrinterEdge(settings, printer), ["printerMargin"] = PrintJobs.PrinterMargin(settings, printer),
                ["photoSizes"] = Strs(photoSizes), ["sheet"] = Arr(PrintJobs.Sheet(settings.PaperId, printer).Width, PrintJobs.Sheet(settings.PaperId, printer).Height),
                ["plan"] = LayoutGen.Plan(job.Plan), ["manualDuplex"] = job.ManualDuplex, ["passes"] = passes, ["copiesInJob"] = job.CopiesInJob, ["notes"] = Strs(job.Notes),
                ["asIs"] = asIs, ["format"] = format, ["ticket"] = TicketJson(ticket),
            });
        }
        o["cases"] = cases;

        var turned = new JsonArray();
        var doc0 = new LoadedDocument("D", new DocumentKind.Photo(), [new LayoutSize(432, 288), new LayoutSize(288, 432), new LayoutSize(100, 200)]);
        foreach (var seq in new (int? Page, int Quarter)[][]
        {
            [(0, 1)], [(0, -1)], [(0, 1), (0, 1), (0, 1), (0, 1)], [(1, 1), (1, 1)], [(null, 1)], [(1, 1), (null, 1)], [(null, 4)], [(0, -1), (0, 1)], [(2, -1), (2, -1), (2, -1)], [(null, -1), (1, 1)],
        })
        {
            var d = doc0;
            foreach (var (page, q) in seq) d = d.Turned(page, q);
            turned.Add(new JsonObject
            {
                ["ops"] = new JsonArray(seq.Select(s => (JsonNode)new JsonObject { ["page"] = s.Page, ["quarter"] = s.Quarter }).ToArray()),
                ["turns"] = new JsonArray(d.Turns.Select(t => (JsonNode)t).ToArray()), ["isTurned"] = d.IsTurned,
                ["sizes"] = new JsonArray(Enumerable.Range(0, 3).Select(i => (JsonNode)Arr(d.Size(i).Width, d.Size(i).Height)).ToArray()),
            });
        }
        o["turned"] = turned;
        o["jobStates"] = Strs(Enum.GetNames<JobState>());
        File.WriteAllText(path, o.ToJsonString() + "\n");
        Console.WriteLine("jobs written");
    }
}

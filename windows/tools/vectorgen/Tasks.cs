using System.Reflection;
using System.Text.Json.Nodes;
using LazyPrint.Core;
using static LayoutGen;

static class TasksGen
{
    public static void Write(string path)
    {
        var rng = new Random(20261128);
        var o = new JsonObject();
        var defs = new JsonArray();
        foreach (var d in TaskCatalog.All)
            defs.Add(new JsonObject { ["task"] = d.Task.RawValue(), ["title"] = d.Title, ["subtitle"] = d.Subtitle, ["iconKey"] = d.IconKey,
                ["group"] = Camel(d.Group), ["groupTitle"] = d.Group.Title(), ["opensFiles"] = d.OpensFiles });
        o["definitions"] = defs;
        var tasks = new JsonArray();
        foreach (var p in new[] { AppPlatform.Windows, AppPlatform.Mac, AppPlatform.Ios })
            tasks.Add(new JsonObject { ["platform"] = Camel(p), ["tasks"] = new JsonArray(TaskCatalog.Tasks(p).Select(d => (JsonNode)d.Task.RawValue()).ToArray()) });
        o["platformTasks"] = tasks;
        var avail = new JsonArray();
        foreach (var t in PrintTasks.All)
            foreach (bool hasPrinter in new[] { true, false })
                foreach (bool scan in new[] { true, false })
                {
                    var a = TaskCatalog.Availability(t, new TaskContext(hasPrinter, scan, AppPlatform.Windows));
                    avail.Add(new JsonObject { ["task"] = t.RawValue(), ["hasPrinter"] = hasPrinter, ["lazyScan"] = scan, ["available"] = a.IsAvailable, ["reason"] = a.Reason });
                }
        o["availability"] = avail;
        var parse = new JsonArray();
        foreach (var s in new string?[] { null, "document", "twoSided", "Document", "nope", "fromPhone" })
            parse.Add(new JsonObject { ["in"] = s, ["task"] = PrintTasks.TryParse(s)?.RawValue() });
        o["parse"] = parse;

        var applies = new JsonArray();
        var printers = new (bool TwoSided, string[] Types)[] { (false, []), (true, []), (true, ["stationery", "photographic-glossy", "photographic"]), (false, ["photographic-matte", "photographic-satin"]) };
        for (int i = 0; i < 90; i++)
        {
            var s = RandomJson(rng);
            var d = Directory.CreateDirectory(Path.Combine(Gen.Temp, Guid.NewGuid().ToString("N"))).FullName;
            File.WriteAllText(Path.Combine(d, "settings.json"), s.ToJsonString());
            var settings = (PrintSettings)typeof(SettingsStore).GetMethod("Load", BindingFlags.NonPublic | BindingFlags.Static, [typeof(string)])!.Invoke(null, [d])!;
            settings.Copies = rng.Next(1, 5);
            var task = PrintTasks.All[rng.Next(PrintTasks.All.Count)];
            var (two, types) = printers[rng.Next(printers.Length)];
            var cap = new PrinterCapabilities { SidesSupported = two ? ["one-sided", "two-sided-long-edge"] : ["one-sided"], MediaTypeSupported = types };
            bool none = rng.Next(6) == 0;
            if (none) { two = false; types = []; }
            var result = TaskCatalog.Apply(task, settings, none ? null : cap);
            var d2 = Directory.CreateDirectory(Path.Combine(Gen.Temp, Guid.NewGuid().ToString("N"))).FullName;
            typeof(SettingsStore).GetMethod("Save", BindingFlags.NonPublic | BindingFlags.Static, [typeof(PrintSettings), typeof(string)])!.Invoke(null, [result, d2]);
            applies.Add(new JsonObject
            {
                ["task"] = task.RawValue(), ["settings"] = s, ["copies"] = settings.Copies, ["twoSided"] = two, ["mediaTypes"] = new JsonArray(types.Select(t => (JsonNode)t).ToArray()),
                ["noPrinter"] = none, ["result"] = JsonNode.Parse(File.ReadAllText(Path.Combine(d2, "settings.json"))),
                ["resultCopies"] = result.Copies,
            });
        }
        o["apply"] = applies;
        File.WriteAllText(path, o.ToJsonString() + "\n");
        Console.WriteLine("tasks written");
    }

    static JsonObject RandomJson(Random rng)
    {
        JsonNode? Pick(params object?[] v) { var x = v[rng.Next(v.Length)]; return x is null ? null : JsonValue.Create(x switch { int i => (object)i, double d => d, bool b => b, string s => s, _ => throw new InvalidOperationException() }); }
        return new JsonObject
        {
            ["taskId"] = Pick(null, "document", "photos", "photoSheet"),
            ["printerId"] = Pick(null, "p1"),
            ["collate"] = Pick(true, false),
            ["color"] = Pick("color", "gray"),
            ["quality"] = Pick("normal", "draft", "best"),
            ["sides"] = Pick("oneSided", "longEdge", "shortEdge"),
            ["pagesPerSheet"] = Pick(1, 2, 4, 9),
            ["booklet"] = Pick(true, false),
            ["scaling"] = Pick("shrinkToFit", "fit", "actualSize", "fill"),
            ["scale"] = Pick(100, 50, 250),
            ["margin"] = Pick("none", "printer", "normal", "custom"),
            ["marginMm"] = Pick(10.0, 3.5),
            ["poster"] = Pick(0, 2),
            ["paperId"] = Pick("auto", "a4", "photo4x6"),
            ["mediaSource"] = Pick("auto", "tray-2"),
            ["mediaType"] = Pick("auto", "stationery", "photographic-glossy", "photographic", "photographic-matte", "photographic-satin", "cardstock"),
            ["photoSizeId"] = Pick("page", "4x6", "5x7"),
            ["cutMarks"] = Pick(true, false),
        };
    }
}

using System.Reflection;
using System.Text.Json;
using System.Text.Json.Nodes;
using LazyPrint.Core;
using static LayoutGen;

static class SettingsGen
{
    static readonly BindingFlags Internal = BindingFlags.NonPublic | BindingFlags.Static;
    static readonly Type Store = typeof(SettingsStore);

    static T Call<T>(string name, params object[] args) =>
        (T)Store.GetMethod(name, Internal, args.Select(a => a.GetType()).ToArray())!.Invoke(null, args)!;

    static string Dir() { var d = Path.Combine(Gen.Temp, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(d); return d; }

    static string Roundtrip(string file, string text)
    {
        var d = Dir();
        File.WriteAllText(Path.Combine(d, file), text, new System.Text.UTF8Encoding(false));
        return d;
    }

    static JsonNode? ParseFile(string path) => File.Exists(path) ? JsonNode.Parse(File.ReadAllText(path)) : null;

    public static JsonNode? LoadSettings(string text, out PrintSettings? loaded)
    {
        var d = Roundtrip("settings.json", text);
        loaded = Call<PrintSettings?>("Load", d);
        if (loaded is null) return null;
        Call<object>("Save", loaded, d);
        return ParseFile(Path.Combine(d, "settings.json"));
    }

    static JsonNode? LoadPrinters(string text)
    {
        var d = Roundtrip("printers.json", text);
        var loaded = Call<Dictionary<string, PrinterPrefs>>("LoadPrinters", d);
        var d2 = Dir();
        Call<object>("SavePrinters", loaded, d2);
        return ParseFile(Path.Combine(d2, "printers.json"));
    }

    static JsonNode? LoadPresets(string text)
    {
        var d = Roundtrip("presets.json", text);
        var loaded = Call<List<UserPreset>>("LoadPresets", d);
        var d2 = Dir();
        Call<object>("SavePresets", loaded, d2);
        return ParseFile(Path.Combine(d2, "presets.json"));
    }

    static JsonNode? Pick(Random rng, params object?[] values)
    {
        var v = values[rng.Next(values.Length)];
        return v is null ? null : JsonValue.Create(v switch { int i => (object)i, double x => x, bool b => b, string s => s, _ => throw new InvalidOperationException() });
    }

    public static JsonObject RandomSettings(Random rng, bool noisy)
    {
        var o = new JsonObject
        {
            ["taskId"] = Pick(rng, null, "document", "photos", "photoSheet", "future"),
            ["printerId"] = Pick(rng, null, "p1", "p2"),
            ["collate"] = Pick(rng, true, false),
            ["color"] = Pick(rng, "color", "gray"),
            ["quality"] = Pick(rng, "normal", "draft", "best"),
            ["sides"] = Pick(rng, "oneSided", "longEdge", "shortEdge"),
            ["pagesPerSheet"] = Pick(rng, 1, 1, 2, 4, 6, 9, 16, 3),
            ["booklet"] = Pick(rng, true, false, false),
            ["rightToLeft"] = Pick(rng, true, false),
            ["pageBorders"] = Pick(rng, true, false),
            ["scaling"] = Pick(rng, "shrinkToFit", "fit", "actualSize", "fill"),
            ["scale"] = Pick(rng, 100, 100, 50, 10, 400, 7),
            ["orientation"] = Pick(rng, "automatic", "portrait", "landscape"),
            ["margin"] = Pick(rng, "none", "printer", "normal", "custom", "small"),
            ["marginMm"] = Pick(rng, 10.0, 3.456, 0.05, 49.99, 80.0, -1.0, 12.0, 0.15),
            ["poster"] = Pick(rng, 0, 0, 2, 3, 4, 1),
            ["paperId"] = Pick(rng, "auto", "a4", "letter", "listed_sheet_100x150mm"),
            ["mediaSource"] = Pick(rng, "auto", "tray-2", "manual"),
            ["mediaType"] = Pick(rng, "auto", "photographic-glossy", "stationery"),
            ["photoSizeId"] = Pick(rng, "page", "page", "4x6", "5x7", "wallet", "nonsense"),
            ["cutMarks"] = Pick(rng, true, false),
        };
        if (rng.Next(6) == 0) o["layoutStyle"] = Pick(rng, "photoPrints", "photoSheet", "pages", "other");
        if (rng.Next(6) == 0) o["photoFill"] = Pick(rng, true, false);
        if (noisy)
        {
            var keys = o.Select(p => p.Key).ToList();
            for (int i = 0; i < 3; i++)
            {
                var key = keys[rng.Next(keys.Count)];
                o[key] = rng.Next(4) switch { 0 => null, 1 => JsonValue.Create("bogus"), 2 => JsonValue.Create(12345678901L), _ => JsonValue.Create(true) };
            }
        }
        return o;
    }

    static readonly string[] Fields = ["taskId", "printerId", "collate", "color", "quality", "sides", "pagesPerSheet", "booklet", "rightToLeft", "pageBorders",
        "scaling", "scale", "orientation", "margin", "marginMm", "poster", "paperId", "mediaSource", "mediaType", "photoSizeId", "cutMarks"];

    static JsonObject Prefs(Random rng) => new()
    {
        ["paperPath"] = new JsonObject { ["turnStackOver"] = Pick(rng, true, false), ["turnBacks"] = Pick(rng, true, false), ["checked"] = Pick(rng, true, false) },
        ["paperId"] = Pick(rng, null, "a4", "letter"),
        ["sides"] = Pick(rng, null, "oneSided", "longEdge"),
        ["color"] = Pick(rng, null, "color", "gray"),
        ["quality"] = Pick(rng, null, "best", "draft"),
        ["mediaSource"] = Pick(rng, null, "tray-2"),
        ["mediaType"] = Pick(rng, null, "stationery", "photographic"),
    };

    public static void Write(string path)
    {
        var rng = new Random(20261127);
        var o = new JsonObject();

        var texts = new List<string>
        {
            "{}", "[]", "null", "garbage", "{\"margin\": \"small\"}", "{\"marginMm\": 0.05}", "{\"marginMm\": 7}", "{\"marginMm\": 99}", "{\"marginMm\": -3}",
            "{\"layoutStyle\":\"photoPrints\",\"photoSizeId\":\"5x7\",\"photoFill\":false,\"margin\":\"small\"}",
            "{\"layoutStyle\":\"photoPrints\",\"photoFill\":true,\"pagesPerSheet\":4,\"sides\":\"longEdge\",\"booklet\":true,\"poster\":3}",
            "{\"layoutStyle\":\"photoSheet\",\"photoSizeId\":\"4x6\",\"sides\":\"longEdge\",\"poster\":2,\"margin\":\"normal\"}",
            "{\"layoutStyle\":\"pages\",\"photoSizeId\":\"4x6\",\"cutMarks\":true}",
            "{\"photoFill\":false,\"taskId\":\"photos\"}", "{\"photoFill\":true,\"taskId\":\"photoSheet\"}", "{\"photoFill\":true,\"taskId\":\"document\"}",
            "{\"photoFill\":true}", "{\"photoSizeId\":\"4x6\",\"cutMarks\":true}",
            "{\"sides\":\"diagonal\",\"color\":\"gray\",\"scale\":\"big\"}", "{\"sides\":\"LongEdge\"}", "{\"sides\":2}", "{\"pagesPerSheet\":2.5}",
            "{\"collate\":null,\"scale\":null}", "{\"unknownKey\":1,\"scale\":200}", "﻿{\"scale\":150}",
            "{\"copies\":5,\"pageSelection\":\"odd\",\"reverseOrder\":true}", "{\"scale\":9999999999}", "{\"printerId\":\"x\",\"taskId\":\"newTask\"}",
            "{\"margin\":\"custom\",\"marginMm\":3.456}",
        };
        for (int i = 0; i < 70; i++) texts.Add(RandomSettings(rng, i % 3 == 2).ToJsonString());
        var load = new JsonArray();
        foreach (var t in texts)
            load.Add(new JsonObject { ["input"] = t, ["output"] = LoadSettings(t, out _) });
        o["load"] = load;

        var same = new JsonArray();
        for (int i = 0; i < 160; i++)
        {
            var s = RandomSettings(rng, false);
            s.Remove("layoutStyle"); s.Remove("photoFill");
            var p = (JsonObject)s.DeepClone();
            int changes = rng.Next(4);
            for (int c = 0; c < changes; c++)
            {
                var other = RandomSettings(rng, false);
                var f = Fields[rng.Next(Fields.Length)];
                p[f] = other[f]?.DeepClone();
            }
            if (rng.Next(3) == 0) p["taskId"] = "document";
            string[] sel = ["all", "odd", "even"];
            var pe = new JsonObject { ["copies"] = rng.Next(3) == 0 ? 3 : 1, ["pageSelection"] = sel[rng.Next(rng.Next(4) == 0 ? 3 : 1)], ["reverseOrder"] = rng.Next(5) == 0 };
            var se = new JsonObject { ["copies"] = rng.Next(5) == 0 ? 2 : 1, ["pageSelection"] = sel[rng.Next(rng.Next(5) == 0 ? 3 : 1)], ["reverseOrder"] = rng.Next(6) == 0 };
            LoadSettings(p.ToJsonString(), out var presetS);
            LoadSettings(s.ToJsonString(), out var settingsS);
            void Apply(PrintSettings x, JsonObject e)
            {
                x.Copies = e["copies"]!.GetValue<int>();
                x.PageSelection = Enum.Parse<PageSelection>(e["pageSelection"]!.GetValue<string>(), true);
                x.ReverseOrder = e["reverseOrder"]!.GetValue<bool>();
            }
            Apply(presetS!, pe); Apply(settingsS!, se);
            same.Add(new JsonObject { ["preset"] = p, ["presetRuntime"] = pe, ["settings"] = s, ["settingsRuntime"] = se, ["same"] = PrintSettings.SameInUse(presetS!, settingsS!) });
        }
        o["sameInUse"] = same;

        var used = new JsonArray();
        for (int i = 0; i < 24; i++)
        {
            var s = RandomSettings(rng, false); s.Remove("layoutStyle"); s.Remove("photoFill");
            LoadSettings(s.ToJsonString(), out var ps);
            bool noQ = rng.Next(2) == 0, gray = rng.Next(2) == 0;
            var printer = new PrinterCapabilities { PrintQualitySupported = noQ ? [] : [4], PrintColorModesSupported = gray ? ["monochrome"] : ["color", "monochrome"] };
            var u = ps!.Used(printer);
            used.Add(new JsonObject { ["settings"] = s, ["noQuality"] = noQ, ["grayOnly"] = gray, ["quality"] = Camel(u.Quality), ["color"] = Camel(u.Color) });
        }
        o["used"] = used;

        var printers = new JsonArray();
        foreach (var t in new[] { "{}", "[]", "garbage", "{\"a\":{}}", "{\"a\":{\"paperPath\":{\"turnBacks\":true},\"paperId\":\"a4\",\"sides\":\"weird\"}}", "{\"a\":{\"paperPath\":null,\"color\":5}}" })
            printers.Add(new JsonObject { ["input"] = t, ["output"] = LoadPrinters(t) });
        for (int i = 0; i < 12; i++)
        {
            var obj = new JsonObject { ["p1"] = Prefs(rng), ["p2"] = Prefs(rng) };
            printers.Add(new JsonObject { ["input"] = obj.ToJsonString(), ["output"] = LoadPrinters(obj.ToJsonString()) });
        }
        o["printers"] = printers;

        var prefApply = new JsonArray();
        for (int i = 0; i < 24; i++)
        {
            var prefs = Prefs(rng);
            var s = RandomSettings(rng, false); s.Remove("layoutStyle"); s.Remove("photoFill");
            LoadPrinters(new JsonObject { ["p"] = prefs.DeepClone() }.ToJsonString());
            var d = Roundtrip("printers.json", new JsonObject { ["p"] = prefs.DeepClone() }.ToJsonString());
            var pp = Call<Dictionary<string, PrinterPrefs>>("LoadPrinters", d)["p"];
            LoadSettings(s.ToJsonString(), out var ps);
            var copy = ps! with { };
            pp.ApplyTo(copy);
            var rem = pp.Remembering(ps!);
            var d3 = Dir();
            Call<object>("SavePrinters", new Dictionary<string, PrinterPrefs> { ["p"] = rem }, d3);
            var d4 = Dir();
            Call<object>("Save", copy, d4);
            prefApply.Add(new JsonObject { ["prefs"] = prefs, ["settings"] = s, ["applied"] = ParseFile(Path.Combine(d4, "settings.json")),
                ["remembered"] = ParseFile(Path.Combine(d3, "printers.json"))!["p"]!.DeepClone() });
        }
        o["prefs"] = prefApply;

        var presets = new JsonArray();
        foreach (var t in new[]
        {
            "[]", "{}", "null", "[null]", "[1]", "[{}]", "[{\"name\":\"  \"}]", "[{\"name\":\"A\",\"settings\":{\"scale\":50}}]",
            "[{\"name\": \"Prints\", \"settings\": {\"layoutStyle\": \"photoPrints\", \"photoSizeId\": \"5x7\", \"photoFill\": false, \"margin\": \"small\"}}]",
            "[{\"name\":\"B\",\"settings\":null},{\"name\":\"C\",\"settings\":{\"sides\":\"bad\"}}]",
        })
            presets.Add(new JsonObject { ["input"] = t, ["output"] = LoadPresets(t) });
        o["loadPresets"] = presets;

        var builtIn = TaskCatalog.All.Select(d => d.Title).ToList();
        o["builtInNames"] = new JsonArray(builtIn.Select(n => (JsonNode)n).ToArray());
        var existing = new List<UserPreset> { new() { Name = "Mine" }, new() { Name = "Other Thing" } };
        var checks = new JsonArray();
        foreach (var (name, renaming) in new (string?, string?)[] { (null, null), ("", null), ("  ", null), ("Mine", null), (" mine ", null), ("MINE", "Mine"), ("Mine", "Other Thing"), ("Fresh", null), ("Two-sided", null), ("TWO-SIDED", "Mine"), ("Booklet", "Booklet") })
            checks.Add(new JsonObject { ["name"] = name, ["renaming"] = renaming, ["result"] = Camel(UserPresets.Check(name, existing, renaming)) });
        o["names"] = new JsonObject { ["existing"] = new JsonArray(existing.Select(p => (JsonNode)p.Name).ToArray()), ["checks"] = checks };

        var make = new JsonArray();
        for (int i = 0; i < 20; i++)
        {
            var s = RandomSettings(rng, false); s.Remove("layoutStyle"); s.Remove("photoFill");
            var cur = RandomSettings(rng, false); cur.Remove("layoutStyle"); cur.Remove("photoFill");
            LoadSettings(s.ToJsonString(), out var ps);
            LoadSettings(cur.ToJsonString(), out var cs);
            ps!.Copies = 5; ps.ReverseOrder = true; ps.PageSelection = PageSelection.Odd;
            cs!.Copies = 7; cs.PageSelection = PageSelection.Even;
            var preset = UserPresets.Make("  Name " + i + " ", ps);
            var applied = UserPresets.Apply(preset, cs);
            var d = Dir();
            Call<object>("Save", preset.Settings, d);
            var d2 = Dir();
            Call<object>("Save", applied, d2);
            make.Add(new JsonObject
            {
                ["name"] = "  Name " + i + " ", ["settings"] = s, ["current"] = cur,
                ["madeName"] = preset.Name, ["made"] = ParseFile(Path.Combine(d, "settings.json")),
                ["madeRuntime"] = new JsonObject { ["copies"] = preset.Settings.Copies, ["reverseOrder"] = preset.Settings.ReverseOrder, ["pageSelection"] = Camel(preset.Settings.PageSelection) },
                ["applied"] = ParseFile(Path.Combine(d2, "settings.json")),
                ["appliedRuntime"] = new JsonObject { ["copies"] = applied.Copies, ["reverseOrder"] = applied.ReverseOrder, ["pageSelection"] = Camel(applied.PageSelection) },
                ["matches"] = UserPresets.Matches(preset, cs), ["matchesSelf"] = UserPresets.Matches(preset, applied),
            });
        }
        o["presets"] = make;

        File.WriteAllText(path, o.ToJsonString() + "\n");
        Console.WriteLine("settings written");
    }
}

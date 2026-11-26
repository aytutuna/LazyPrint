using System.Text.Json.Nodes;
using LazyPrint.Core;
using static LayoutGen;

static class PaperGen
{
    static JsonNode? Sz(LayoutSize? s) => s is { } z ? Arr(z.Width, z.Height) : null;
    static JsonArray Strs(IEnumerable<string> v) { var a = new JsonArray(); foreach (var s in v) a.Add(s); return a; }

    public static JsonArray Attrs(IEnumerable<IppAttribute> list)
    {
        var a = new JsonArray();
        foreach (var attr in list)
        {
            var values = new JsonArray();
            foreach (var v in attr.Values)
                values.Add(v switch
                {
                    IppValue.Integer i => new JsonObject { ["integer"] = i.Value },
                    IppValue.Keyword k => new JsonObject { ["keyword"] = k.Value },
                    IppValue.Collection c => new JsonObject { ["collection"] = Attrs(c.Members) },
                    _ => new JsonObject { ["other"] = v.GetType().Name },
                });
            a.Add(new JsonObject { ["name"] = attr.Name, ["values"] = values });
        }
        return a;
    }

    public static JsonObject MediaJson(PrinterCapabilities p)
    {
        JsonArray Entries(IEnumerable<MediaEntry> list)
        {
            var a = new JsonArray();
            foreach (var e in list)
                a.Add(new JsonObject
                {
                    ["width"] = e.Width, ["height"] = e.Height, ["isVariable"] = e.IsVariable,
                    ["margins"] = e.Margins is { } m ? Arr(m.Top, m.Left, m.Bottom, m.Right) : null,
                    ["type"] = e.Type, ["source"] = e.Source,
                    ["attributes"] = Attrs(e.Attributes),
                });
            return a;
        }
        return new JsonObject
        {
            ["mediaColDatabase"] = Entries(p.MediaColDatabase), ["mediaColReady"] = Entries(p.MediaColReady),
            ["mediaReady"] = Strs(p.MediaReady), ["mediaSupported"] = Strs(p.MediaSupported),
            ["customPaper"] = p.CustomPaper is { } r ? Arr(r.MinWidth, r.MaxWidth, r.MinHeight, r.MaxHeight) : null,
        };
    }

    static MediaEntry E(double wMm, double hMm, int[]? margins, string? type = null, bool variable = false) =>
        new([], (int)(wMm * 100), (int)(hMm * 100), variable,
            margins is { } m ? new MediaMargins(m[0], m[1], m[2], m[3]) : null, type, null);

    public static List<PrinterCapabilities> Printers() =>
    [
        new PrinterCapabilities(),
        new PrinterCapabilities
        {
            MediaColDatabase = [E(210, 297, [423, 423, 423, 423]), E(210, 297, [0, 0, 0, 0], "photographic-glossy"), E(279.4, 431.8, [300, 300, 300, 300]),
                E(100, 150, [0, 0, 0, 0]), E(101.6, 152.4, [0, 0, 0, 0], "stationery"), E(50, 50, null), E(90, 140, [100, 100, 100, 100], variable: true)],
            MediaColReady = [E(210, 297, [423, 423, 423, 423])],
            MediaReady = ["iso_a4_210x297mm"],
            MediaSupported = ["iso_a4_210x297mm", "na_letter_8.5x11in", "om_small-photo_100x150mm", "custom_min_89x127mm", "custom_max_330x1200mm", "iso_a3_297x420mm"],
            CustomPaper = new PaperRange(8900, 33000, 12700, 120000),
        },
        new PrinterCapabilities
        {
            MediaColReady = [E(215.9, 279.4, [635, 635, 635, 635])],
            MediaColDatabase = [E(215.9, 279.4, [635, 635, 635, 635]), E(215.9, 279.4, [0, 0, 0, 0], "stationery-inkjet"), E(215.9, 279.4, [0, 0, 0, 0], "bond")],
            MediaReady = ["na_letter_8.5x11in"],
            MediaSupported = ["na_letter_8.5x11in", "na_legal_8.5x14in", "na_5x7_5x7in", "na_number-10_4.125x9.5in", "A4", "Custom.300x500", "w288h432", "weird"],
        },
        new PrinterCapabilities { MediaReady = ["jpn_hagaki_100x148mm"], MediaSupported = ["iso_a5_148x210mm", "iso_b5_176x250mm"] },
    ];

    public static void Write(string path)
    {
        var o = new JsonObject();
        var cat = new JsonArray();
        foreach (var s in PaperSizes.All)
            cat.Add(new JsonObject { ["raw"] = s.RawValue, ["pwg"] = s.Pwg, ["label"] = s.Label, ["group"] = Camel(s.Group), ["psk"] = s.Psk,
                ["detail"] = s.Detail, ["points"] = Sz(PaperSizes.Points(s)) });
        o["catalogue"] = cat;
        o["letterRegions"] = Strs(PaperSizes.LetterRegions);
        o["groupLabels"] = new JsonArray(Enum.GetValues<PaperGroup>().Select(g => (JsonNode)new JsonObject { ["group"] = Camel(g), ["label"] = PaperSizes.GroupLabel(g) }).ToArray());

        var parse = new JsonArray();
        foreach (var t in new[] { "a4", " A4 ", "LETTER", "b5Jis", "idCard", "unknown", "", "auto", "photo4x6" })
            parse.Add(new JsonObject { ["in"] = t, ["raw"] = PaperSizes.Parse(t).RawValue });
        o["parse"] = parse;

        string?[] regions = ["US", "ca", " mx ", "GB", "", null, "TR", "pr"];
        var regs = new JsonArray();
        foreach (var r in regions)
            regs.Add(new JsonObject
            {
                ["region"] = r, ["default"] = PaperSizes.DefaultForRegion(r).RawValue, ["usesInches"] = PaperSizes.UsesInches(r),
                ["common"] = Strs(PaperSizes.CommonFor(r).Select(s => s.RawValue)), ["order"] = Strs(PaperSizes.DisplayOrder(r).Select(s => s.RawValue)),
            });
        o["regions"] = regs;

        var match = new JsonArray();
        foreach (var s in PaperSizes.All) if (PaperSizes.Points(s) is { } p)
            foreach (var d in new[] { 0.0, 3, -3, 3.7, 10 })
                foreach (bool flip in new[] { false, true })
                {
                    var pt = new LayoutSize(flip ? p.Height + d : p.Width + d, flip ? p.Width : p.Height + d);
                    match.Add(new JsonObject { ["points"] = Sz(pt), ["match"] = PaperSizes.Match(pt)?.RawValue, ["name"] = PaperSizes.NameOf(pt),
                        ["id"] = PaperSizes.IdFor(new LayoutSize(Math.Min(pt.Width, pt.Height), Math.Max(pt.Width, pt.Height))) });
                }
        match.Add(new JsonObject { ["points"] = Arr(0, 100), ["match"] = null, ["name"] = null, ["id"] = PaperSizes.IdFor(new LayoutSize(0, 100)) });
        o["match"] = match;

        var fits = new JsonArray();
        foreach (var s in new[] { PaperSize.A4, PaperSize.Letter, PaperSize.Auto, PaperSize.A3 })
            foreach (var a in new LayoutSize?[] { null, new(0, 0), new(595, 842), new(612, 792), new(500, 700), new(300, 300) })
                fits.Add(new JsonObject { ["size"] = s.RawValue, ["area"] = Sz(a), ["fits"] = PaperSizes.Fits(s, a) });
        o["fits"] = fits;

        var pwg = new JsonArray();
        foreach (var t in new[] { "iso_a4_210x297mm", "na_letter_8.5x11in", " iso_a3_297x420mm ", "custom_min_89x127mm", "custom_max_330x1200mm", "x", "a_b", "iso_a4_210x297", "a_b_0x5mm", "a_b_5mm", "a_b_axbmm", "a_b_1x2x3mm", "jpn_hagaki_100x148mm", "om_x_1e2x3e2mm", "a_b_-5x7in", "A4" })
            pwg.Add(new JsonObject { ["in"] = t, ["size"] = Sz(PaperSizes.PwgSize(t)), ["media"] = Sz(PaperSizes.MediaSize(t)) });
        foreach (var t in new[] { "A4", "Letter.Borderless", "EnvDL", "Custom.612x792", "w612h792", "Custom.8.5x11in", "w100x200mm", "Custom.5x10cm", "w1h1", "Custom.0x5", "Postcard", "4x6.FullBleed", "nope", "Folio", "FanFoldGermanLegal", "a4", "B5" })
            pwg.Add(new JsonObject { ["in"] = t, ["size"] = Sz(PaperSizes.PwgSize(t)), ["media"] = Sz(PaperSizes.MediaSize(t)) });
        o["names"] = pwg;

        var custom = new JsonArray();
        foreach (var names in new[]
        {
            new[] { "custom_min_89x127mm", "custom_max_330x1200mm" }, new[] { "custom_max_330x1200mm", "custom_min_89x127mm" },
            new[] { "custom_min_3.5x5in", "custom_max_13x19in" }, new[] { "custom_min_89x127mm" }, new[] { "custom_min_89x127mm", "custom_max_89x127mm" },
            new string[0], new[] { "custom_min_0x5mm", "custom_max_1x1mm" }, new[] { "iso_a4_210x297mm" },
        })
            custom.Add(new JsonObject { ["names"] = Strs(names), ["range"] = PaperSizes.CustomRange(names) is { } r ? Arr(r.MinWidth, r.MaxWidth, r.MinHeight, r.MaxHeight) : null });
        o["customRange"] = custom;

        var ids = new JsonArray();
        foreach (var id in new string?[] { null, "", "auto", "a4", " Letter ", "listed_sheet_100x150mm", "custom_sheet_90.5x120mm", "iso_a5_148x210mm", "garbage", "photo4x6" })
            ids.Add(new JsonObject { ["id"] = id, ["points"] = Sz(PaperSizes.PointsOf(id)), ["label"] = PaperSizes.LabelOf(id, "CA"), ["labelMetric"] = PaperSizes.LabelOf(id, "GB") });
        o["ids"] = ids;

        var dims = new JsonArray();
        foreach (var sz in new[] { new LayoutSize(612, 792), new LayoutSize(595.2756, 841.8898), new LayoutSize(283.46, 425.2) })
            foreach (var r in new string?[] { "US", "GB", null })
            {
                var (w, h) = PaperSizes.Dimensions(sz, r);
                dims.Add(new JsonObject { ["points"] = Sz(sz), ["region"] = r, ["dimensions"] = Arr(w, h), ["text"] = PaperSizes.DimensionText(sz, r) });
            }
        o["dimensions"] = dims;

        var printers = new JsonArray();
        var plist = Printers();
        for (int i = 0; i < plist.Count; i++)
        {
            var p = plist[i];
            var item = new JsonObject { ["media"] = MediaJson(p) };
            var listed = new JsonArray();
            foreach (var s in PaperSizes.Listed(p)) listed.Add(Arr(s.Width, s.Height));
            item["listed"] = listed;
            var supports = new JsonArray();
            foreach (var sz in new[] { new LayoutSize(595.2756, 841.8898), new LayoutSize(612, 792), new LayoutSize(288, 432), new LayoutSize(100, 100), new LayoutSize(400, 600) })
                supports.Add(new JsonObject { ["paper"] = Sz(sz), ["supports"] = PaperSizes.Supports(p, sz), ["listedName"] = PaperSizes.ListedName(p, sz),
                    ["customId"] = null });
            item["supports"] = supports;
            var matches = new JsonArray();
            foreach (var sz in new[] { new LayoutSize(595.2756, 841.8898), new LayoutSize(612, 792), new LayoutSize(283.46, 425.2), new LayoutSize(300, 300) })
                foreach (bool bl in new[] { false, true })
                    foreach (string? t in new string?[] { null, "auto", "stationery", "photographic-glossy", "bond" })
                    {
                        var m = p.Match(sz, bl, t);
                        matches.Add(new JsonObject { ["paper"] = Sz(sz), ["borderless"] = bl, ["type"] = t,
                            ["entry"] = m is { } e ? new JsonObject { ["width"] = e.Width, ["height"] = e.Height, ["type"] = e.Type, ["variable"] = e.IsVariable } : null,
                            ["area"] = m?.PrintableArea is { } pa ? AreaJson(pa) : null });
                    }
            item["match"] = matches;
            var choices = new JsonArray();
            foreach (var chosen in new string?[] { null, "auto", "a4", "letter", "listed_sheet_100x150mm", "custom_sheet_150x200mm", "iso_a5_148x210mm", "custom_sheet_99.9x99.9mm", "photo4x6" })
                foreach (var region in new[] { "US", "GB" })
                {
                    var c = PaperSizes.Choices(p, chosen, region);
                    var opts = new JsonArray();
                    foreach (var op in c.Options) opts.Add(new JsonObject { ["id"] = op.Id, ["label"] = op.Label, ["detail"] = op.Detail, ["group"] = op.Group });
                    choices.Add(new JsonObject { ["chosen"] = chosen, ["region"] = region, ["selected"] = c.Selected, ["options"] = opts,
                        ["startCustom"] = PaperSizes.StartCustom(p, chosen, region) });
                }
            item["choices"] = choices;
            var cids = new JsonArray();
            foreach (var (w, h, region) in new[] { (210.0, 297.0, "GB"), (297.0, 210.0, "GB"), (8.5, 11.0, "US"), (3.0, 4.0, "US"), (20.0, 5.0, "GB"), (500.0, 2000.0, "GB") })
                cids.Add(new JsonObject { ["width"] = w, ["height"] = h, ["region"] = region, ["id"] = PaperSizes.CustomSizeId(w, h, region, p) });
            item["customIds"] = cids;
            printers.Add(item);
        }
        o["printers"] = printers;
        File.WriteAllText(path, o.ToJsonString() + "\n");
        Console.WriteLine("paper written");
    }
}

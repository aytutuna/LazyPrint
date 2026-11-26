System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("en-CA");
var outDir = args[0];
Gen.Root = args.Length > 1 ? args[1] : Path.GetFullPath(Path.Combine(AppContext.BaseDirectory, "../../../../../.."));
Gen.Temp = Path.Combine(Path.GetTempPath(), "lp-gen-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(Gen.Temp);
try
{
    Directory.CreateDirectory(Path.Combine(outDir, "layout"));
    LayoutGen.Write(Path.Combine(outDir, "layout", "imposition.jsonl"));
    MiscGen.Write(Path.Combine(outDir, "layout", "misc.json"));
    Directory.CreateDirectory(Path.Combine(outDir, "paper"));
    PaperGen.Write(Path.Combine(outDir, "paper", "paper.json"));
    Directory.CreateDirectory(Path.Combine(outDir, "settings"));
    SettingsGen.Write(Path.Combine(outDir, "settings", "settings.json"));
    TasksGen.Write(Path.Combine(outDir, "settings", "tasks.json"));
    Directory.CreateDirectory(Path.Combine(outDir, "jobs"));
    JobsGen.Write(Path.Combine(outDir, "jobs", "jobs.json"));
}
finally
{
    Directory.Delete(Gen.Temp, true);
}

static class Gen { public static string Root = ""; public static string Temp = ""; }

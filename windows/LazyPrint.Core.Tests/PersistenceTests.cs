using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PersistenceTests.swift: the same cases. Settings files load
// across versions (CONTRACTS.md, Global rule 5), shown on a small settings type of the test's own.

public enum Tone { Plain, Loud }

public sealed class Inner
{
    public int Level { get; set; } = 3;
}

public sealed class Sample
{
    public string Name { get; set; } = "";
    public int Count { get; set; } = 1;
    public Tone Tone { get; set; } = Tone.Plain;
    public List<string> Tags { get; set; } = [];
    public Inner Inner { get; set; } = new();
}

public sealed class PersistenceTests : IDisposable
{
    private readonly string _directory;
    private static readonly byte[] Garbage = Encoding.UTF8.GetBytes("this is not JSON {");
    private const string Current = """{"name": "Office", "count": 4, "tone": "loud", "tags": ["a", "b"], "inner": {"level": 7}}""";

    public PersistenceTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private string FilePath => Path.Combine(_directory, "sample.json");

    private List<string> KeptFiles() =>
        [.. Directory.GetFiles(_directory)
            .Select(path => Path.GetFileName(path))
            .Where(name => name.StartsWith("sample.unreadable-", StringComparison.Ordinal))
            .Order(StringComparer.Ordinal)];

    private static void AssertCurrent(Sample sample)
    {
        Assert.Equal("Office", sample.Name);
        Assert.Equal(4, sample.Count);
        Assert.Equal(Tone.Loud, sample.Tone);
        Assert.Equal(["a", "b"], sample.Tags);
        Assert.Equal(7, sample.Inner.Level);
    }

    [Fact]
    public void DefaultDirectoryIsLazyPrintInTheRoamingFolder()
    {
        Assert.Equal(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Lazy Print"),
                     StoreFiles.DefaultDirectory);
    }

    [Fact]
    public void MissingFile_IsMissingAndKeepsNothing()
    {
        Assert.Equal(StoreReadStatus.Missing, StoreFiles.Read<Sample>(FilePath).Status);
        Assert.Null(StoreFiles.Load<Sample>(FilePath));
        Assert.Empty(KeptFiles());
    }

    [Fact]
    public void WriteThenLoad_RoundTripsWithCamelCaseKeys()
    {
        string nested = Path.Combine(_directory, "deeper", "sample.json");
        var sample = new Sample { Name = "Office", Count = 4, Tone = Tone.Loud, Tags = ["a", "b"], Inner = new Inner { Level = 7 } };

        Assert.True(StoreFiles.Write(sample, nested));

        string text = File.ReadAllText(nested);
        Assert.Contains("\"tone\": \"loud\"", text);
        Assert.Contains("\"level\": 7", text);
        AssertCurrent(StoreFiles.Load<Sample>(nested)!);
        Assert.False(File.Exists(nested + ".tmp"));
    }

    [Fact]
    public void UnknownValuesAndWrongTypes_ResetOnlyThatField()
    {
        File.WriteAllText(FilePath, """
            {"name": 12, "count": 9, "tone": "deafening", "tags": "x", "inner": {"level": "high"}, "future": [1, 2]}
            """);

        var sample = StoreFiles.Load<Sample>(FilePath)!;

        Assert.Equal("", sample.Name);
        Assert.Equal(9, sample.Count);
        Assert.Equal(Tone.Plain, sample.Tone);
        Assert.Empty(sample.Tags);
        Assert.Equal(3, sample.Inner.Level);
        Assert.Empty(KeptFiles());
    }

    [Fact]
    public void MissingKeysAndNulls_TakeTheDefaults()
    {
        File.WriteAllText(FilePath, """{"name": "Home", "count": null, "inner": null}""");

        var sample = StoreFiles.Load<Sample>(FilePath)!;

        Assert.Equal("Home", sample.Name);
        Assert.Equal(1, sample.Count);
        Assert.Equal(3, sample.Inner.Level);
    }

    [Fact]
    public void EnumsAreReadExactly()
    {
        foreach (string tone in new[] { "\"Loud\"", "\"LOUD\"", "1" })
        {
            File.WriteAllText(FilePath, $$"""{"tone": {{tone}}}""");
            Assert.Equal(Tone.Plain, StoreFiles.Load<Sample>(FilePath)!.Tone);
        }
    }

    [Fact]
    public void UndecodableFile_IsKeptAsideUnderATimestampedName()
    {
        File.WriteAllBytes(FilePath, Garbage);

        Assert.Null(StoreFiles.Load<Sample>(FilePath));

        string name = Assert.Single(KeptFiles());
        Assert.Matches(new Regex(@"^sample\.unreadable-\d{8}-\d{6}\.json$"), name);
        Assert.Equal(Garbage, File.ReadAllBytes(Path.Combine(_directory, name)));
        Assert.False(File.Exists(FilePath));
        // The next write is not refused, and the next load keeps nothing new.
        Assert.True(StoreFiles.Write(new Sample { Name = "Fresh" }, FilePath));
        Assert.Equal("Fresh", StoreFiles.Load<Sample>(FilePath)!.Name);
        Assert.Single(KeptFiles());
    }

    [Fact]
    public void WrongShapeFile_IsKept()
    {
        byte[] wrongShape = Encoding.UTF8.GetBytes("""{"hosts": ["192.168.1.50"]}""");
        File.WriteAllBytes(FilePath, wrongShape);

        Assert.Null(StoreFiles.Load<List<string>>(FilePath));

        string name = Assert.Single(KeptFiles());
        Assert.Equal(wrongShape, File.ReadAllBytes(Path.Combine(_directory, name)));
    }

    [Theory]
    [InlineData("null")]
    [InlineData("[null]")]
    public void NullDocuments_AreKept(string json)
    {
        File.WriteAllText(FilePath, json);

        Assert.Null(StoreFiles.Load<List<string>>(FilePath));

        string name = Assert.Single(KeptFiles());
        Assert.Equal(json, File.ReadAllText(Path.Combine(_directory, name)));
    }

    [Fact]
    public void TakenKeptName_GetsNumberedSuffix()
    {
        // Occupy the kept names (plain and -2) for this second and the next few, so the
        // load below finds them taken whenever it runs.
        var now = DateTime.Now;
        var taken = new List<string>();
        for (int second = 0; second <= 5; second++)
        {
            string stamp = now.AddSeconds(second).ToString("yyyyMMdd-HHmmss", CultureInfo.InvariantCulture);
            foreach (string name in new[] { $"sample.unreadable-{stamp}.json", $"sample.unreadable-{stamp}-2.json" })
            {
                File.WriteAllText(Path.Combine(_directory, name), "taken");
                taken.Add(name);
            }
        }
        File.WriteAllBytes(FilePath, Garbage);

        _ = StoreFiles.Load<Sample>(FilePath);

        string kept = Assert.Single(KeptFiles().Except(taken));
        Assert.Matches(new Regex(@"^sample\.unreadable-\d{8}-\d{6}-3\.json$"), kept);
        Assert.Equal(Garbage, File.ReadAllBytes(Path.Combine(_directory, kept)));
        Assert.All(taken, name => Assert.Equal("taken", File.ReadAllText(Path.Combine(_directory, name))));
    }

    [Fact]
    public void FileWithByteOrderMark_LoadsInPlace()
    {
        File.WriteAllBytes(FilePath, [0xEF, 0xBB, 0xBF, .. Encoding.UTF8.GetBytes(Current)]);

        AssertCurrent(StoreFiles.Load<Sample>(FilePath)!);
        Assert.Empty(KeptFiles());
    }

    // Notepad's "UTF-16 LE" and Windows PowerShell 5.1's Out-File write UTF-16 with a
    // byte-order mark; Swift's JSONDecoder also reads UTF-32 and UTF-16 without one.
    [Theory]
    [InlineData("utf-16", true)]
    [InlineData("utf-16BE", true)]
    [InlineData("utf-32", true)]
    [InlineData("utf-32BE", true)]
    [InlineData("utf-16", false)]
    [InlineData("utf-16BE", false)]
    [InlineData("utf-32", false)]
    [InlineData("utf-32BE", false)]
    public void FileInUtf16OrUtf32_LoadsInPlace(string encodingName, bool withByteOrderMark)
    {
        var encoding = Encoding.GetEncoding(encodingName);
        byte[] text = encoding.GetBytes(Current);
        File.WriteAllBytes(FilePath, withByteOrderMark ? [.. encoding.GetPreamble(), .. text] : text);

        AssertCurrent(StoreFiles.Load<Sample>(FilePath)!);
        Assert.Empty(KeptFiles());
    }

    [Fact]
    public void InvalidUtf16File_IsKept()
    {
        // A byte-order mark followed by an unpaired high surrogate inside a string.
        byte[] damaged = [0xFF, 0xFE, .. Encoding.Unicode.GetBytes("{\"name\": \""), 0x00, 0xD8, .. Encoding.Unicode.GetBytes("\"}")];
        File.WriteAllBytes(FilePath, damaged);

        Assert.Null(StoreFiles.Load<Sample>(FilePath));

        string name = Assert.Single(KeptFiles());
        Assert.Equal(damaged, File.ReadAllBytes(Path.Combine(_directory, name)));
    }

    // Swift's JSONDecoder takes a comma before a closing bracket; this reader does not, and the
    // Swift twin refuses it too, so neither app reads such a file.
    [Fact]
    public void TrailingComma_IsKept()
    {
        File.WriteAllText(FilePath, """{"tags": ["a",]}""");

        Assert.Null(StoreFiles.Load<Sample>(FilePath));
        Assert.Single(KeptFiles());
    }

    /// <summary>
    /// Keeps <paramref name="path"/> open with no sharing for the duration of <paramref name="body"/>,
    /// so reading it fails with an I/O error (the Windows counterpart of the Swift test's permission change).
    /// </summary>
    private static void WithoutReadAccess(string path, Action body)
    {
        using (new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None))
        {
            body();
        }
    }

    [Fact]
    public void InaccessibleFile_IsLeftInPlaceAndNotOverwritten()
    {
        Assert.True(StoreFiles.Write(new Sample { Name = "Office" }, FilePath));
        byte[] original = File.ReadAllBytes(FilePath);

        WithoutReadAccess(FilePath, () =>
        {
            Assert.Equal(StoreReadStatus.Inaccessible, StoreFiles.Read<Sample>(FilePath).Status);
            Assert.Null(StoreFiles.Load<Sample>(FilePath));
        });

        Assert.Empty(KeptFiles());
        Assert.Equal(original, File.ReadAllBytes(FilePath));
        // Writes stay refused for the session even once the file is readable again.
        Assert.False(StoreFiles.Write(new Sample { Name = "Other" }, FilePath));
        Assert.Equal(original, File.ReadAllBytes(FilePath));
    }

    [Fact]
    public void WriteFailure_ReportsFalse()
    {
        // A directory where the temporary file should go.
        Directory.CreateDirectory(FilePath + ".tmp");

        Assert.False(StoreFiles.Write(new Sample(), FilePath));
        Assert.False(File.Exists(FilePath));
    }

    [Fact]
    public void Decode_RejectsWhatIsNotTheType()
    {
        Assert.Throws<JsonException>(() => StoreFiles.Decode<Sample>("[1]"u8));
        Assert.Throws<JsonException>(() => StoreFiles.Decode<Sample>("null"u8));
    }
}

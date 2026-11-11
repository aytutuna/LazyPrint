using System.IO;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Windows.Threading;
using LazyPrint.App;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Xunit;
using ZXing;
using ZXing.Common;
using ZXing.QrCode;

namespace LazyPrint.App.Tests;

// What the app does with the files a phone sends: the batches the bar offers one at a time, adding them to the job or
// starting a new one, dismissing them, and asking before a phone pairs. The server itself is checked in
// LazyPrint.Core.Tests; here the files are put in the inbox as the server would, and nothing listens on a network.

internal sealed class NoNetworks : ICompanionNetworkSource
{
    public IReadOnlyList<CompanionNetwork> Networks() => [];

    public event EventHandler? Changed
    {
        add { }
        remove { }
    }
}

public sealed class PhoneLinkTests : IDisposable
{
    private static readonly byte[] Pdf = Encoding.ASCII.GetBytes("%PDF-1.7\n1 0 obj\n<< /Type /Catalog >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n");

    private readonly Rig _rig = new();
    private readonly string _mutex = @"Local\LazyPrint.PhoneLink.test-" + Guid.NewGuid().ToString("N");
    private readonly CompanionService _service;
    private readonly string _data;

    public PhoneLinkTests()
    {
        _rig.Model.CompanionMutexName = _mutex;
        _data = Path.Combine(_rig.Directory, "data");
        _service = _rig.Model.EnsureCompanion(Options(_rig))!;
    }

    public void Dispose() => _rig.Model.Shutdown();

    private CompanionServiceOptions Options(Rig rig) => new()
    {
        SettingsDirectory = rig.Directory,
        DataDirectory = Path.Combine(rig.Directory, "data"),
        Certificate = MakeCertificate,
        Networks = new NoNetworks(),
    };

    private static X509Certificate2 MakeCertificate()
    {
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        var request = new CertificateRequest("CN=Lazy Print test", key, HashAlgorithmName.SHA256);
        using var ephemeral = request.CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1), DateTimeOffset.UtcNow.AddDays(30));
        return X509CertificateLoader.LoadPkcs12(ephemeral.Export(X509ContentType.Pfx), null);
    }

    /// <summary>A package in the inbox as the server leaves it, then the bar told to look.</summary>
    private async Task Send(string batch, int index, int count, string name, string from = "Aytu's iPhone", DateTimeOffset? at = null)
    {
        byte[] package = PrintPackage.Make(name, "application/pdf", batch, index, count, from, Pdf);
        await _service.Inbox.ReceiveAsync("phone-0001", $"{batch}-{index}", new MemoryStream(package), package.Length,
                                          at ?? DateTimeOffset.UtcNow, CancellationToken.None);
        _rig.Model.RefreshPhoneBatches();
    }

    private static DateTimeOffset LongAgo => DateTimeOffset.UtcNow - CompanionInbox.BatchGrace - TimeSpan.FromSeconds(5);

    [Fact]
    public async Task ABatchThatIsOfferedStaysOfferedWhenAFileOfItArrivesLate()
    {
        await Send("batch-0001", 0, 3, "a.pdf", at: LongAgo);
        Assert.Equal("1 file from Aytu's iPhone", _rig.Model.PhoneBatchMessage);

        await Send("batch-0001", 1, 3, "b.pdf");

        Assert.Equal("2 files from Aytu's iPhone", _rig.Model.PhoneBatchMessage);
    }

    [Fact]
    public async Task ABatchThatIsOfferedKeepsItsPlaceWhenAFileOfItArrivesLate()
    {
        await Send("batch-0001", 0, 2, "a.pdf", at: LongAgo);
        await Send("batch-0002", 0, 1, "b.pdf", "Ela's iPhone", LongAgo.AddSeconds(1));
        Assert.Equal("1 file from Aytu's iPhone", _rig.Model.PhoneBatchMessage);

        await Send("batch-0001", 1, 2, "c.pdf");

        Assert.Equal("2 files from Aytu's iPhone", _rig.Model.PhoneBatchMessage);
        Assert.Equal("batch-0001", _rig.Model.PhoneBatch?.Id);
    }

    [Fact]
    public async Task ABatchIsOfferedOnlyOnceItIsWhole()
    {
        int arrived = 0;
        _rig.Model.PhoneFilesArrived += () => arrived++;

        await Send("batch-0001", 0, 2, "a.pdf");
        Assert.Null(_rig.Model.PhoneBatchMessage);
        Assert.Equal(0, arrived);

        await Send("batch-0001", 1, 2, "b.pdf");
        Assert.Equal("2 files from Aytu's iPhone", _rig.Model.PhoneBatchMessage);
        Assert.Equal(1, arrived);
    }

    [Fact]
    public async Task OneFileIsNotPlural()
    {
        await Send("batch-0001", 0, 1, "a.pdf");

        Assert.Equal("1 file from Aytu's iPhone", _rig.Model.PhoneBatchMessage);
    }

    [Fact]
    public async Task BatchesQueueBehindTheBarOneAtATime()
    {
        await Send("batch-0001", 0, 1, "a.pdf", "Aytu's iPhone");
        await Send("batch-0002", 0, 1, "b.pdf", "Ela's iPhone");

        Assert.Equal("1 file from Aytu's iPhone", _rig.Model.PhoneBatchMessage);
        _rig.Model.DismissPhoneBatch();
        Assert.Equal("1 file from Ela's iPhone", _rig.Model.PhoneBatchMessage);
        _rig.Model.DismissPhoneBatch();
        Assert.Null(_rig.Model.PhoneBatchMessage);
    }

    [Fact]
    public async Task DismissingDeletesTheFiles()
    {
        await Send("batch-0001", 0, 1, "a.pdf");
        _rig.Model.DismissPhoneBatch();

        Assert.DoesNotContain(Directory.GetFiles(_data, "*", SearchOption.AllDirectories), f => f.EndsWith(".pdf") || f.EndsWith(".lppkg"));
        Assert.Empty(_rig.Model.Documents);
    }

    [Fact]
    public async Task AddingPutsTheFilesInTheJobAfterTheOthersAndPrintsNothing()
    {
        await _rig.Model.AddFilesAsync([@"C:\Docs\first.pdf"]);
        await Send("batch-0001", 0, 2, "a.pdf");
        await Send("batch-0001", 1, 2, "b.pdf");

        Assert.True(await _rig.Model.UsePhoneBatchAsync(startNew: false));

        Assert.Equal(["first.pdf", "a.pdf", "b.pdf"], _rig.Model.Documents.Select(d => d.Name));
        Assert.Equal(PrintTask.Document, _rig.Model.SelectedTask);
        Assert.Null(_rig.Model.PhoneBatchMessage);
        Assert.Empty(_rig.Sheets.Passes);
    }

    [Fact]
    public async Task StartingANewJobClearsTheJobFirst()
    {
        await _rig.Model.AddFilesAsync([@"C:\Docs\first.pdf"]);
        _rig.Model.SetPageRange("1-2");
        await Send("batch-0001", 0, 1, "a.pdf");

        Assert.True(await _rig.Model.UsePhoneBatchAsync(startNew: true));

        Assert.Equal(["a.pdf"], _rig.Model.Documents.Select(d => d.Name));
        Assert.Equal("", _rig.Model.PageRangeText);
        Assert.Empty(_rig.Sheets.Passes);
    }

    [Fact]
    public async Task AFileThatCannotBeReadIsReportedAndTheOthersGoIn()
    {
        await Send("batch-0001", 0, 2, "a.pdf");
        await Send("batch-0001", 1, 2, "b.bad");

        Assert.True(await _rig.Model.UsePhoneBatchAsync(startNew: false));

        Assert.Equal(["a.pdf"], _rig.Model.Documents.Select(d => d.Name));
        Assert.Equal("Not added", _rig.Model.ErrorTitle);
    }

    [Fact]
    public async Task StartingANewJobKeepsTheJobWhenNothingInTheBatchOpens()
    {
        await _rig.Model.AddFilesAsync([@"C:\Docs\first.pdf"]);
        _rig.Model.SetPageRange("1");
        await Send("batch-0001", 0, 1, "a.bad");

        Assert.False(await _rig.Model.UsePhoneBatchAsync(startNew: true));

        Assert.Equal(["first.pdf"], _rig.Model.Documents.Select(d => d.Name));
        Assert.Equal("1", _rig.Model.PageRangeText);
        Assert.Equal("Not added", _rig.Model.ErrorTitle);
        Assert.Contains("a.bad", _rig.Model.ErrorMessage);
    }

    [Fact]
    public async Task AFileOfANewJobThatCannotBeReadIsReportedAndTheOthersReplaceTheJob()
    {
        await _rig.Model.AddFilesAsync([@"C:\Docs\first.pdf"]);
        await Send("batch-0001", 0, 2, "a.pdf");
        await Send("batch-0001", 1, 2, "b.bad");

        Assert.True(await _rig.Model.UsePhoneBatchAsync(startNew: true));

        Assert.Equal(["a.pdf"], _rig.Model.Documents.Select(d => d.Name));
        Assert.Equal("Not added", _rig.Model.ErrorTitle);
        Assert.Contains("b.bad", _rig.Model.ErrorMessage);
    }

    [Fact]
    public async Task ASyncFolderProblemIsPutInTheMainWindowsBarToo()
    {
        _rig.Model.ReportSyncProblem("Report.pdf in the cloud folder could not be read.");

        Assert.Equal("Phone sync", _rig.Model.ErrorTitle);
        Assert.True(_rig.Model.ErrorIsNotice);
        Assert.Equal("Report.pdf in the cloud folder could not be read.", _rig.Model.ErrorMessage);
        Assert.Equal(_rig.Model.ErrorMessage, _rig.Model.SyncFolderProblem);

        await _rig.Model.AddFilesAsync(["a.bad"]);
        _rig.Model.ReportSyncProblem("Another file could not be read.");

        Assert.Equal("Not added", _rig.Model.ErrorTitle);
        Assert.Equal("Another file could not be read.", _rig.Model.SyncFolderProblem);
    }

    [Fact]
    public async Task AFileThatCannotBeMovedIsReportedAndTheOthersGoIn()
    {
        await Send("batch-0001", 0, 2, "a.pdf");
        await Send("batch-0001", 1, 2, "b.pdf");
        Directory.CreateDirectory(Path.Combine(_data, "Inbox", "batch-0001", "a.pdf"));

        Assert.True(await _rig.Model.UsePhoneBatchAsync(startNew: false));

        Assert.Equal(["b.pdf"], _rig.Model.Documents.Select(d => d.Name));
        Assert.Equal("Not added", _rig.Model.ErrorTitle);
    }

    [Fact]
    public async Task DismissingABatchDeletesItEvenWhenItsFilesCannotBeMoved()
    {
        await Send("batch-0001", 0, 1, "a.pdf");
        await Send("batch-0002", 0, 1, "b.pdf");
        Directory.CreateDirectory(Path.Combine(_data, "Inbox", "batch-0001", "a.pdf"));

        _rig.Model.DismissPhoneBatch();

        Assert.Equal("1 file from Aytu's iPhone", _rig.Model.PhoneBatchMessage);
        Assert.False(File.Exists(Path.Combine(_data, "Inbox", "phone-0001", "batch-0001-0.lppkg")));
    }

    [Fact]
    public async Task AClickWhileABatchIsBeingTakenDoesNothing()
    {
        await Send("batch-0001", 0, 1, "a.pdf");
        await _rig.Model.AddFilesAsync([@"C:\Docs\first.pdf"]);

        var first = _rig.Model.UsePhoneBatchAsync(startNew: false);
        bool second = await _rig.Model.UsePhoneBatchAsync(startNew: true);

        Assert.False(second);
        Assert.True(await first);
        Assert.Equal(["first.pdf", "a.pdf"], _rig.Model.Documents.Select(d => d.Name));
    }

    [Fact]
    public async Task ABatchWaitsWhileAJobRuns()
    {
        await Send("batch-0001", 0, 1, "a.pdf");
        var printing = new TaskCompletionSource();
        _rig.Sheets.While = (_, _, _) => printing.Task;
        _rig.Model.Settings.PrinterId = PrinterMerge.DemoId;
        await _rig.Model.RefreshPrintersAsync();
        await _rig.Model.AddFilesAsync([@"C:\Docs\first.pdf"]);
        var job = _rig.Model.PrintAsync();

        Assert.False(await _rig.Model.UsePhoneBatchAsync(startNew: true));
        Assert.Single(_rig.Model.Documents);
        Assert.NotNull(_rig.Model.PhoneBatchMessage);

        printing.SetResult();
        await job;
    }

    [Fact]
    public void ForgettingAPhoneTakesItsWaitingBatchOffTheBar()
    {
        byte[] package = PrintPackage.Make("a.pdf", "application/pdf", "batch-0001", 0, 1, "Aytu's iPhone", Pdf);
        Task.Run(() => _service.Inbox.ReceiveAsync("phone-0001", "batch-0001-0", new MemoryStream(package), package.Length,
                                                   DateTimeOffset.UtcNow, CancellationToken.None)).Wait();
        _rig.Model.RefreshPhoneBatches();
        Assert.NotNull(_rig.Model.PhoneBatchMessage);

        // The link reports the change from a server thread; the UI thread (this one) handles it.
        var frame = new DispatcherFrame();
        var ui = Dispatcher.CurrentDispatcher;
        Task.Run(() => _service.RemoveDeviceAsync("phone-0001")).ContinueWith(_ =>
            ui.BeginInvoke(DispatcherPriority.Background, () => frame.Continue = false));
        Dispatcher.PushFrame(frame);

        Assert.Null(_rig.Model.PhoneBatchMessage);
    }

    [Fact]
    public void AnotherWindowOfTheAppHoldsTheLink()
    {
        // A mutex is owned per thread, so the first window is stood in for by a thread that holds it until the end.
        string name = _mutex + "-held";
        using var held = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        var holder = new Thread(() =>
        {
            using var mutex = new Mutex(false, name);
            mutex.WaitOne();
            held.Set();
            release.Wait();
            mutex.ReleaseMutex();
        });
        holder.Start();
        held.Wait();
        using var other = new Rig();
        other.Model.CompanionMutexName = name;

        bool elsewhere = other.Model.EnsureCompanion(Options(other)) is null && other.Model.CompanionElsewhere;
        release.Set();
        holder.Join();

        Assert.True(elsewhere);
    }

    [Fact]
    public void APhoneThatPresentsTheCodeIsAskedAboutAndDeclinedWhenNobodyIsThere()
    {
        var request = new PairRequest("token", "phone-0001", "Aytu's iPhone", "ios", "1.0");
        PairRequest? asked = null;

        Assert.False(Approve(request));
        _rig.Model.ConfirmPhonePairing = (r, _) =>
        {
            asked = r;
            return Task.FromResult(true);
        };
        Assert.True(Approve(request));
        Assert.Equal("Aytu's iPhone", asked?.PhoneName);
    }

    /// <summary>The router asks from a server thread; the UI thread (this one) answers while it waits.</summary>
    private bool Approve(PairRequest request)
    {
        var frame = new DispatcherFrame();
        var answer = Task.Run(() => _service.Router.ApprovePairing(request, CancellationToken.None))
                         .ContinueWith(task =>
                         {
                             frame.Continue = false;
                             return task.Result;
                         });
        Dispatcher.PushFrame(frame);
        return answer.Result;
    }

    [Fact]
    public void ThePairingCodeIsAQrCodeThatReadsBack()
    {
        string text = "lazyprint://pair?v=1&n=Aytu%27s%20PC&p=52732";
        var modules = new ZXingQrEncoder().Encode(text)!;
        Assert.Equal(0, (modules.Size - 17) % 4);
        Assert.True(modules[0, 0] && modules[modules.Size - 1, 0] && modules[0, modules.Size - 1]);

        const int quiet = 4, scale = 4;
        int side = (modules.Size + 2 * quiet) * scale;
        var gray = Enumerable.Repeat((byte)255, side * side).ToArray();
        for (int y = 0; y < side; y++)
        {
            for (int x = 0; x < side; x++)
            {
                int mx = x / scale - quiet, my = y / scale - quiet;
                if (mx >= 0 && my >= 0 && mx < modules.Size && my < modules.Size && modules[mx, my]) gray[y * side + x] = 0;
            }
        }
        var source = new RGBLuminanceSource(gray, side, side, RGBLuminanceSource.BitmapFormat.Gray8);
        var result = new QRCodeReader().decode(new BinaryBitmap(new HybridBinarizer(source)));
        Assert.Equal(text, result?.Text);
    }

    [Fact]
    public void NoTextMakesNoQrCode()
    {
        Assert.Null(new ZXingQrEncoder().Encode(""));
    }

    [Fact]
    public void ALazyPrintAddressOnTheCommandLineStandsForItsFiles()
    {
        string url = "lazyprint:open?file=" + Uri.EscapeDataString(@"C:\Temp\scan 1.pdf") + "&file=" + Uri.EscapeDataString(@"C:\Temp\scan 2.pdf");

        Assert.Equal([@"C:\Temp\scan 1.pdf", @"C:\Temp\scan 2.pdf"], LazyPrint.App.App.FilesOf([url]));
        Assert.Equal([@"C:\Docs\a.pdf", @"C:\Temp\scan 1.pdf", @"C:\Docs\b.pdf"], LazyPrint.App.App.FilesOf([@"C:\Docs\a.pdf", url.Split('&')[0], @"C:\Docs\b.pdf"]));
    }

    [Theory]
    [InlineData(@"\\server\share\a.pdf")]
    [InlineData(@"\\?\C:\a.pdf")]
    [InlineData(@"\\?\UNC\server\share\a.pdf")]
    [InlineData(@"\\.\pipe\x")]
    public void AUncOrDevicePathInTheAddressIsDropped(string path)
    {
        Assert.Empty(LazyPrint.App.App.FilesOf(["lazyprint:open?file=" + Uri.EscapeDataString(path)]));
    }

    [Fact]
    public void AnAddressWithAQuoteInItCannotAddArguments()
    {
        // The scheme's command is "exe" "%1": this address reaches the program as two arguments.
        string[] split = [@"lazyprint:x", @"\\evil\share\a.pdf"];
        string[] fromOpen = ["lazyprint:open?file=" + Uri.EscapeDataString(@"C:\Temp\a.pdf"), @"\\evil\share\a.pdf"];

        Assert.Empty(LazyPrint.App.App.FilesOf(split));
        Assert.Empty(LazyPrint.App.App.FilesOf([" lazyprint:x", @"\\evil\share\a.pdf"]));
        Assert.Equal([@"C:\Temp\a.pdf"], LazyPrint.App.App.FilesOf(fromOpen));
    }

    [Fact]
    public void AnAddressThatIsNotOpenFilesStandsForNone()
    {
        Assert.Empty(LazyPrint.App.App.FilesOf(["lazyprint:"]));
        Assert.Empty(LazyPrint.App.App.FilesOf(["LazyPrint:other?file=C%3A%5Ca.pdf"]));
    }
}

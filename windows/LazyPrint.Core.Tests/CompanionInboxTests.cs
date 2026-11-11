using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/CompanionInboxTests.swift (same cases).

public sealed class CompanionInboxTests : IDisposable
{
    private const string Phone = "phone-0001";
    private readonly string _root = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
    private readonly CompanionInbox _inbox;
    private readonly DateTimeOffset _start = new(2026, 11, 2, 9, 0, 0, TimeSpan.Zero);

    public CompanionInboxTests()
    {
        _inbox = new CompanionInbox(Path.Combine(_root, "Inbox")) { FreeSpace = _ => long.MaxValue };
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_root, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private Task<ReceivedPackage> Receive(string packageId, byte[] package, DateTimeOffset when, string device = Phone) =>
        _inbox.ReceiveAsync(device, packageId, new MemoryStream(package), package.Length, when, CancellationToken.None);

    private Task<ReceivedPackage> Send(string packageId, string batch, int index, int count, string name, DateTimeOffset when,
                                       string device = Phone) =>
        Receive(packageId, CompanionFixtures.Package(batch, index, count, name), when, device);

    [Fact]
    public async Task ReceivedPackage_IsKeptAndLoggedByItsId()
    {
        var received = await Send("package-0001", "batch-0001", 0, 1, "Report.pdf", _start);
        Assert.Equal(Path.Combine(_root, "Inbox", Phone, "package-0001.lppkg"), received.Path);
        Assert.Equal("Report.pdf", received.Info.Name);
        Assert.True(File.Exists(received.Path));
        Assert.Empty(Directory.GetFiles(Path.Combine(_root, "Inbox", Phone), "*.part"));
        Assert.Equal(_start, _inbox.Find(Phone, "package-0001")?.Received);
        Assert.Null(_inbox.Find(Phone, "package-0002"));
        Assert.Null(_inbox.Find("phone-0002", "package-0001"));
    }

    [Fact]
    public async Task ReceivedPackage_StaysLoggedAfterItsBatchIsTaken()
    {
        await Send("package-0001", "batch-0001", 0, 1, "Report.pdf", _start);
        Assert.Single(_inbox.Take("batch-0001", _start));
        Assert.NotNull(_inbox.Find(Phone, "package-0001"));
    }

    [Fact]
    public async Task RefusedPackage_LeavesNothing()
    {
        byte[] damaged = CompanionFixtures.Package();
        damaged[0] ^= 0xFF;
        await Assert.ThrowsAsync<PrintPackageException>(() => Receive("package-0001", damaged, _start));
        Assert.Null(_inbox.Find(Phone, "package-0001"));
        Assert.Empty(Directory.GetFiles(Path.Combine(_root, "Inbox", Phone)));
        Assert.Empty(_inbox.Batches(_start));
    }

    [Fact]
    public async Task ABodyThatEndsEarly_LeavesNothing()
    {
        byte[] package = CompanionFixtures.Package();
        await Assert.ThrowsAsync<EndOfStreamException>(() =>
            _inbox.ReceiveAsync(Phone, "package-0001", new MemoryStream(package[..20]), package.Length, _start, CancellationToken.None));
        Assert.Empty(Directory.GetFiles(Path.Combine(_root, "Inbox", Phone)));
    }

    [Fact]
    public async Task ABatch_IsWholeWhenEveryFileIsIn()
    {
        await Send("package-0001", "batch-0001", 0, 3, "a.pdf", _start);
        await Send("package-0002", "batch-0001", 2, 3, "c.pdf", _start.AddSeconds(1));
        Assert.False(Assert.Single(_inbox.Batches(_start.AddSeconds(2))).IsWhole(_start.AddSeconds(2)));
        await Send("package-0003", "batch-0001", 1, 3, "b.pdf", _start.AddSeconds(2));

        var batch = Assert.Single(_inbox.Batches(_start.AddSeconds(2)));
        Assert.Equal(new PhoneBatch("batch-0001", "Aytu's iPhone", 3, 3, _start.AddSeconds(2)), batch);
        Assert.True(batch.IsWhole(_start.AddSeconds(2)));
    }

    [Fact]
    public async Task ABatch_IsWhole30SecondsAfterTheLastFile()
    {
        await Send("package-0001", "batch-0001", 0, 3, "a.pdf", _start);
        await Send("package-0002", "batch-0001", 1, 3, "b.pdf", _start.AddSeconds(10));
        var batch = Assert.Single(_inbox.Batches(_start.AddSeconds(10)));
        Assert.Equal(2, batch.Arrived);
        Assert.False(batch.IsWhole(_start.AddSeconds(39)));
        Assert.False(batch.IsWhole(_start.AddSeconds(39.9)));
        Assert.True(batch.IsWhole(_start.AddSeconds(40)));
        Assert.True(batch.IsWhole(_start.AddMinutes(5)));
    }

    [Fact]
    public async Task Batches_AreKeptApartAndOldestFirst()
    {
        await Send("package-0001", "batch-0002", 0, 1, "later.pdf", _start.AddMinutes(1));
        await Send("package-0002", "batch-0001", 0, 1, "earlier.pdf", _start);
        await Send("package-0003", "batch-0003", 0, 1, "other.pdf", _start.AddMinutes(2), "phone-0002");
        Assert.Equal(["batch-0001", "batch-0002", "batch-0003"], _inbox.Batches(_start.AddMinutes(3)).Select(b => b.Id));
    }

    [Fact]
    public async Task Take_GivesTheFilesInTheOrderTheyWereSent()
    {
        await Send("package-0001", "batch-0001", 1, 3, "second.pdf", _start);
        await Send("package-0002", "batch-0001", 2, 3, "third.pdf", _start.AddSeconds(1));
        await Send("package-0003", "batch-0001", 0, 3, "first.pdf", _start.AddSeconds(2));
        await Send("package-0004", "batch-0002", 0, 1, "other.pdf", _start);

        string[] files = [.. _inbox.Take("batch-0001", _start)];

        string folder = Path.Combine(_root, "Inbox", "batch-0001");
        Assert.Equal([Path.Combine(folder, "first.pdf"), Path.Combine(folder, "second.pdf"), Path.Combine(folder, "third.pdf")], files);
        Assert.All(files, file => Assert.Equal(CompanionFixtures.Pdf, File.ReadAllBytes(file)));
        Assert.Equal(["batch-0002"], _inbox.Batches(_start.AddSeconds(3)).Select(b => b.Id));
        Assert.Empty(_inbox.Take("batch-0001", _start));
        Assert.True(File.Exists(Path.Combine(_root, "Inbox", Phone, "package-0004.lppkg")));
        Assert.False(File.Exists(Path.Combine(_root, "Inbox", Phone, "package-0001.lppkg")));
    }

    [Fact]
    public async Task Take_KeepsTheRealNamesAndNumbersRepeats()
    {
        await Send("package-0001", "batch-0001", 0, 3, "Report.pdf", _start);
        await Send("package-0002", "batch-0001", 1, 3, "Report.pdf", _start);
        await Send("package-0003", "batch-0001", 2, 3, "Q3: plan?.pdf", _start);

        string[] names = [.. _inbox.Take("batch-0001", _start).Select(Path.GetFileName)!];

        Assert.Equal(["Report.pdf", "Report (2).pdf", "Q3_ plan_.pdf"], names);
    }

    [Theory]
    [InlineData("NUL", "_NUL.pdf")]
    [InlineData("con.pdf", "_con.pdf")]
    [InlineData("COM1", "_COM1.pdf")]
    [InlineData("Lpt9.txt", "_Lpt9.txt.pdf")]
    [InlineData("CONOUT$", "_CONOUT$.pdf")]
    [InlineData("...", "file.pdf")]
    [InlineData("   ", "file.pdf")]
    [InlineData(". .", "file.pdf")]
    [InlineData(".pdf", "file.pdf")]
    [InlineData("report. ", "report.pdf")]
    [InlineData("Report.PDF", "Report.PDF")]
    [InlineData("COM10.pdf", "COM10.pdf")]
    public async Task Take_MakesTheNameSafeToCreateOnWindows(string name, string expected)
    {
        await Send("package-0001", "batch-0001", 0, 1, name, _start);

        Assert.Equal(expected, Path.GetFileName(Assert.Single(_inbox.Take("batch-0001", _start))));
    }

    [Fact]
    public async Task Take_GivesTheFileTheExtensionOfItsContentType()
    {
        string[] names = ["evil.exe", "evil.hta", "photo.pdf", "photo.JPEG", "noextension"];
        string[] types = ["application/pdf", "application/pdf", "image/png", "image/jpeg", "image/tiff"];
        byte[][] bytes = [CompanionFixtures.Pdf, CompanionFixtures.Pdf, [0x89, 0x50, 0x4E, 0x47, 1], [0xFF, 0xD8, 0xFF, 1], [0x49, 0x49, 0x2A, 0x00, 1]];
        for (int i = 0; i < names.Length; i++)
        {
            byte[] package = PrintPackage.Make(names[i], types[i], "batch-0001", i, names.Length, "x", bytes[i]);
            await Receive($"package-000{i}", package, _start);
        }

        string[] taken = [.. _inbox.Take("batch-0001", _start).Select(Path.GetFileName)!];

        Assert.Equal(["evil.exe.pdf", "evil.hta.pdf", "photo.pdf.png", "photo.JPEG", "noextension.tif"], taken);
    }

    [Fact]
    public async Task Take_TwoLongNamesOfOneBatch_BothGoIn()
    {
        string name = new string('a', 251) + ".pdf";
        await Send("package-0001", "batch-0001", 0, 2, name, _start);
        await Send("package-0002", "batch-0001", 1, 2, name, _start);

        string[] taken = [.. _inbox.Take("batch-0001", _start).Select(Path.GetFileName)!];

        Assert.Equal(2, taken.Length);
        Assert.All(taken, file => Assert.True(System.Text.Encoding.UTF8.GetByteCount(file) <= 255));
        Assert.EndsWith(" (2).pdf", taken[1]);
        Assert.Empty(_inbox.Batches(_start));
    }

    [Fact]
    public async Task Take_WhenTheFolderCannotBeMade_LeavesTheFilesInTheInbox()
    {
        await Send("package-0001", "batch-0001", 0, 2, "first.pdf", _start);
        await Send("package-0002", "batch-0001", 1, 2, "second.pdf", _start);
        string blocker = Path.Combine(_root, "Inbox", "batch-0001");
        File.WriteAllText(blocker, "in the way");

        Assert.Empty(_inbox.Take("batch-0001", _start));
        Assert.Equal(2, Assert.Single(_inbox.Batches(_start)).Arrived);

        File.Delete(blocker);
        Assert.Equal(2, _inbox.Take("batch-0001", _start).Count);
    }

    [Fact]
    public async Task Discard_DeletesTheBatchWithoutCopyingIt()
    {
        await Send("package-0001", "batch-0001", 0, 2, "NUL", _start);
        await Send("package-0002", "batch-0001", 1, 2, "second.pdf", _start);
        await Send("package-0003", "batch-0002", 0, 1, "other.pdf", _start);

        _inbox.Discard("batch-0001");

        Assert.Equal(["batch-0002"], _inbox.Batches(_start).Select(b => b.Id));
        Assert.False(Directory.Exists(Path.Combine(_root, "Inbox", "batch-0001")));
        _inbox.Discard("../batch-0002");
        Assert.Single(_inbox.Batches(_start));
    }

    [Fact]
    public async Task APhoneWithTooManyFilesWaiting_IsRefusedUntilSomeAreTaken()
    {
        for (int n = 0; n < CompanionInbox.MaxWaitingFiles; n++) await Send($"package-{n:D4}", "batch-0001", 0, 1, "a.pdf", _start);
        byte[] package = CompanionFixtures.Package();

        await Assert.ThrowsAsync<CompanionInboxFullException>(() => Receive("package-9999", package, _start));
        Assert.Null(_inbox.Find(Phone, "package-9999"));
        // Another phone has room of its own.
        await Send("package-9999", "batch-0002", 0, 1, "b.pdf", _start, "phone-0002");

        _inbox.Take("batch-0001", _start);
        await Receive("package-9998", package, _start);
    }

    [Fact]
    public async Task AnUploadThatWouldPassTheByteLimit_IsRefusedBeforeItsBodyIsRead()
    {
        await Send("package-0001", "batch-0001", 0, 1, "a.pdf", _start);
        var body = new MemoryStream(); // empty: reading it would end early instead

        await Assert.ThrowsAsync<CompanionInboxFullException>(
            () => _inbox.ReceiveAsync(Phone, "package-0002", body, CompanionInbox.MaxWaitingBytes, _start, CancellationToken.None));
        await Assert.ThrowsAsync<EndOfStreamException>(
            () => _inbox.ReceiveAsync(Phone, "package-0002", body, 1000, _start, CancellationToken.None));
    }

    [Fact]
    public async Task UploadsUnderWay_CountAgainstTheByteLimitTogether()
    {
        var release = new TaskCompletionSource();
        var slow = new SlowStream(release.Task);
        long half = CompanionInbox.MaxWaitingBytes / 2 + 1;
        var first = _inbox.ReceiveAsync(Phone, "package-0001", slow, half, _start, CancellationToken.None);
        await Assert.ThrowsAsync<CompanionInboxFullException>(
            () => _inbox.ReceiveAsync(Phone, "package-0002", new MemoryStream(), half, _start, CancellationToken.None));
        release.SetResult();
        await Assert.ThrowsAnyAsync<Exception>(() => first);
        // The reservation went with the failed upload.
        await Assert.ThrowsAsync<EndOfStreamException>(
            () => _inbox.ReceiveAsync(Phone, "package-0002", new MemoryStream(), half, _start, CancellationToken.None));
    }

    [Fact]
    public async Task AnUploadThatWouldLeaveTooLittleDisk_IsRefused()
    {
        _inbox.FreeSpace = _ => CompanionInbox.MinFreeBytes + 999;
        await Assert.ThrowsAsync<CompanionInboxFullException>(
            () => _inbox.ReceiveAsync(Phone, "package-0001", new MemoryStream(), 1000, _start, CancellationToken.None));
        await Assert.ThrowsAsync<EndOfStreamException>(
            () => _inbox.ReceiveAsync(Phone, "package-0001", new MemoryStream(), 999, _start, CancellationToken.None));
    }

    // A body that gives nothing until released, then ends.
    private sealed class SlowStream(Task release) : Stream
    {
        public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
        {
            await release.ConfigureAwait(false);
            return 0;
        }

        public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    [Fact]
    public async Task ABatch_GoesByTheNameThePhonePairedAs()
    {
        _inbox.NameOf = id => id == Phone ? "Aytu's iPhone" : null;
        await Send("package-0001", "batch-0001", 0, 1, "a.pdf", _start);
        await Receive("package-0002", CompanionFixtures.Package("batch-0002", 0, 1, "b.pdf", "Someone else"), _start.AddSeconds(1), "phone-0002");
        await Receive("package-0003", CompanionFixtures.Package("batch-0003", 0, 1, "c.pdf", "Line one\nLine two" + new string('x', 300)), _start.AddSeconds(2), "phone-0003");

        var batches = _inbox.Batches(_start.AddSeconds(3));

        Assert.Equal("Aytu's iPhone", batches[0].From);
        Assert.Equal("Someone else", batches[1].From);
        Assert.StartsWith("Line oneLine two", batches[2].From);
        Assert.True(System.Text.Encoding.UTF8.GetByteCount(batches[2].From) <= PairRequest.MaxNameBytes);
    }

    [Theory]
    [InlineData("unknown-batch")]
    [InlineData("short")]
    [InlineData("../batch-0001")]
    [InlineData("")]
    public async Task Take_OfAnythingElseGivesNothing(string batch)
    {
        await Send("package-0001", "batch-0001", 0, 1, "Report.pdf", _start);
        Assert.Empty(_inbox.Take(batch, _start));
        Assert.Single(_inbox.Batches(_start));
    }

    [Fact]
    public async Task AFile_IsKeptSevenDays()
    {
        await Send("package-0001", "batch-0001", 0, 1, "Report.pdf", _start);

        Assert.Single(_inbox.Batches(_start.AddDays(7).AddSeconds(-1)));
        Assert.Empty(_inbox.Batches(_start.AddDays(7)));
        Assert.False(File.Exists(Path.Combine(_root, "Inbox", Phone, "package-0001.lppkg")));
        // The log stays, so a retry is still answered as a duplicate.
        Assert.NotNull(_inbox.Find(Phone, "package-0001"));
    }

    [Fact]
    public async Task ATakenFile_IsKeptSevenDaysFromWhenItWasTaken()
    {
        await Send("package-0001", "batch-0001", 0, 1, "Report.pdf", _start);
        string file = Assert.Single(_inbox.Take("batch-0001", _start.AddDays(6)));

        _inbox.Batches(_start.AddDays(7));
        Assert.True(File.Exists(file));
        _inbox.Batches(_start.AddDays(13).AddSeconds(-1));
        Assert.True(File.Exists(file));
        _inbox.Batches(_start.AddDays(13));
        Assert.False(File.Exists(file));
        Assert.False(Directory.Exists(Path.GetDirectoryName(file)));
    }

    [Fact]
    public async Task OnlyTheOldFilesGo()
    {
        await Send("package-0001", "batch-0001", 0, 1, "old.pdf", _start);
        await Send("package-0002", "batch-0002", 0, 1, "new.pdf", _start.AddDays(5));

        Assert.Equal(["batch-0002"], _inbox.Batches(_start.AddDays(8)).Select(b => b.Id));
    }

    [Fact]
    public void APackage_IsReceivedOnceAtATime()
    {
        Assert.True(_inbox.TryBegin(Phone, "package-0001"));
        Assert.False(_inbox.TryBegin(Phone, "package-0001"));
        Assert.True(_inbox.TryBegin("phone-0002", "package-0001"));
        _inbox.End(Phone, "package-0001");
        Assert.True(_inbox.TryBegin(Phone, "package-0001"));
    }

    [Fact]
    public async Task RemovingAPhone_DeletesWhatItSent()
    {
        await Send("package-0001", "batch-0001", 0, 1, "Report.pdf", _start);
        _inbox.RemoveDevice(Phone);
        Assert.Empty(_inbox.Batches(_start));
        Assert.False(Directory.Exists(Path.Combine(_root, "Inbox", Phone)));
    }

    [Theory]
    [InlineData("short", "package-0001")]
    [InlineData("../phone-0001", "package-0001")]
    [InlineData(Phone, "pkg")]
    [InlineData(Phone, "..%2F..%2Fx")]
    public async Task IdsThatAreNotSafeFileNames_AreRefused(string device, string package)
    {
        Assert.Throws<ArgumentException>(() => _inbox.Find(device, package));
        await Assert.ThrowsAsync<ArgumentException>(() => Receive(package, CompanionFixtures.Package(), _start, device));
    }
}

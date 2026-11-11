using System.Net;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/IppClientTests.swift: the same cases, against the same loopback printer
// (LoopbackIppPrinter); retry waits run on a fake clock, timeouts on short real ones.

public sealed class IppClientTests : IDisposable
{
    private const string User = "tester";
    private readonly string _directory;

    public IppClientTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
    }

    public void Dispose()
    {
        try { Directory.Delete(_directory, recursive: true); } catch (IOException) { }
    }

    private sealed class FakeClock
    {
        public TimeSpan Now { get; private set; }
        public List<TimeSpan> Delays { get; } = [];

        public Task Delay(TimeSpan wait, CancellationToken token)
        {
            token.ThrowIfCancellationRequested();
            Delays.Add(wait);
            Now += wait;
            return Task.CompletedTask;
        }
    }

    private static IppClientOptions Options(FakeClock clock, double requestSeconds = 10, double printSeconds = 120) => new()
    {
        RequestTimeout = TimeSpan.FromSeconds(requestSeconds),
        PrintTimeout = TimeSpan.FromSeconds(printSeconds),
        Delay = clock.Delay,
        StartClock = () => () => clock.Now,
    };

    private static IppClient Client(LoopbackIppPrinter printer, FakeClock? clock = null, bool secure = false,
                                    IppCertificateValidator? validator = null, IppClientOptions? options = null)
    {
        options ??= Options(clock ?? new FakeClock());
        HttpMessageHandler handler = validator?.CreateHandler() ?? new HttpClientHandler { UseProxy = false };
        return new IppClient(printer.Address(secure), handler, "Fake MFP", User, validator, options);
    }

    private static readonly IppJobTicket Ticket = new("Report", "application/pdf", 1, "one-sided", "color",
                                                       new IppMediaChoice(null, "na_letter_8.5x11in"));

    private string Document(int length = 1000)
    {
        var bytes = new byte[length];
        new Random(7).NextBytes(bytes);
        var spool = new IppSpool(_directory); // the test directory goes away with its files
        spool.Write(stream => stream.Write(bytes));
        return spool.Complete();
    }

    private static byte[] CapabilitiesSpeaking(params string[] versions)
    {
        var message = IppMessage.Decode(IppFixtures.Printer("hp-laserjet")).Message;
        var groups = message.Groups.Select(g => new IppGroup(g.Tag,
        [
            .. g.Attributes.Select(a => a.Name == "ipp-versions-supported"
                ? new IppAttribute(a.Name, [.. versions.Select(v => (IppValue)new IppValue.Keyword(v))])
                : a),
        ])).ToList();
        return (message with { Groups = groups }).Encoded();
    }

    // MARK: - Requests

    [Fact]
    public async Task ReadsTheCapabilities()
    {
        using var printer = new LoopbackIppPrinter();
        using var client = Client(printer);
        var capabilities = await client.CapabilitiesAsync();
        Assert.Equal("HP LaserJet Pro M404dn", capabilities.MakeAndModel);
        var request = Assert.Single(printer.Requests);
        Assert.Equal("POST", request.Method);
        Assert.Equal("/ipp/print", request.Path);
        Assert.Equal("application/ipp", request.Header("Content-Type"));
        Assert.Equal(IppRequests.GetPrinterAttributes(printer.Address().PrinterUri, User).Encoded(), request.Body);
    }

    [Fact]
    public async Task PrintJobSendsTheFileInOneBodyWithAContentLength()
    {
        using var printer = new LoopbackIppPrinter();
        using var client = Client(printer);
        string path = Document(300_000);
        var job = await client.PrintAsync(path, Ticket);

        Assert.Equal(new IppJob(42, IppJobState.Pending, ["none"], 0), job);
        var request = Assert.Single(printer.Requests);
        byte[] head = IppRequests.PrintJob(printer.Address().PrinterUri, User, Ticket).Encoded();
        Assert.Equal(head, request.Body[..head.Length]);
        Assert.Equal(File.ReadAllBytes(path), request.Document);
        Assert.Equal("application/ipp", request.Header("Content-Type"));
        Assert.Equal(request.Body.Length.ToString(), request.Header("Content-Length"));
        Assert.Null(request.Header("Transfer-Encoding"));
        Assert.Null(request.Header("Expect"));
        Assert.True(File.Exists(path)); // the spool is the caller's to delete
    }

    [Fact]
    public async Task APrinterThatRefusesMediaCol_IsAskedOnceMoreWithTheMediaName()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.ClientErrorAttributesOrValuesNotSupported));
        using var client = Client(printer);
        var rich = Ticket with { Media = new IppMediaChoice([new IppAttribute("media-type", new IppValue.Keyword("stationery"))], "na_letter_8.5x11in") };
        var job = await client.PrintAsync(Document(), rich);

        Assert.Equal(42, job.Id);
        Assert.Equal(2, printer.Requests.Count);
        byte[] first = IppRequests.PrintJob(printer.Address().PrinterUri, User, rich, 1).Encoded();
        byte[] second = IppRequests.PrintJob(printer.Address().PrinterUri, User, Ticket, 2).Encoded();
        Assert.Equal(first, printer.Requests[0].Body[..first.Length]);
        Assert.Equal(second, printer.Requests[1].Body[..second.Length]);
    }

    [Fact]
    public async Task ARefusedPrintJobWithoutMediaCol_IsNotAskedAgain()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.ClientErrorAttributesOrValuesNotSupported));
        using var client = Client(printer);
        await Assert.ThrowsAsync<PrintException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Single(printer.Requests);
    }

    [Fact]
    public async Task ReadsAJobsStateReasonsAndImpressions()
    {
        using var printer = new LoopbackIppPrinter();
        var group = LoopbackAnswer.Job(42, 5, "job-printing", "job-queued");
        printer.Script(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, new IppGroup(group.Tag,
            [.. group.Attributes, new IppAttribute("job-impressions-completed", new IppValue.Integer(3))])));
        using var client = Client(printer);
        var job = await client.JobAsync(42);
        Assert.Equal(new IppJob(42, IppJobState.Processing, ["job-printing", "job-queued"], 3), job);
        Assert.False(job.IsFinished);
        Assert.Equal(IppRequests.GetJobAttributes(printer.Address().PrinterUri, User, 42).Encoded(),
                     Assert.Single(printer.Requests).Body);
    }

    [Fact]
    public async Task AJobThePrinterForgotAfterAcceptingItIsLostContact()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.ClientErrorNotFound));
        using var client = Client(printer);
        var error = await Assert.ThrowsAsync<PrintException>(() => client.JobAsync(42));
        Assert.Equal(new PrintError.LostContact(client.PrinterName), error.Error);
    }

    [Fact]
    public async Task CancelSendsCancelJobAndAnOverJobIsFine()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk), LoopbackAnswer.Ipp(IppStatus.ClientErrorNotFound),
                       LoopbackAnswer.Ipp(IppStatus.ClientErrorNotPossible), LoopbackAnswer.Ipp(IppStatus.ClientErrorForbidden));
        using var client = Client(printer);
        await client.CancelAsync(42);
        Assert.Equal(IppRequests.CancelJob(printer.Address().PrinterUri, User, 42).Encoded(), printer.Requests[0].Body);
        await client.CancelAsync(42);
        await client.CancelAsync(42);
        var refused = await Assert.ThrowsAsync<PrintException>(() => client.CancelAsync(42));
        Assert.Equal(new PrintError.Refused(0x0401, ""), refused.Error);
    }

    // MARK: - Busy printers

    [Fact]
    public async Task ABusyPrinterIsAskedAgainWithTheFileSentAgain()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Http(503, retryAfter: "1"), LoopbackAnswer.Ipp(IppStatus.ServerErrorBusy));
        var clock = new FakeClock();
        using var client = Client(printer, clock);
        string path = Document(70_000);
        var job = await client.PrintAsync(path, Ticket);

        Assert.Equal(42, job.Id);
        Assert.Equal(3, printer.Requests.Count);
        foreach (var request in printer.Requests)
        {
            Assert.Equal(File.ReadAllBytes(path), request.Document);
            Assert.Equal(request.Body.Length.ToString(), request.Header("Content-Length"));
            Assert.Null(request.Header("Transfer-Encoding"));
        }
        Assert.Equal([TimeSpan.FromSeconds(1), TimeSpan.FromSeconds(0.75)], clock.Delays);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task ABusyPrinterThatStaysBusyIsBusy(bool inTheIppStatus)
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script([.. Enumerable.Repeat(inTheIppStatus ? LoopbackAnswer.Ipp(IppStatus.ServerErrorBusy) : LoopbackAnswer.Http(503), 40)]);
        var clock = new FakeClock();
        using var client = Client(printer, clock);
        var error = await Assert.ThrowsAsync<PrintException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Equal(new PrintError.Busy(), error.Error);
        Assert.True(clock.Now <= TimeSpan.FromSeconds(60));
        Assert.Equal(clock.Delays.Count + 1, printer.Requests.Count);
    }

    [Fact]
    public async Task APrinterNotAcceptingJobsIsItsOwnProblemAndNotRetried()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.ServerErrorNotAcceptingJobs));
        var clock = new FakeClock();
        using var client = Client(printer, clock);
        var error = await Assert.ThrowsAsync<PrintException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Equal(new PrintError.Refused(0x0506, "The printer is not accepting jobs"), error.Error);
        Assert.Single(printer.Requests);
        Assert.Empty(clock.Delays);
    }

    // MARK: - IPP versions

    [Fact]
    public async Task AVersionRefusedMeansIpp11ForTheRestOfTheSession()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.ServerErrorVersionNotSupported));
        using var client = Client(printer);
        await client.PrintAsync(Document(), Ticket);
        await client.JobAsync(42);
        Assert.Equal([IppVersion.V20, IppVersion.V11, IppVersion.V11], printer.Requests.Select(r => r.Ipp.Version));
        Assert.Equal(IppRequests.Downgraded(IppRequests.PrintJob(printer.Address().PrinterUri, User, Ticket, 2)).Encoded(),
                     printer.Requests[1].Body[..IppRequests.PrintJob(printer.Address().PrinterUri, User, Ticket).Encoded().Length]);
    }

    [Fact]
    public async Task APrinterWithoutIpp20InItsVersionsIsSpokenToAs11()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(new LoopbackAnswer(200, CapabilitiesSpeaking("1.0", "1.1")));
        using var client = Client(printer);
        await client.CapabilitiesAsync();
        await client.JobAsync(42);
        Assert.Equal([IppVersion.V20, IppVersion.V11], printer.Requests.Select(r => r.Ipp.Version));
    }

    // MARK: - Encryption

    [Fact]
    public async Task HttpUpgradeRequiredMovesThePrinterToIpps()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        using var printer = new LoopbackIppPrinter { Certificate = certificate, UpgradeRequired = true };
        var store = new IppTrustStore(_directory);
        store.Trust(IppCertificates.Fingerprint(certificate), null, $"127.0.0.1:{printer.Port}", "Fake MFP");
        using var client = Client(printer, validator: new IppCertificateValidator(store, null, "Fake MFP"));

        var capabilities = await client.CapabilitiesAsync();
        Assert.Equal("HP LaserJet Pro M404dn", capabilities.MakeAndModel);
        Assert.True(client.Address.Secure);
        Assert.False(client.NotEncrypted);
        Assert.Equal([false, true], printer.Requests.Select(r => r.Tls));
        await client.JobAsync(42);
        Assert.Equal([false, true, true], printer.Requests.Select(r => r.Tls)); // it stays on ipps
    }

    [Fact]
    public async Task AFailedTlsHandshakeFallsBackToIppMarkedNotEncrypted()
    {
        using var printer = new LoopbackIppPrinter(); // no certificate: it cannot answer a handshake
        var store = new IppTrustStore(_directory);
        using var client = Client(printer, secure: true, validator: new IppCertificateValidator(store, null, "Fake MFP"));

        await client.CapabilitiesAsync();
        Assert.Equal(1, printer.TlsConnections);
        Assert.True(client.NotEncrypted);
        Assert.False(client.Address.Secure);
        Assert.False(Assert.Single(printer.Requests).Tls);
    }

    [Fact]
    public async Task ARefusedCertificateIsNeverFollowedByPlainIpp()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        using var printer = new LoopbackIppPrinter { Certificate = certificate };
        var store = new IppTrustStore(_directory);
        using var client = Client(printer, secure: true, validator: new IppCertificateValidator(store, null, "Fake MFP"));

        var refused = await Assert.ThrowsAsync<IppCertificateException>(() => client.CapabilitiesAsync());
        Assert.Equal(IppTrustVerdict.Unknown, refused.Verdict);
        Assert.True(refused.CanTrust);
        Assert.Equal(IppCertificates.Fingerprint(certificate), refused.Fingerprint);
        Assert.Equal(0, printer.PlainConnections); // nothing was sent to a printer that was not trusted
        Assert.Empty(printer.Requests);
        Assert.False(client.NotEncrypted);
    }

    [Fact]
    public async Task WithoutAValidatorARejectedCertificateIsNeverFollowedByPlainIpp()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        using var printer = new LoopbackIppPrinter { Certificate = certificate };
        using var client = Client(printer, secure: true);

        var error = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.IsType<PrintError.Unreachable>(error.Error);
        Assert.Equal(0, printer.PlainConnections);
        Assert.False(client.NotEncrypted);
    }

    [Fact]
    public async Task APrinterTrustedBeforeIsNeverDowngradedToPlainIpp()
    {
        using var printer = new LoopbackIppPrinter(); // its handshake fails, as when someone cuts it
        var store = new IppTrustStore(_directory);
        store.Trust(new string('a', 64), null, $"127.0.0.1:{printer.Port}", "Fake MFP");
        using var client = Client(printer, secure: true, validator: new IppCertificateValidator(store, null, "Fake MFP"));

        var error = await Assert.ThrowsAsync<PrintException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Equal(new PrintError.Unreachable("Fake MFP", "no secure connection"), error.Error);
        Assert.Equal(0, printer.PlainConnections);
        Assert.False(client.NotEncrypted);
    }

    [Fact]
    public async Task ARefusalNobodyCollectedIsNotReportedForALaterFailure()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        var validator = new IppCertificateValidator(new IppTrustStore(_directory), null, "Fake MFP");
        Assert.False(validator.Validate(new Uri("https://127.0.0.1:631/ipp/print"), certificate,
                                        System.Net.Security.SslPolicyErrors.RemoteCertificateChainErrors));
        var printer = new LoopbackIppPrinter();
        using var client = Client(printer, validator: validator);
        printer.Dispose(); // nothing answers any more

        var error = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.IsType<PrintError.Unreachable>(error.Error);
    }

    [Fact]
    public async Task AChangedCertificateIsRefusedAndNeverFallsBackToPlainIpp()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        using var printer = new LoopbackIppPrinter { Certificate = certificate };
        var store = new IppTrustStore(_directory);
        store.Trust(new string('a', 64), null, $"127.0.0.1:{printer.Port}", "Fake MFP");
        using var client = Client(printer, secure: true, validator: new IppCertificateValidator(store, null, "Fake MFP"));

        var refused = await Assert.ThrowsAsync<IppCertificateException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Equal(IppTrustVerdict.Changed, refused.Verdict);
        Assert.Equal(new string('a', 64), refused.Previous?.Fingerprint);
        Assert.Equal(0, printer.PlainConnections);
        Assert.Empty(printer.Requests);
    }

    [Fact]
    public async Task AFirstUseCertificateIsPinnedWithTheUuidTheCapabilitiesReport()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        using var printer = new LoopbackIppPrinter { Certificate = certificate };
        var store = new IppTrustStore(_directory);
        string fingerprint = IppCertificates.Fingerprint(certificate);
        using var client = Client(printer, secure: true,
                                  validator: new IppCertificateValidator(store, null, "Fake MFP", firstUse: fingerprint));

        Assert.Empty(store.Certificates);
        await client.CapabilitiesAsync();
        var pin = Assert.Single(new IppTrustStore(_directory).Certificates);
        Assert.Equal(fingerprint, pin.Fingerprint);
        Assert.Equal("4509a32000a0008f00b69c93b9a1c2d3", pin.DeviceUuid);
        Assert.Equal([$"127.0.0.1:{printer.Port}"], pin.Addresses);
    }

    [Fact]
    public async Task AFirstUseCertificateIsPinnedBeforeTheDocumentGoesOut()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        using var printer = new LoopbackIppPrinter { Certificate = certificate };
        var store = new IppTrustStore(_directory);
        using var client = Client(printer, secure: true,
                                  validator: new IppCertificateValidator(store, null, "Fake MFP", firstUse: IppCertificates.Fingerprint(certificate)));

        await client.PrintAsync(Document(), Ticket);
        Assert.Equal([(ushort)IppOperation.GetPrinterAttributes, (ushort)IppOperation.PrintJob],
                     printer.Requests.Select(r => IppMessage.Decode(r.Body).Message.Code));
        Assert.Single(new IppTrustStore(_directory).Certificates);
    }

    [Fact]
    public async Task AFirstUseCertificateOfAKnownPrintersKeyIsRefusedBeforeTheDocumentGoesOut()
    {
        using var certificate = LoopbackIppPrinter.SelfSigned("FakePrinter");
        using var printer = new LoopbackIppPrinter { Certificate = certificate };
        var store = new IppTrustStore(_directory);
        store.Trust(new string('a', 64), "4509a32000a0008f00b69c93b9a1c2d3", "10.0.0.9:631", "Fake MFP");
        using var client = Client(printer, secure: true,
                                  validator: new IppCertificateValidator(store, null, "Fake MFP", firstUse: IppCertificates.Fingerprint(certificate)));

        var refused = await Assert.ThrowsAsync<IppCertificateException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Equal(IppTrustVerdict.Changed, refused.Verdict);
        Assert.Equal((ushort)IppOperation.GetPrinterAttributes, IppMessage.Decode(Assert.Single(printer.Requests).Body).Message.Code);
    }

    // MARK: - Failures

    [Fact]
    public async Task ASignInIsNeededOnHttp401()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Http(401));
        using var client = Client(printer);
        var error = await Assert.ThrowsAsync<PrintException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Equal(new PrintError.NeedsSignIn(), error.Error);
        Assert.Equal("This printer asks for a sign-in, which Lazy Print can't do yet", error.Message);
    }

    [Fact]
    public async Task ASignInIsNeededWhenTheJobWaitsForAPassword()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(42, 4, "job-password-wait")),
                       LoopbackAnswer.Ipp(IppStatus.SuccessfulOk));
        using var client = Client(printer);
        var error = await Assert.ThrowsAsync<PrintException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Equal(new PrintError.NeedsSignIn(), error.Error);
        Assert.Equal(IppRequests.CancelJob(printer.Address().PrinterUri, User, 42, 2).Encoded(), printer.Requests[1].Body); // the held job is not left behind
    }

    [Theory]
    [InlineData(IppStatus.ClientErrorNotAuthenticated)]
    [InlineData(IppStatus.ClientErrorNotAuthorized)]
    public async Task ASignInIsNeededWhenThePrinterWantsAuthentication(IppStatus status)
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(status));
        using var client = Client(printer);
        var error = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.Equal(new PrintError.NeedsSignIn(), error.Error);
    }

    [Fact]
    public async Task AnIppErrorIsRefusedWithTheStatusAndThePrintersWords()
    {
        using var printer = new LoopbackIppPrinter();
        var message = new IppGroup(IppTag.OperationAttributes, [new IppAttribute("status-message", new IppValue.Text("Format not supported"))]);
        printer.Script(LoopbackAnswer.Ipp(IppStatus.ClientErrorDocumentFormatNotSupported, message),
                       LoopbackAnswer.Ipp(IppStatus.ServerErrorInternalError));
        using var client = Client(printer);

        var first = await Assert.ThrowsAsync<PrintException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Equal(new PrintError.Refused(0x040A, "Format not supported"), first.Error);
        Assert.Equal("Format not supported", first.Message);
        var second = await Assert.ThrowsAsync<PrintException>(() => client.PrintAsync(Document(), Ticket));
        Assert.Equal(new PrintError.Refused(0x0500, ""), second.Error);
        Assert.Equal("The printer refused the job (0x0500)", second.Message);
    }

    [Fact]
    public async Task AnswersThatAreNotIppAreReportedForWhatTheyAre()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Http(404), new LoopbackAnswer(200, "<html>hello</html>"u8.ToArray()),
                       new LoopbackAnswer(200, IppMessage.Decode(IppFixtures.Printer("hp-laserjet")).Message.Encoded()[..20]));
        using var client = Client(printer);
        var notFound = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.Equal(new PrintError.Unreachable("Fake MFP", "it answered HTTP 404"), notFound.Error);
        Assert.Equal("Can't reach Fake MFP: it answered HTTP 404", notFound.Message);
        var html = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.Equal(new PrintError.BadResponse(), html.Error);
        var cut = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.Equal(new PrintError.BadResponse(), cut.Error);
    }

    [Fact]
    public async Task AnAnswerOverEightMebibytesIsABadResponse()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(new LoopbackAnswer(200, new byte[8 * 1024 * 1024 + 1]));
        using var client = Client(printer);
        var error = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.Equal(new PrintError.BadResponse(), error.Error);
    }

    [Fact]
    public async Task ARepliedBodyOverEightMebibytesWithNoLengthIsABadResponse()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(new LoopbackAnswer(200, new byte[8 * 1024 * 1024 + 1], Chunked: true));
        using var client = Client(printer);
        var error = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.Equal(new PrintError.BadResponse(), error.Error);
    }

    [Fact]
    public async Task AnAnswerCutBeforeItsPromisedLengthIsUnreachable()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(new LoopbackAnswer(200, new byte[100], ClaimedLength: 500));
        using var client = Client(printer);
        var error = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.IsType<PrintError.Unreachable>(error.Error);
    }

    [Fact]
    public async Task APrinterThatIsNotThereIsUnreachable()
    {
        var printer = new LoopbackIppPrinter();
        var address = printer.Address();
        printer.Dispose();
        using var client = new IppClient(address, new HttpClientHandler { UseProxy = false }, "Fake MFP", User,
                                         options: Options(new FakeClock()));
        var error = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.Equal(new PrintError.Unreachable("Fake MFP", "it did not answer"), error.Error);
    }

    [Fact]
    public async Task APrinterThatStaysSilentTimesOutAfterTheRequestTimeout()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk).After(TimeSpan.FromSeconds(5)));
        using var client = Client(printer, options: Options(new FakeClock(), requestSeconds: 0.3));
        var error = await Assert.ThrowsAsync<PrintException>(() => client.CapabilitiesAsync());
        Assert.Equal(new PrintError.Unreachable("Fake MFP", "it did not answer in time"), error.Error);
    }

    [Fact]
    public async Task PrintJobHasItsOwnLongerTimeout()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(9, 3)).After(TimeSpan.FromSeconds(0.8)));
        using var client = Client(printer, options: Options(new FakeClock(), requestSeconds: 0.3, printSeconds: 5));
        Assert.Equal(9, (await client.PrintAsync(Document(), Ticket)).Id);

        printer.Script(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk, LoopbackAnswer.Job(9, 3)).After(TimeSpan.FromSeconds(5)));
        using var impatient = Client(printer, options: Options(new FakeClock(), requestSeconds: 5, printSeconds: 0.3));
        var error = await Assert.ThrowsAsync<PrintException>(() => impatient.PrintAsync(Document(), Ticket));
        Assert.Equal(new PrintError.Unreachable("Fake MFP", "it did not answer in time"), error.Error);
    }

    [Fact]
    public async Task CancellingStopsTheRequestAndIsNotAFailure()
    {
        using var printer = new LoopbackIppPrinter();
        printer.Script(LoopbackAnswer.Ipp(IppStatus.SuccessfulOk).After(TimeSpan.FromSeconds(5)));
        using var client = Client(printer);
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => client.CapabilitiesAsync(cancel.Token));
    }
}

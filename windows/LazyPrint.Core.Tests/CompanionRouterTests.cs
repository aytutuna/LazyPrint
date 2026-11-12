using System.Net;
using System.Text;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/CompanionRouterTests.swift: the desktop's request handling,
// without a network.

[Collection(WallClockCollection.Name)]
public sealed class CompanionRouterTests : IDisposable
{
    private static readonly IPAddress Phone = IPAddress.Parse("192.168.1.30");
    private readonly string _directory;
    private DateTimeOffset _now = new(2026, 10, 20, 8, 30, 0, TimeSpan.Zero);
    private readonly PairedDeviceStore _devices;
    private readonly CompanionInbox _inbox;
    private readonly CompanionRouter _router;
    private PairingSession? _pairing;
    // What the server reports once it has tried to write a response.
    private bool _delivered = true;

    public CompanionRouterTests()
    {
        _directory = Path.Combine(Path.GetTempPath(), "LazyPrintTests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(_directory);
        _devices = new PairedDeviceStore(_directory);
        _inbox = new CompanionInbox(Path.Combine(_directory, "Inbox"));
        _router = new CompanionRouter(_devices, _inbox, new CompanionRateLimiter(), () => _now)
        {
            DesktopName = () => "AYTU-PC",
            CurrentPairing = () => _pairing,
            ApprovePairing = (_, _) => Task.FromResult(true),
        };
    }

    public void Dispose()
    {
        try
        {
            Directory.Delete(_directory, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private async Task<CompanionResponse> Send(string method, string target, byte[]? body = null, string? device = null,
                                               string? secret = null, IPAddress? from = null, params (string, string)[] headers)
    {
        var list = new List<KeyValuePair<string, string>> { new("Host", "192.168.1.20:52732") };
        if (device is not null) list.Add(new(CompanionProtocol.DeviceIdHeader, device));
        if (secret is not null) list.Add(new("Authorization", "Bearer " + secret));
        list.AddRange(headers.Select(h => new KeyValuePair<string, string>(h.Item1, h.Item2)));
        long? length = body?.Length;
        if (length is not null) list.Add(new("Content-Length", length.Value.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        var head = new HttpRequestHead(method, target, list, length, false);
        var stream = new MemoryStream(body ?? []);
        var response = await _router.HandleAsync(new CompanionRequest(head, new CompanionRequestBody(stream, length ?? 0), from ?? Phone),
                                                 CancellationToken.None);
        response.Written?.Invoke(_delivered);
        return response;
    }

    private async Task<string> PairPhone(string id = "phone-0001")
    {
        _pairing = new PairingSession(_now);
        var response = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, id, "Aytu's iPhone", "ios", "1.0")));
        Assert.Equal(200, response.Status);
        return PairResponse.FromJson(response.Body)!.DeviceSecret;
    }

    private static byte[] Json(PairRequest request) => Encoding.UTF8.GetBytes(request.ToJson());

    [Fact]
    public async Task Health_AnswersAnyoneAndChecksCredentialsWhenGiven()
    {
        var anonymous = await Send("GET", CompanionProtocol.HealthPath);
        Assert.Equal(200, anonymous.Status);
        Assert.Equal(new HealthResponse(1, false), HealthResponse.FromJson(anonymous.Body));
        string secret = await PairPhone();
        Assert.Equal(new HealthResponse(1, true),
                     HealthResponse.FromJson((await Send("GET", CompanionProtocol.HealthPath, device: "phone-0001", secret: secret)).Body));
        var wrong = await Send("GET", CompanionProtocol.HealthPath, device: "phone-0001", secret: CompanionVectors.SecretText);
        Assert.Equal(401, wrong.Status);
        Assert.Contains(wrong.Headers, h => h.Key == "WWW-Authenticate" && h.Value == "Bearer");
        Assert.Equal(405, (await Send("POST", CompanionProtocol.HealthPath, [])).Status);
    }

    [Fact]
    public async Task Pair_GivesASecretForTheOpenSessionsToken()
    {
        _pairing = new PairingSession(_now);
        PairedDevice? paired = null;
        _router.DevicePaired += (_, device) => paired = device;
        var response = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0001", "Aytu's\u0001 iPhone", "ios", "1.0")));
        Assert.Equal(200, response.Status);
        var answer = PairResponse.FromJson(response.Body)!;
        Assert.Equal(_devices.DesktopId, answer.DesktopId);
        Assert.Equal("AYTU-PC", answer.DesktopName);
        Assert.Equal(1, answer.ProtocolVersion);
        // Approved, not paired yet: its first request with the secret pairs it.
        Assert.Null(paired);
        Assert.Empty(_devices.Devices);
        Assert.Equal(200, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: answer.DeviceSecret)).Status);
        Assert.Equal("Aytu's iPhone", paired?.Name);
        Assert.Single(_devices.Devices);
        // The token was single use.
        var again = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0002", "Other", "ios", "1.0")));
        Assert.Equal(403, again.Status);
        Assert.Equal(CompanionErrorCode.TokenUsed, CompanionError.FromJson(again.Body)!.Code);
    }

    [Fact]
    public async Task Pair_ForgetsAPhoneThatNeverGotItsSecret()
    {
        _pairing = new PairingSession(_now);
        int paired = 0;
        _router.DevicePaired += (_, _) => paired++;
        _delivered = false;
        var response = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0001", "P", "ios", "1")));
        Assert.Equal(200, response.Status);
        Assert.Empty(_devices.Devices);
        Assert.Equal(0, paired);
        Assert.Equal(0, _router.AwaitingApproval);
    }

    [Fact]
    public async Task Pair_DoesNotStoreAPhoneThatNeverComesBack()
    {
        string secret = await PairPhone();
        Assert.Empty(_devices.Devices);
        Assert.True(_devices.HasPending(_now));
        // Not stored while it is awaited, and refused with the secret it was given, unless it comes back in time.
        _now += PairedDeviceStore.PendingLifetime;
        Assert.False(_devices.HasPending(_now));
        Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Status);
        Assert.Empty(_devices.Devices);
        Assert.Empty(new PairedDeviceStore(_directory).Devices);
    }

    [Fact]
    public async Task Pair_StoresAnApprovedPhoneAtItsFirstRequest()
    {
        int paired = 0;
        _router.DevicePaired += (_, _) => paired++;
        string secret = await PairPhone();
        Assert.Empty(new PairedDeviceStore(_directory).Devices);
        Assert.Equal(200, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Status);
        Assert.Equal(1, paired);
        Assert.Equal("phone-0001", Assert.Single(new PairedDeviceStore(_directory).Devices).Id);
        Assert.False(_devices.HasPending(_now));
        Assert.Equal(200, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Status);
        Assert.Equal(1, paired);
    }

    [Fact]
    public async Task Pair_GivesAnApprovedPhoneNothingBeforeItsSecretIsUsed()
    {
        string secret = await PairPhone();
        // Another secret, or none, gets what an unknown phone gets.
        Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: CompanionVectors.SecretText)).Status);
        Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001")).Status);
        Assert.Equal(401, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", [1], device: "phone-0001", secret: CompanionVectors.SecretText)).Status);
        Assert.Empty(_devices.Devices);
        // With its own secret it is a paired phone like any other, and the upload route answers it.
        Assert.NotEqual(401, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", [1], device: "phone-0001", secret: secret)).Status);
        Assert.Single(_devices.Devices);
    }

    [Fact]
    public async Task Pair_ForgetsAnApprovedPhoneWhenPairingEnds()
    {
        string secret = await PairPhone();
        _devices.ClearPending();
        Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Status);
        Assert.Empty(_devices.Devices);
    }

    [Fact]
    public async Task Pair_RefusesWithoutAnOpenSessionOrTheRightToken()
    {
        async Task<string> Code(PairRequest request) => CompanionError.FromJson((await Send("POST", CompanionProtocol.PairPath, Json(request))).Body)!.Code;
        Assert.Equal(CompanionErrorCode.PairingClosed, await Code(new PairRequest(CompanionVectors.TokenText, "phone-0001", "P", "ios", "1")));
        _pairing = new PairingSession(_now, CompanionVectors.Token);
        Assert.Equal(CompanionErrorCode.TokenInvalid, await Code(new PairRequest("AAECAwQFBgcICQoLDA0ODx", "phone-0001", "P", "ios", "1")));
        _now = _now.AddMinutes(6);
        Assert.Equal(CompanionErrorCode.TokenExpired, await Code(new PairRequest(CompanionVectors.TokenText, "phone-0001", "P", "ios", "1")));
        Assert.Empty(_devices.Devices);
    }

    [Fact]
    public async Task Pair_RefusesMalformedRequests()
    {
        _pairing = new PairingSession(_now);
        Assert.Equal(400, (await Send("POST", CompanionProtocol.PairPath, Encoding.UTF8.GetBytes("not json"))).Status);
        Assert.Equal(400, (await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "bad id", "P", "ios", "1")))).Status);
        Assert.Equal(411, (await Send("POST", CompanionProtocol.PairPath)).Status);
        Assert.Equal(413, (await Send("POST", CompanionProtocol.PairPath, new byte[CompanionProtocol.MaxJsonBodyBytes + 1])).Status);
        // None of these used the token.
        Assert.Equal(PairingSessionState.Open, _pairing.StateAt(_now));
    }

    [Fact]
    public async Task Pair_WithoutAnyoneToAsk_IsDeclined()
    {
        var router = new CompanionRouter(_devices, _inbox, new CompanionRateLimiter(), () => _now) { CurrentPairing = () => _pairing };
        _pairing = new PairingSession(_now);
        var head = new HttpRequestHead("POST", CompanionProtocol.PairPath, [new("Host", "x")], null, false);
        byte[] body = Json(new PairRequest(_pairing.Token, "phone-0001", "P", "ios", "1"));
        var request = new CompanionRequest(head with { ContentLength = body.Length }, new CompanionRequestBody(new MemoryStream(body), body.Length), Phone);

        var response = await router.HandleAsync(request, CancellationToken.None);

        Assert.Equal(403, response.Status);
        Assert.Equal(CompanionErrorCode.Declined, CompanionError.FromJson(response.Body)!.Code);
        Assert.Empty(_devices.Devices);
    }

    [Fact]
    public async Task Pair_WithoutAnOpenSession_DoesNotReadTheBody()
    {
        var head = new HttpRequestHead("POST", CompanionProtocol.PairPath, [new("Host", "x"), new("Content-Length", "100")], 100, false);
        var request = new CompanionRequest(head, new CompanionRequestBody(new UnreadableStream(), 100), Phone);

        var response = await _router.HandleAsync(request, CancellationToken.None);

        Assert.Equal(403, response.Status);
        Assert.Equal(CompanionErrorCode.PairingClosed, CompanionError.FromJson(response.Body)!.Code);
    }

    private sealed class UnreadableStream : Stream
    {
        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
        public override void Flush() { }
        public override int Read(byte[] buffer, int offset, int count) => throw new InvalidOperationException("The body was read.");
        public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }

    [Fact]
    public async Task Pair_WaitsForTheUsersAnswer()
    {
        _pairing = new PairingSession(_now);
        PairRequest? asked = null;
        _router.ApprovePairing = (request, _) =>
        {
            asked = request;
            return Task.FromResult(false);
        };
        var declined = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0001", "", "ios", "1")));
        Assert.Equal(403, declined.Status);
        Assert.Equal(CompanionErrorCode.Declined, CompanionError.FromJson(declined.Body)!.Code);
        Assert.Equal("Phone", asked?.PhoneName);
        Assert.Empty(_devices.Devices);

        _pairing = new PairingSession(_now);
        _router.ApprovalTimeout = TimeSpan.FromMilliseconds(50);
        _router.ApprovePairing = async (_, cancellation) =>
        {
            await Task.Delay(Timeout.Infinite, cancellation);
            return true;
        };
        var unanswered = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0001", "P", "ios", "1")));
        Assert.Equal(CompanionErrorCode.Declined, CompanionError.FromJson(unanswered.Body)!.Code);
    }

    [Fact]
    public async Task Pair_CountsEveryTokenCheckUntilItEnds()
    {
        int settled = 0;
        _router.ApprovalSettled += (_, _) => settled++;
        // Refused tokens: counted while checked, then nothing is left waiting.
        _pairing = new PairingSession(_now, CompanionVectors.Token);
        await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest("AAECAwQFBgcICQoLDA0ODx", "phone-0001", "P", "ios", "1")));
        Assert.Equal(0, _router.AwaitingApproval);
        Assert.Equal(1, settled);

        // A valid token: the used session's request is counted while the user answers.
        var asked = new TaskCompletionSource<(PairingSessionState State, int Awaiting)>(TaskCreationOptions.RunContinuationsAsynchronously);
        var answer = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _router.ApprovePairing = (_, cancellation) =>
        {
            asked.TrySetResult((_pairing!.StateAt(_now), _router.AwaitingApproval));
            return answer.Task.WaitAsync(cancellation);
        };
        var pairing = Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(CompanionVectors.TokenText, "phone-0001", "P", "ios", "1")));
        Assert.Equal((PairingSessionState.Used, 1), await asked.Task.WaitAsync(TimeSpan.FromSeconds(10)));
        Assert.Equal(1, _router.AwaitingApproval);
        Assert.Equal(1, settled);
        answer.SetResult(true);
        Assert.Equal(200, (await pairing).Status);
        Assert.Equal(0, _router.AwaitingApproval);
        Assert.Equal(2, settled);

        // The used token again: refused, counted and settled like the others.
        var reused = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(CompanionVectors.TokenText, "phone-0002", "P", "ios", "1")));
        Assert.Equal(CompanionErrorCode.TokenUsed, CompanionError.FromJson(reused.Body)!.Code);
        Assert.Equal(0, _router.AwaitingApproval);
        Assert.Equal(3, settled);
    }

    [Fact]
    public async Task Hello_NeedsAPairedPhone()
    {
        Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath)).Status);
        string secret = await PairPhone();
        var hello = HelloResponse.FromJson((await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Body);
        Assert.Equal(new HelloResponse(_devices.DesktopId, "AYTU-PC", 1, CompanionProtocol.MaxUploadBytes), hello);
    }

    [Fact]
    public async Task Inbox_ReceivesAPackageOnce()
    {
        string secret = await PairPhone();
        var received = new List<CompanionPackageReceivedEventArgs>();
        _router.PackageReceived += (_, e) => received.Add(e);
        byte[] package = CompanionFixtures.Package();
        var first = await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", package, "phone-0001", secret);
        Assert.Equal(201, first.Status);
        Assert.Equal(new InboxResponse("package-0001", false), InboxResponse.FromJson(first.Body));
        var e = Assert.Single(received);
        Assert.Equal("phone-0001", e.Device.Id);
        Assert.True(File.Exists(e.Package.Path));
        Assert.Equal("Report.pdf", e.Package.Info.Name);

        // A retry, even after the batch was taken, is answered as a duplicate.
        Assert.Single(_inbox.Take("batch-0001", _now));
        var again = await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", package, "phone-0001", secret);
        Assert.Equal(200, again.Status);
        Assert.Equal(new InboxResponse("package-0001", true), InboxResponse.FromJson(again.Body));
        Assert.Single(received);
        Assert.Empty(_inbox.Batches(_now));
    }

    [Fact]
    public async Task Inbox_RefusesBadUploads()
    {
        string secret = await PairPhone();
        byte[] package = CompanionFixtures.Package();
        Assert.Equal(401, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", package)).Status);
        Assert.Equal(401, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", package, "phone-0001", CompanionVectors.SecretText)).Status);
        Assert.Equal(400, (await Send("PUT", CompanionProtocol.InboxPrefix + "..%2F..%2Fx", package, "phone-0001", secret)).Status);
        Assert.Equal(400, (await Send("PUT", CompanionProtocol.InboxPrefix + "short", package, "phone-0001", secret)).Status);
        Assert.Equal(411, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", null, "phone-0001", secret)).Status);
        Assert.Equal(405, (await Send("GET", CompanionProtocol.InboxPrefix + "package-0001", null, "phone-0001", secret)).Status);

        var damaged = (byte[])package.Clone();
        damaged[0] ^= 0xFF;
        var refused = await Send("PUT", CompanionProtocol.InboxPrefix + "package-0002", damaged, "phone-0001", secret);
        Assert.Equal(422, refused.Status);
        Assert.Equal(CompanionErrorCode.InvalidPackage, CompanionError.FromJson(refused.Body)!.Code);
        var notAPdf = (byte[])package.Clone();
        notAPdf[PrintPackage.Read(package).DataOffset] ^= 0xFF;
        Assert.Equal(422, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0004", notAPdf, "phone-0001", secret)).Status);
        Assert.Equal(422, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0003", Encoding.UTF8.GetBytes("not a package"), "phone-0001", secret)).Status);
        // Nothing of the refused uploads is kept, and they can be sent again.
        Assert.Null(_inbox.Find("phone-0001", "package-0002"));
        Assert.Empty(Directory.GetFiles(Path.Combine(_directory, "Inbox", "phone-0001"), "*.part"));
        Assert.Empty(_inbox.Batches(_now));
    }

    [Fact]
    public async Task Inbox_RefusesAPhoneWithTooManyFilesWaiting()
    {
        string secret = await PairPhone();
        for (int n = 0; n < CompanionInbox.MaxWaitingFiles; n++)
        {
            byte[] stored = CompanionFixtures.Package(index: 0, count: 1);
            await _inbox.ReceiveAsync("phone-0001", $"package-{n:D4}", new MemoryStream(stored), stored.Length, _now, CancellationToken.None);
        }
        byte[] package = CompanionFixtures.Package();

        var refused = await Send("PUT", CompanionProtocol.InboxPrefix + "package-9999", package, "phone-0001", secret);

        Assert.Equal(409, refused.Status);
        Assert.Equal(CompanionErrorCode.InboxFull, CompanionError.FromJson(refused.Body)!.Code);
        Assert.Null(_inbox.Find("phone-0001", "package-9999"));
        // A retry of a file that is in already is still answered.
        Assert.Equal(200, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0000", package, "phone-0001", secret)).Status);
    }

    [Fact]
    public async Task Inbox_RefusesAnOversizeUploadBeforeReadingIt()
    {
        string secret = await PairPhone();
        var head = new HttpRequestHead("PUT", CompanionProtocol.InboxPrefix + "package-0001",
            [new("Host", "x"), new(CompanionProtocol.DeviceIdHeader, "phone-0001"), new("Authorization", "Bearer " + secret)],
            CompanionProtocol.MaxUploadBytes + 1, true);
        bool continued = false;
        var body = new CompanionRequestBody(new MemoryStream(), CompanionProtocol.MaxUploadBytes + 1, default, _ =>
        {
            continued = true;
            return Task.CompletedTask;
        });
        var response = await _router.HandleAsync(new CompanionRequest(head, body, Phone), CancellationToken.None);
        Assert.Equal(413, response.Status);
        Assert.False(continued);
        Assert.True(body.IsWithheld);
    }

    [Fact]
    public async Task Inbox_RefusesTheSamePackageWhileItIsReceived()
    {
        string secret = await PairPhone();
        Assert.True(_inbox.TryBegin("phone-0001", "package-0001"));
        var busy = await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", CompanionFixtures.Package(), "phone-0001", secret);
        Assert.Equal(409, busy.Status);
        _inbox.End("phone-0001", "package-0001");
    }

    [Fact]
    public async Task DeviceSelf_ForgetsThePhone()
    {
        string secret = await PairPhone();
        Assert.Equal(201, (await Send("PUT", CompanionProtocol.InboxPrefix + "package-0001", CompanionFixtures.Package(), "phone-0001", secret)).Status);
        PairedDevice? removed = null;
        _router.DeviceRemoved += (_, device) => removed = device;
        Assert.Equal(204, (await Send("DELETE", CompanionProtocol.DeviceSelfPath, device: "phone-0001", secret: secret)).Status);
        Assert.Equal("phone-0001", removed?.Id);
        Assert.Empty(_devices.Devices);
        Assert.Empty(_inbox.Batches(_now));
        Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Status);
    }

    [Fact]
    public async Task UnknownPaths_AreNotFound()
    {
        Assert.Equal(404, (await Send("GET", "/")).Status);
        Assert.Equal(404, (await Send("GET", "/v2/health")).Status);
        Assert.Equal(404, (await Send("GET", "/v1/outbox", device: "phone-0001")).Status);
        Assert.Equal(405, (await Send("PUT", CompanionProtocol.HelloPath, [])).Status);
    }

    [Fact]
    public async Task WrongSecrets_AreRateLimited()
    {
        string secret = await PairPhone();
        var attacker = IPAddress.Parse("192.168.1.66");
        for (int i = 0; i < CompanionRateLimiter.MaxFailures; i++)
        {
            Assert.Equal(401, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: CompanionVectors.SecretText, from: attacker)).Status);
        }
        var limited = await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret, from: attacker);
        Assert.Equal(429, limited.Status);
        Assert.Contains(limited.Headers, h => h.Key == "Retry-After");
        // Others are not affected, and the attacker may try again a minute later.
        Assert.Equal(200, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret)).Status);
        _now = _now.AddMinutes(1);
        Assert.Equal(200, (await Send("GET", CompanionProtocol.HelloPath, device: "phone-0001", secret: secret, from: attacker)).Status);
    }

    [Fact]
    public async Task WrongTokens_AreRateLimitedToo()
    {
        _pairing = new PairingSession(_now);
        var attacker = IPAddress.Parse("192.168.1.66");
        for (int i = 0; i < PairingSession.MaxFailedAttempts; i++)
        {
            await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(CompanionVectors.TokenText, "phone-0001", "P", "ios", "1")), from: attacker);
        }
        // The attacker is refused now, even with the right token; the session stays open for others.
        var closed = await Send("POST", CompanionProtocol.PairPath, Json(new PairRequest(_pairing.Token, "phone-0001", "P", "ios", "1")), from: attacker);
        Assert.Equal(CompanionErrorCode.PairingClosed, CompanionError.FromJson(closed.Body)!.Code);
        Assert.Equal(PairingSessionState.Open, _pairing.StateAt(_now));
    }
}

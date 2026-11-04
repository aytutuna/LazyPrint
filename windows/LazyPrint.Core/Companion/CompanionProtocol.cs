using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Companion/CompanionProtocol.swift: the same constants, the same
// JSON bytes for the same message and the same lenient reading, so the phone and the desktop
// speak exactly one protocol.

/// <summary>
/// The companion link between a paired phone and the desktop app: HTTP/1.1 over TLS, the phone
/// always starting the connection. The desktop's certificate is pinned by its
/// <see cref="SpkiFingerprint"/> from the pairing code; every request after pairing carries the
/// phone's device secret as a bearer token with its id. Endpoints (all JSON unless noted):
/// <list type="bullet">
/// <item><c>GET /v1/health</c>: reachability, answered to anyone (<see cref="HealthResponse"/>; with
/// credentials it also says whether the phone is still paired, a wrong secret gets 401).</item>
/// <item><c>POST /v1/pair</c>: the one call an unpaired phone may make, with the pairing code's token
/// (<see cref="PairRequest"/> → <see cref="PairResponse"/>).</item>
/// <item><c>GET /v1/hello</c>: the desktop's name and its upload limit (<see cref="HelloResponse"/>).</item>
/// <item><c>PUT /v1/inbox/{packageId}</c>: a print package (<see cref="PrintPackage"/>),
/// idempotent by package id (<see cref="InboxResponse"/>).</item>
/// <item><c>DELETE /v1/devices/self</c>: the phone forgets this desktop.</item>
/// </list>
/// Errors are <see cref="CompanionError"/> with a stable code (<see cref="CompanionErrorCode"/>).
/// </summary>
public static class CompanionProtocol
{
    /// <summary>The protocol version, in the pairing code and every response.</summary>
    public const int Version = 1;
    /// <summary>The DNS-SD service type the desktop advertises while it receives.</summary>
    public const string ServiceType = "_lazyprint._tcp";
    /// <summary>The <c>service</c> value of <see cref="HealthResponse"/>.</summary>
    public const string ServiceName = "lazyprint";
    /// <summary>The port the desktop tries first; another free one is used when it is taken.</summary>
    public const int DefaultPort = 52732;

    public const string HealthPath = "/v1/health";
    public const string PairPath = "/v1/pair";
    public const string HelloPath = "/v1/hello";
    /// <summary>Followed by the package id.</summary>
    public const string InboxPrefix = "/v1/inbox/";
    public const string DeviceSelfPath = "/v1/devices/self";

    /// <summary>The phone's id, sent with its secret on every request after pairing.</summary>
    public const string DeviceIdHeader = "X-Device-Id";
    public const string JsonContentType = "application/json; charset=utf-8";
    public const string PackageContentType = "application/vnd.lazyprint.package";

    /// <summary>The largest JSON request body (a pairing request).</summary>
    public const int MaxJsonBodyBytes = 8192;
    /// <summary>The DNS-SD TXT keys: the protocol version and the desktop's id.</summary>
    public const string TxtVersionKey = "v";
    public const string TxtIdKey = "id";

    /// <summary>The largest upload: a print package at its largest.</summary>
    public static long MaxUploadBytes => PrintPackage.MaxPackageBytes;

    /// <summary>
    /// Whether <paramref name="id"/> can be a phone's, desktop's or package's id:
    /// 8 to 64 characters, letters, digits, '-' and '_' (safe as a file name everywhere).
    /// </summary>
    public static bool IsValidId(string? id)
    {
        if (id is null || id.Length < 8 || id.Length > 64) return false;
        foreach (char c in id)
        {
            if (!(c is >= 'a' and <= 'z' or >= 'A' and <= 'Z' or >= '0' and <= '9' or '-' or '_')) return false;
        }
        return true;
    }

    /// <summary>Base64url without padding (RFC 4648 section 5).</summary>
    public static string EncodeBase64Url(ReadOnlySpan<byte> data)
    {
        const string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
        var text = new StringBuilder((data.Length * 4 + 2) / 3);
        int i = 0;
        for (; i + 3 <= data.Length; i += 3)
        {
            int block = (data[i] << 16) | (data[i + 1] << 8) | data[i + 2];
            text.Append(alphabet[(block >> 18) & 63]).Append(alphabet[(block >> 12) & 63])
                .Append(alphabet[(block >> 6) & 63]).Append(alphabet[block & 63]);
        }
        int rest = data.Length - i;
        if (rest == 1)
        {
            int block = data[i] << 16;
            text.Append(alphabet[(block >> 18) & 63]).Append(alphabet[(block >> 12) & 63]);
        }
        else if (rest == 2)
        {
            int block = (data[i] << 16) | (data[i + 1] << 8);
            text.Append(alphabet[(block >> 18) & 63]).Append(alphabet[(block >> 12) & 63]).Append(alphabet[(block >> 6) & 63]);
        }
        return text.ToString();
    }

    /// <summary>
    /// The bytes of base64url text without padding; null for anything else: padding, other
    /// characters, a length no encoding has, or unused bits that are not zero (so every value has
    /// exactly one text).
    /// </summary>
    public static byte[]? DecodeBase64Url(string? text)
    {
        if (text is null || text.Length % 4 == 1) return null;
        var bytes = new byte[text.Length * 3 / 4];
        int bits = 0, bitCount = 0, count = 0;
        foreach (char c in text)
        {
            int value = c switch
            {
                >= 'A' and <= 'Z' => c - 'A',
                >= 'a' and <= 'z' => c - 'a' + 26,
                >= '0' and <= '9' => c - '0' + 52,
                '-' => 62,
                '_' => 63,
                _ => -1,
            };
            if (value < 0) return null;
            bits = (bits << 6) | value;
            bitCount += 6;
            if (bitCount >= 8)
            {
                bitCount -= 8;
                bytes[count++] = (byte)(bits >> bitCount);
                bits &= (1 << bitCount) - 1;
            }
        }
        if (bits != 0) return null;
        return count == bytes.Length ? bytes : bytes[..count];
    }

    /// <summary>A JSON body as UTF-8 bytes.</summary>
    internal static byte[] Utf8(string json) => Encoding.UTF8.GetBytes(json);

    /// <summary>
    /// <paramref name="json"/> read as <typeparamref name="T"/> the way settings files are read
    /// (every property on its own, defaults for anything missing or wrong-typed); null when it is
    /// not a JSON object.
    /// </summary>
    internal static T? Decode<T>(ReadOnlySpan<byte> json) where T : class
    {
        try
        {
            return StoreFiles.Decode<T>(json);
        }
        catch (Exception error) when (error is JsonException or InvalidOperationException or NotSupportedException
                                      or ArgumentException or DecoderFallbackException)
        {
            return null;
        }
    }

    internal static string Integer(long value) => value.ToString(CultureInfo.InvariantCulture);

    internal static string Bool(bool value) => value ? "true" : "false";

    /// <summary>A string as a JSON literal: quote, backslash and control characters escaped (\n, \r, \t, \b, \f, else \u00xx), the rest as is.</summary>
    internal static string Quote(string text)
    {
        var json = new StringBuilder(text.Length + 2).Append('"');
        foreach (char c in text)
        {
            switch (c)
            {
                case '"': json.Append("\\\""); break;
                case '\\': json.Append("\\\\"); break;
                case '\n': json.Append("\\n"); break;
                case '\r': json.Append("\\r"); break;
                case '\t': json.Append("\\t"); break;
                case '\b': json.Append("\\b"); break;
                case '\f': json.Append("\\f"); break;
                default:
                    if (c < 0x20) json.Append("\\u00").Append(((int)c).ToString("x2", CultureInfo.InvariantCulture));
                    else json.Append(c);
                    break;
            }
        }
        return json.Append('"').ToString();
    }
}

/// <summary>The stable error codes of <see cref="CompanionError"/>.</summary>
public static class CompanionErrorCode
{
    public const string Unauthorized = "unauthorized";
    public const string PairingClosed = "pairingClosed";
    public const string TokenInvalid = "tokenInvalid";
    public const string TokenExpired = "tokenExpired";
    public const string TokenUsed = "tokenUsed";
    public const string Declined = "declined";
    public const string TooManyDevices = "tooManyDevices";
    public const string TooLarge = "tooLarge";
    public const string InvalidPackage = "invalidPackage";
    public const string RateLimited = "rateLimited";
    public const string NotFound = "notFound";
    public const string MethodNotAllowed = "methodNotAllowed";
    public const string BadRequest = "badRequest";
    public const string LengthRequired = "lengthRequired";
    public const string Busy = "busy";
    public const string InboxFull = "inboxFull";
    public const string ServerError = "serverError";
}

/// <summary>What went wrong, for the phone: a stable <paramref name="Code"/> and a sentence to show.</summary>
public sealed record CompanionError(string Code, string Message)
{
    public string ToJson() =>
        $"{{\"error\":{CompanionProtocol.Quote(Code)},\"message\":{CompanionProtocol.Quote(Message)}}}";

    public static CompanionError? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto && dto.Error.Length > 0 ? new CompanionError(dto.Error, dto.Message) : null;

    public static CompanionError Unauthorized { get; } =
        new(CompanionErrorCode.Unauthorized, "This computer no longer recognizes this phone. Pair it again.");
    public static CompanionError PairingClosed { get; } =
        new(CompanionErrorCode.PairingClosed, "Pairing is not open on this computer. Choose Pair a phone there and scan the new code.");
    public static CompanionError TokenInvalid { get; } =
        new(CompanionErrorCode.TokenInvalid, "This pairing code is not valid. Scan the code shown on the computer again.");
    public static CompanionError TokenExpired { get; } =
        new(CompanionErrorCode.TokenExpired, "This pairing code has expired. Show a new code on the computer.");
    public static CompanionError TokenUsed { get; } =
        new(CompanionErrorCode.TokenUsed, "This pairing code was already used. Show a new code on the computer.");
    public static CompanionError Declined { get; } =
        new(CompanionErrorCode.Declined, "Pairing was declined on the computer.");
    public static CompanionError TooManyDevices { get; } =
        new(CompanionErrorCode.TooManyDevices,
            $"This computer is paired with {PairedDeviceStore.MaxDevices} phones already. Remove one there first.");
    public static CompanionError TooLarge { get; } =
        new(CompanionErrorCode.TooLarge, "This file is too large to send in one piece.");
    public static CompanionError RateLimited { get; } =
        new(CompanionErrorCode.RateLimited, "Too many attempts. Wait a minute, then try again.");
    public static CompanionError NotFound { get; } = new(CompanionErrorCode.NotFound, "Not found.");
    public static CompanionError MethodNotAllowed { get; } =
        new(CompanionErrorCode.MethodNotAllowed, "This address does not take that request.");
    public static CompanionError BadRequest { get; } = new(CompanionErrorCode.BadRequest, "The request was not understood.");
    public static CompanionError LengthRequired { get; } =
        new(CompanionErrorCode.LengthRequired, "The request must say how long it is (Content-Length).");
    public static CompanionError Busy { get; } =
        new(CompanionErrorCode.Busy, "This file is still being received. Try again in a moment.");
    public static CompanionError InboxFull { get; } = new(CompanionErrorCode.InboxFull, CompanionInbox.FullMessage);
    public static CompanionError ServerError { get; } =
        new(CompanionErrorCode.ServerError, "The computer could not store this file.");

    private sealed class Dto
    {
        public string Error { get; set; } = "";
        public string Message { get; set; } = "";
    }
}

/// <summary>The body of <c>POST /v1/pair</c>: the pairing code's token and who the phone is.</summary>
public sealed record PairRequest(string Token, string PhoneId, string PhoneName, string Platform, string AppVersion)
{
    public string ToJson() =>
        $"{{\"token\":{CompanionProtocol.Quote(Token)},\"phoneId\":{CompanionProtocol.Quote(PhoneId)}"
        + $",\"phoneName\":{CompanionProtocol.Quote(PhoneName)},\"platform\":{CompanionProtocol.Quote(Platform)}"
        + $",\"appVersion\":{CompanionProtocol.Quote(AppVersion)}}}";

    public static PairRequest? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto
            ? new PairRequest(dto.Token, dto.PhoneId, dto.PhoneName, dto.Platform, dto.AppVersion)
            : null;

    /// <summary>The longest phone name kept, in UTF-8 bytes (longer names are cut).</summary>
    public const int MaxNameBytes = 128;

    private sealed class Dto
    {
        public string Token { get; set; } = "";
        public string PhoneId { get; set; } = "";
        public string PhoneName { get; set; } = "";
        public string Platform { get; set; } = "";
        public string AppVersion { get; set; } = "";
    }
}

/// <summary>
/// The answer to a pairing the user allowed: who the desktop is, the phone's secret and the key
/// packages put in the cloud sync folder are sealed with (<see cref="SyncPackage"/>).
/// </summary>
/// <param name="SyncKey">Base64url of the 32-byte sync key; null from a desktop without the sync folder (left out of the JSON).</param>
public sealed record PairResponse(string DesktopId, string DesktopName, string DeviceSecret, int ProtocolVersion,
                                  string? SyncKey = null)
{
    public string ToJson() =>
        $"{{\"protocolVersion\":{CompanionProtocol.Integer(ProtocolVersion)},\"desktopId\":{CompanionProtocol.Quote(DesktopId)}"
        + $",\"desktopName\":{CompanionProtocol.Quote(DesktopName)},\"deviceSecret\":{CompanionProtocol.Quote(DeviceSecret)}"
        + (SyncKey is null ? "" : $",\"syncKey\":{CompanionProtocol.Quote(SyncKey)}") + "}";

    public static PairResponse? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto
            ? new PairResponse(dto.DesktopId, dto.DesktopName, dto.DeviceSecret, dto.ProtocolVersion, dto.SyncKey)
            : null;

    private sealed class Dto
    {
        [JsonConverter(typeof(WholeNumberConverter))]
        public int ProtocolVersion { get; set; }
        public string DesktopId { get; set; } = "";
        public string DesktopName { get; set; } = "";
        public string DeviceSecret { get; set; } = "";
        public string? SyncKey { get; set; }
    }
}

/// <summary>The answer to <c>GET /v1/health</c>; <paramref name="Paired"/> only when the phone sent valid credentials.</summary>
public sealed record HealthResponse(int ProtocolVersion, bool Paired)
{
    public string ToJson() =>
        $"{{\"service\":{CompanionProtocol.Quote(CompanionProtocol.ServiceName)}"
        + $",\"protocolVersion\":{CompanionProtocol.Integer(ProtocolVersion)},\"paired\":{CompanionProtocol.Bool(Paired)}}}";

    /// <summary>Null unless the body says it is Lazy Print's.</summary>
    public static HealthResponse? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto && dto.Service == CompanionProtocol.ServiceName
            ? new HealthResponse(dto.ProtocolVersion, dto.Paired)
            : null;

    private sealed class Dto
    {
        public string Service { get; set; } = "";
        [JsonConverter(typeof(WholeNumberConverter))]
        public int ProtocolVersion { get; set; }
        public bool Paired { get; set; }
    }
}

/// <summary>The answer to <c>GET /v1/hello</c>: the desktop and the largest upload it takes.</summary>
public sealed record HelloResponse(string DesktopId, string DesktopName, int ProtocolVersion, long MaxUploadBytes)
{
    public string ToJson() =>
        $"{{\"protocolVersion\":{CompanionProtocol.Integer(ProtocolVersion)},\"desktopId\":{CompanionProtocol.Quote(DesktopId)}"
        + $",\"desktopName\":{CompanionProtocol.Quote(DesktopName)}"
        + $",\"maxUploadBytes\":{CompanionProtocol.Integer(MaxUploadBytes)}}}";

    public static HelloResponse? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto
            ? new HelloResponse(dto.DesktopId, dto.DesktopName, dto.ProtocolVersion, dto.MaxUploadBytes)
            : null;

    private sealed class Dto
    {
        [JsonConverter(typeof(WholeNumberConverter))]
        public int ProtocolVersion { get; set; }
        public string DesktopId { get; set; } = "";
        public string DesktopName { get; set; } = "";
        [JsonConverter(typeof(WholeNumberConverter))]
        public long MaxUploadBytes { get; set; }
    }
}

/// <summary>The answer to an upload: the package and whether it had arrived before.</summary>
public sealed record InboxResponse(string PackageId, bool Duplicate)
{
    public string ToJson() =>
        $"{{\"packageId\":{CompanionProtocol.Quote(PackageId)}"
        + $",\"duplicate\":{CompanionProtocol.Bool(Duplicate)}}}";

    public static InboxResponse? FromJson(ReadOnlySpan<byte> json) =>
        CompanionProtocol.Decode<Dto>(json) is { } dto ? new InboxResponse(dto.PackageId, dto.Duplicate) : null;

    private sealed class Dto
    {
        public string PackageId { get; set; } = "";
        public bool Duplicate { get; set; }
    }
}

/// <summary>
/// Reads an int, long or their nullable forms from a JSON number the way Swift's JSONDecoder
/// does: a plain integer in range, or a number written with a fraction or an exponent ("1.0",
/// "3e2") whose value is whole and in range (tried as a double, then as a decimal, as
/// JSONDecoder tries Double and then Decimal). Anything else, strings included, throws, so the
/// lenient property reader falls back to the default. Writes the plain integer.
/// </summary>
internal sealed class WholeNumberConverter : JsonConverterFactory
{
    public override bool CanConvert(Type typeToConvert) =>
        typeToConvert == typeof(int) || typeToConvert == typeof(int?) || typeToConvert == typeof(long) || typeToConvert == typeof(long?);

    public override JsonConverter CreateConverter(Type typeToConvert, JsonSerializerOptions options)
    {
        if (typeToConvert == typeof(int)) return new Int32Converter();
        if (typeToConvert == typeof(int?)) return new NullableConverter<int>(new Int32Converter());
        if (typeToConvert == typeof(long)) return new Int64Converter();
        if (typeToConvert == typeof(long?)) return new NullableConverter<long>(new Int64Converter());
        throw new NotSupportedException($"{typeToConvert.Name} is not a whole-number type.");
    }

    /// <summary>The value of the number token at <paramref name="reader"/> when it is whole and within [min, max].</summary>
    internal static bool TryRead(ref Utf8JsonReader reader, long min, long max, out long value)
    {
        value = 0;
        if (reader.TokenType != JsonTokenType.Number) return false;
        if (reader.TryGetInt64(out long integer))
        {
            value = integer;
            return integer >= min && integer <= max;
        }
        // -2^63 and 2^63 are exact doubles; max + 1 is 2^31 or 2^63.
        if (reader.TryGetDouble(out double number) && double.IsFinite(number) && Math.Floor(number) == number
            && number >= min && number < (double)max + 1)
        {
            value = (long)number;
            return true;
        }
        if (reader.TryGetDecimal(out decimal exact) && decimal.Truncate(exact) == exact && exact >= min && exact <= max)
        {
            value = (long)exact;
            return true;
        }
        return false;
    }

    private sealed class Int32Converter : JsonConverter<int>
    {
        public override int Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            TryRead(ref reader, int.MinValue, int.MaxValue, out long value)
                ? (int)value
                : throw new JsonException("Not a whole number within Int32.");

        public override void Write(Utf8JsonWriter writer, int value, JsonSerializerOptions options) => writer.WriteNumberValue(value);
    }

    private sealed class Int64Converter : JsonConverter<long>
    {
        public override long Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            TryRead(ref reader, long.MinValue, long.MaxValue, out long value)
                ? value
                : throw new JsonException("Not a whole number within Int64.");

        public override void Write(Utf8JsonWriter writer, long value, JsonSerializerOptions options) => writer.WriteNumberValue(value);
    }

    private sealed class NullableConverter<T>(JsonConverter<T> inner) : JsonConverter<T?> where T : struct
    {
        public override T? Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
            reader.TokenType == JsonTokenType.Null ? null : inner.Read(ref reader, typeof(T), options);

        public override void Write(Utf8JsonWriter writer, T? value, JsonSerializerOptions options)
        {
            if (value is { } some) inner.Write(writer, some, options);
            else writer.WriteNullValue();
        }
    }
}

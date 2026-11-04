using System.Buffers.Binary;
using System.Text;
using System.Text.Json.Serialization;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Companion/PrintPackage.swift: the same bytes for the same file, the
// same refusals. The golden file Tests/Fixtures/Companion/print-package.lppkg is written here and
// checked by Swift.

/// <summary>A print package that cannot be made or read; the message is for the phone.</summary>
public sealed class PrintPackageException(string message) : Exception(message);

/// <summary>What a package's header says about the file in it.</summary>
/// <param name="Name">The file's name, with no path.</param>
/// <param name="ContentType">One of <see cref="PrintPackage.ContentTypes"/>.</param>
/// <param name="Batch">The files sent together share it (<see cref="CompanionProtocol.IsValidId"/>).</param>
/// <param name="Index">From 0, the file's place in the batch.</param>
/// <param name="Count">How many files the batch has.</param>
/// <param name="From">The phone's name, for the bar on the desktop.</param>
public sealed record PrintPackageInfo(string Name, string ContentType, string Batch, int Index, int Count, string From)
{
    /// <summary>Where the file's bytes start in the package.</summary>
    public int DataOffset { get; init; }
}

/// <summary>
/// One file for the computer to print: eight bytes of magic, the header's length as four bytes
/// little endian, the header (UTF-8 JSON) and then the file's bytes to the end. The desktop opens
/// what arrives, so a package is accepted by what its first bytes are, not by what the sender says.
/// </summary>
public static class PrintPackage
{
    public const string FileExtension = "lppkg";

    /// <summary>The largest file in a package.</summary>
    public const long MaxFileBytes = 512L * 1024 * 1024;
    public const int MaxHeaderBytes = 65536;
    public const int MaxNameBytes = 255;

    private static readonly byte[] Magic = "LPPKG01\0"u8.ToArray();
    private const int PrefixBytes = 12;
    private const int SniffBytes = 12;

    /// <summary>The largest package: the largest file, its header and the prefix.</summary>
    public const long MaxPackageBytes = MaxFileBytes + MaxHeaderBytes + PrefixBytes;

    public static readonly IReadOnlyList<string> ContentTypes =
        ["application/pdf", "image/jpeg", "image/png", "image/heic", "image/tiff"];

    public const string NotPackageMessage = "This file is not a Lazy Print package.";
    public const string DamagedMessage = "This package is damaged.";
    public const string TooLargeMessage = "This package is too large.";
    public const string NameMessage = "The file's name in this package is not valid.";
    public const string ContentMessage = "The file in this package is not the kind it says it is.";

    public static byte[] Make(string name, string contentType, string batch, int index, int count, string from, ReadOnlySpan<byte> bytes)
    {
        var info = new PrintPackageInfo(name, contentType, batch, index, count, from);
        Check(info);
        if (bytes.Length > MaxFileBytes) throw new PrintPackageException(TooLargeMessage);
        if (!Matches(contentType, bytes)) throw new PrintPackageException(ContentMessage);
        byte[] header = Encoding.UTF8.GetBytes(HeaderJson(info));
        if (header.Length > MaxHeaderBytes) throw new PrintPackageException(DamagedMessage);
        var package = new byte[PrefixBytes + header.Length + bytes.Length];
        Magic.CopyTo(package, 0);
        BinaryPrimitives.WriteUInt32LittleEndian(package.AsSpan(8), (uint)header.Length);
        header.CopyTo(package, PrefixBytes);
        bytes.CopyTo(package.AsSpan(PrefixBytes + header.Length));
        return package;
    }

    /// <summary>
    /// Checks the magic, the header and the first bytes of the file; leaves
    /// <paramref name="stream"/> (which must seek) where the file's bytes start.
    /// </summary>
    public static PrintPackageInfo Read(Stream stream)
    {
        if (stream.CanSeek && stream.Length - stream.Position > MaxPackageBytes) throw new PrintPackageException(TooLargeMessage);
        Span<byte> prefix = stackalloc byte[PrefixBytes];
        if (stream.ReadAtLeast(prefix, PrefixBytes, throwOnEndOfStream: false) < PrefixBytes || !prefix[..Magic.Length].SequenceEqual(Magic))
        {
            throw new PrintPackageException(NotPackageMessage);
        }
        uint length = BinaryPrimitives.ReadUInt32LittleEndian(prefix[8..]);
        if (length is 0 or > MaxHeaderBytes) throw new PrintPackageException(DamagedMessage);
        var header = new byte[length];
        if (stream.ReadAtLeast(header, header.Length, throwOnEndOfStream: false) < header.Length) throw new PrintPackageException(DamagedMessage);
        if (CompanionProtocol.Decode<HeaderDto>(header) is not { } dto) throw new PrintPackageException(DamagedMessage);
        var info = new PrintPackageInfo(dto.Name, dto.ContentType, dto.Batch, dto.Index, dto.Count, dto.From)
        {
            DataOffset = PrefixBytes + header.Length,
        };
        Check(info);
        Span<byte> start = stackalloc byte[SniffBytes];
        int read = stream.ReadAtLeast(start, SniffBytes, throwOnEndOfStream: false);
        if (!Matches(info.ContentType, start[..read])) throw new PrintPackageException(ContentMessage);
        stream.Seek(-read, SeekOrigin.Current);
        return info;
    }

    public static PrintPackageInfo Read(byte[] package) => Read(new MemoryStream(package));

    public static PrintPackageInfo ReadFile(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Read(stream);
    }

    /// <summary>The header's JSON, the keys in the order the golden file has them.</summary>
    internal static string HeaderJson(PrintPackageInfo info) =>
        $"{{\"name\":{CompanionProtocol.Quote(info.Name)},\"contentType\":{CompanionProtocol.Quote(info.ContentType)}"
        + $",\"batch\":{CompanionProtocol.Quote(info.Batch)},\"index\":{CompanionProtocol.Integer(info.Index)}"
        + $",\"count\":{CompanionProtocol.Integer(info.Count)},\"from\":{CompanionProtocol.Quote(info.From)}}}";

    private static void Check(PrintPackageInfo info)
    {
        if (!ContentTypes.Contains(info.ContentType) || !CompanionProtocol.IsValidId(info.Batch)
            || info.Count < 1 || info.Index < 0 || info.Index >= info.Count)
        {
            throw new PrintPackageException(DamagedMessage);
        }
        string name = info.Name;
        if (name.Length == 0 || name is "." or ".." || name.AsSpan().IndexOfAny('/', '\\') >= 0
            || Encoding.UTF8.GetByteCount(name) > MaxNameBytes)
        {
            throw new PrintPackageException(NameMessage);
        }
    }

    private static bool Matches(string contentType, ReadOnlySpan<byte> start) => contentType switch
    {
        "application/pdf" => start.StartsWith("%PDF-"u8),
        "image/jpeg" => start.StartsWith(new byte[] { 0xFF, 0xD8, 0xFF }),
        "image/png" => start.StartsWith(new byte[] { 0x89, 0x50, 0x4E, 0x47 }),
        "image/heic" => start.Length >= 8 && start.Slice(4, 4).SequenceEqual("ftyp"u8),
        "image/tiff" => start.StartsWith("II*\0"u8) || start.StartsWith("MM\0*"u8),
        _ => false,
    };

    private sealed class HeaderDto
    {
        public string Name { get; set; } = "";
        public string ContentType { get; set; } = "";
        public string Batch { get; set; } = "";
        [JsonConverter(typeof(WholeNumberConverter))]
        public int Index { get; set; }
        [JsonConverter(typeof(WholeNumberConverter))]
        public int Count { get; set; }
        public string From { get; set; } = "";
    }
}

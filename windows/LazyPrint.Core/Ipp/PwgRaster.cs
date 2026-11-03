using System.Buffers.Binary;
using System.Text;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/PwgRaster.swift: PWG raster (PWG 5102.4) writer.

/// <summary>
/// One page of a PWG raster file. <see cref="PageWidth"/> and <see cref="PageHeight"/> are points, <see cref="MediaName"/> the
/// PWG media name. <see cref="SheetBack"/> is the printer's sheet-back keyword when this page is the back of a two-sided
/// sheet, null for fronts and for one-sided pages; <see cref="Duplex"/> is set on both sides of a two-sided sheet.
/// <see cref="TotalPages"/> is 0 when unknown.
/// </summary>
public sealed record PwgPageHeader(
    int Width,
    int Height,
    bool Color,
    int Dpi,
    int PageWidth,
    int PageHeight,
    string MediaName,
    bool Duplex = false,
    string? SheetBack = null,
    int Quality = 0,
    int TotalPages = 0);

public static class PwgRaster
{
    public const int HeaderSize = 1796;

    /// <summary>The resolution a job goes at: 300 dpi when listed, else the lowest (square) one, else 300.</summary>
    public static int Resolution(IReadOnlyList<(int X, int Y)> supported)
    {
        if (supported.Contains((300, 300))) return 300;
        var square = supported.Where(r => r.X == r.Y).Select(r => r.X).ToList();
        return square.Count == 0 ? 300 : square.Min();
    }

    public static void WriteFileHeader(Stream output) => output.Write("RaS2"u8);

    /// <summary>Writes a page: its header, then the lines, <paramref name="rows"/> giving line y of the sheet as drawn.</summary>
    public static void WritePage(Stream output, PwgPageHeader header, Func<int, byte[]> rows)
    {
        var (cross, feed) = RasterSheet.Transforms(header.SheetBack);
        int bytesPerPixel = header.Color ? 3 : 1;
        var h = new byte[HeaderSize];
        Text(h, 0, "PwgRaster");
        U32(h, 272, header.Duplex ? 1 : 0);
        U32(h, 276, header.Dpi);
        U32(h, 280, header.Dpi);
        U32(h, 352, header.PageWidth);
        U32(h, 356, header.PageHeight);
        U32(h, 372, header.Width);
        U32(h, 376, header.Height);
        U32(h, 384, 8);
        U32(h, 388, bytesPerPixel * 8);
        U32(h, 392, header.Width * bytesPerPixel);
        U32(h, 396, 0);
        U32(h, 400, header.Color ? 19 : 18);
        U32(h, 420, bytesPerPixel);
        U32(h, 452, header.TotalPages);
        U32(h, 456, cross);
        U32(h, 460, feed);
        U32(h, 484, header.Quality);
        Text(h, 1732, header.MediaName);
        output.Write(h);
        RasterSheet.WriteLines(output, header.Width, header.Height, bytesPerPixel, rows, cross, feed);
    }

    private static void U32(byte[] buffer, int offset, int value) =>
        BinaryPrimitives.WriteUInt32BigEndian(buffer.AsSpan(offset), (uint)value);

    private static void Text(byte[] buffer, int offset, string value)
    {
        byte[] bytes = Encoding.ASCII.GetBytes(value);
        Array.Copy(bytes, 0, buffer, offset, Math.Min(bytes.Length, 63));
    }
}

using System.Buffers.Binary;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/UrfRaster.swift: Apple raster (UNIRAST) writer for AirPrint-only printers.

/// <summary>
/// One page of an Apple raster file. <see cref="SheetBack"/> is the PWG keyword the printer's DM token stands for
/// (<see cref="UrfRaster.SheetBack"/>) when this page is the back of a two-sided sheet, null otherwise.
/// </summary>
public sealed record UrfPageHeader(
    int Width,
    int Height,
    bool Color,
    int Dpi,
    bool Duplex = false,
    string? SheetBack = null,
    int Quality = 0);

public static class UrfRaster
{
    public const int HeaderSize = 32;

    /// <summary>The resolution from the RS token ("RS300-600"): 300 when listed, else the lowest, else 300.</summary>
    public static int Resolution(IReadOnlyList<string> urfSupported)
    {
        var dpis = new List<int>();
        foreach (string token in urfSupported)
        {
            if (!token.StartsWith("RS", StringComparison.Ordinal)) continue;
            foreach (string part in token[2..].Split('-'))
                if (int.TryParse(part, out int dpi) && dpi > 0) dpis.Add(dpi);
        }
        return dpis.Contains(300) || dpis.Count == 0 ? 300 : dpis.Min();
    }

    /// <summary>The sheet-back keyword for the printer's DM token: DM1 normal, DM2 flipped, DM3 rotated, DM4 manual-tumble. DM1 when none is listed.</summary>
    public static string SheetBack(IReadOnlyList<string> urfSupported) =>
        urfSupported.Select(t => t switch { "DM2" => "flipped", "DM3" => "rotated", "DM4" => "manual-tumble", "DM1" => "normal", _ => null })
            .FirstOrDefault(k => k is not null) ?? "normal";

    public static void WriteFileHeader(Stream output, int pageCount)
    {
        var h = new byte[12];
        "UNIRAST"u8.CopyTo(h);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(8), (uint)pageCount);
        output.Write(h);
    }

    /// <summary>Writes a page: its header, then the lines, <paramref name="rows"/> giving line y of the sheet as drawn.</summary>
    public static void WritePage(Stream output, UrfPageHeader header, Func<int, byte[]> rows)
    {
        var (cross, feed) = RasterSheet.Transforms(header.SheetBack);
        int bytesPerPixel = header.Color ? 3 : 1;
        var h = new byte[HeaderSize];
        h[0] = (byte)(bytesPerPixel * 8);
        h[1] = (byte)(header.Color ? 1 : 0);
        h[2] = (byte)(header.Duplex ? 3 : 1);
        h[3] = (byte)header.Quality;
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(12), (uint)header.Width);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(16), (uint)header.Height);
        BinaryPrimitives.WriteUInt32BigEndian(h.AsSpan(20), (uint)header.Dpi);
        output.Write(h);
        RasterSheet.WriteLines(output, header.Width, header.Height, bytesPerPixel, rows, cross, feed);
    }
}

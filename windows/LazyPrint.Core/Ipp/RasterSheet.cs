namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/RasterSheet.swift: the line coding PWG raster and Apple raster share.

internal static class RasterSheet
{
    /// <summary>The (cross-feed, feed) transforms a sheet-back keyword stands for. Unknown keywords are normal.</summary>
    internal static (int Cross, int Feed) Transforms(string? sheetBack) => sheetBack switch
    {
        "rotated" => (-1, -1),
        "flipped" => (1, -1),
        _ => (1, 1),
    };

    /// <summary>
    /// Writes the lines of one page. <paramref name="row"/> returns line y of the sheet as it is drawn (gray bytes or RGB
    /// triples); cross -1 writes each line right to left, feed -1 writes the lines bottom to top.
    /// </summary>
    internal static void WriteLines(Stream output, int width, int height, int bytesPerPixel, Func<int, byte[]> row, int cross, int feed)
    {
        byte[]? previous = null;
        int repeats = 0;
        for (int i = 0; i < height; i++)
        {
            byte[] line = row(feed < 0 ? height - 1 - i : i);
            if (line.Length != width * bytesPerPixel)
                throw new PrintException(new PrintError.BadRaster(i, line.Length, width * bytesPerPixel));
            if (cross < 0)
                line = Reversed(line, bytesPerPixel);
            if (previous is not null && repeats < 256 && line.AsSpan().SequenceEqual(previous))
            {
                repeats++;
                continue;
            }
            if (previous is not null)
                WriteLine(output, previous, bytesPerPixel, repeats);
            previous = (byte[])line.Clone();
            repeats = 1;
        }
        if (previous is not null)
            WriteLine(output, previous, bytesPerPixel, repeats);
    }

    private static byte[] Reversed(byte[] line, int bytesPerPixel)
    {
        var result = new byte[line.Length];
        int pixels = line.Length / bytesPerPixel;
        for (int p = 0; p < pixels; p++)
            Array.Copy(line, p * bytesPerPixel, result, (pixels - 1 - p) * bytesPerPixel, bytesPerPixel);
        return result;
    }

    private static void WriteLine(Stream output, byte[] line, int bpp, int repeats)
    {
        output.WriteByte((byte)(repeats - 1));
        int pixels = line.Length / bpp;
        int i = 0;
        while (i < pixels)
        {
            int run = 1;
            while (i + run < pixels && run < 128 && Same(line, i, i + run, bpp))
                run++;
            if (run >= 2)
            {
                output.WriteByte((byte)(run - 1));
                output.Write(line, i * bpp, bpp);
                i += run;
                continue;
            }
            int literal = 1;
            while (i + literal < pixels && literal < 128
                && !(i + literal + 1 < pixels && Same(line, i + literal, i + literal + 1, bpp)))
                literal++;
            if (literal == 1)
                output.WriteByte(0);
            else
                output.WriteByte((byte)(257 - literal));
            output.Write(line, i * bpp, literal * bpp);
            i += literal;
        }
    }

    private static bool Same(byte[] line, int a, int b, int bpp) =>
        line.AsSpan(a * bpp, bpp).SequenceEqual(line.AsSpan(b * bpp, bpp));
}

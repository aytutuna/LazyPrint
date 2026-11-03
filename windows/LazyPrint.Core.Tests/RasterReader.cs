using System.Buffers.Binary;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/RasterReader.swift: a reader apart from the writers, so the tests do not share their mistakes.

/// <summary>A page as it sits in the file: the header bytes and the decoded lines in file order.</summary>
internal sealed record DecodedPage(byte[] Header, int Width, int Height, int BytesPerPixel, byte[] Pixels)
{
    public byte[] Line(int y) => Pixels.AsSpan(y * Width * BytesPerPixel, Width * BytesPerPixel).ToArray();
}

internal static class RasterReader
{
    public static uint U32(byte[] data, int offset) => BinaryPrimitives.ReadUInt32BigEndian(data.AsSpan(offset));

    public static List<DecodedPage> Pwg(byte[] data)
    {
        Assert.Equal("RaS2", System.Text.Encoding.ASCII.GetString(data, 0, 4));
        var pages = new List<DecodedPage>();
        int pos = 4;
        while (pos < data.Length)
        {
            byte[] header = data[pos..(pos + PwgRaster.HeaderSize)];
            pos += PwgRaster.HeaderSize;
            int width = (int)U32(header, 372), height = (int)U32(header, 376), bpp = (int)U32(header, 388) / 8;
            pages.Add(new DecodedPage(header, width, height, bpp, Lines(data, ref pos, width, height, bpp)));
        }
        return pages;
    }

    public static List<DecodedPage> Urf(byte[] data)
    {
        Assert.Equal("UNIRAST\0", System.Text.Encoding.ASCII.GetString(data, 0, 8));
        int count = (int)U32(data, 8);
        var pages = new List<DecodedPage>();
        int pos = 12;
        for (int i = 0; i < count; i++)
        {
            byte[] header = data[pos..(pos + UrfRaster.HeaderSize)];
            pos += UrfRaster.HeaderSize;
            int width = (int)U32(header, 12), height = (int)U32(header, 16), bpp = header[0] / 8;
            pages.Add(new DecodedPage(header, width, height, bpp, Lines(data, ref pos, width, height, bpp)));
        }
        Assert.Equal(data.Length, pos);
        return pages;
    }

    private static byte[] Lines(byte[] data, ref int pos, int width, int height, int bpp)
    {
        var pixels = new byte[width * height * bpp];
        int y = 0;
        while (y < height)
        {
            int repeat = data[pos++] + 1;
            var line = new byte[width * bpp];
            int x = 0;
            while (x < width)
            {
                int n = data[pos++];
                if (n < 128)
                {
                    for (int k = 0; k <= n; k++)
                        Array.Copy(data, pos, line, (x + k) * bpp, bpp);
                    pos += bpp;
                    x += n + 1;
                }
                else if (n == 128)
                {
                    Array.Fill(line, (byte)0xFF, x * bpp, (width - x) * bpp);
                    x = width;
                }
                else
                {
                    int count = 257 - n;
                    Array.Copy(data, pos, line, x * bpp, count * bpp);
                    pos += count * bpp;
                    x += count;
                }
            }
            Assert.Equal(width, x);
            Assert.True(y + repeat <= height, "line repeat runs past the page");
            for (int k = 0; k < repeat; k++)
                Array.Copy(line, 0, pixels, (y + k) * width * bpp, line.Length);
            y += repeat;
        }
        return pixels;
    }
}

/// <summary>Small test pages: gradient, stripes, repeated lines, a white band and a diagonal.</summary>
internal static class RasterPatterns
{
    public static byte[][] Make(int width, int height, bool color, int seed = 0)
    {
        int bpp = color ? 3 : 1;
        var rows = new byte[height][];
        for (int y = 0; y < height; y++)
        {
            var row = new byte[width * bpp];
            for (int x = 0; x < width; x++)
            {
                byte gray = y switch
                {
                    < 10 => (byte)(x * 4 + seed),
                    < 20 => (byte)((x / 8 % 2 == 0 ? 30 : 220) + seed),
                    < 28 => 255,
                    _ => (byte)(x + y * 3 + seed),
                };
                for (int c = 0; c < bpp; c++)
                    row[x * bpp + c] = c == 0 ? gray : (byte)(gray ^ (c * 0x55));
            }
            rows[y] = row;
        }
        return rows;
    }

    public static byte[] Flat(byte[][] rows) => rows.SelectMany(r => r).ToArray();

    public static byte[][] RotatedHalfTurn(byte[][] rows, int bpp) =>
        rows.Reverse().Select(r => ReversePixels(r, bpp)).ToArray();

    public static byte[] ReversePixels(byte[] row, int bpp)
    {
        var result = new byte[row.Length];
        for (int p = 0; p < row.Length / bpp; p++)
            Array.Copy(row, p * bpp, result, (row.Length / bpp - 1 - p) * bpp, bpp);
        return result;
    }
}

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/TestPage.swift: what a test page shows, as drawing primitives
// the platforms render the same way.

/// <summary>A color in 0 to 255 per channel.</summary>
public readonly record struct TestColor(byte R, byte G, byte B)
{
    public static readonly TestColor Black = new(0, 0, 0);
    public static readonly TestColor White = new(255, 255, 255);
    public static readonly TestColor Cyan = new(0, 255, 255);
    public static readonly TestColor Magenta = new(255, 0, 255);
    public static readonly TestColor Yellow = new(255, 255, 0);
    public static readonly TestColor Red = new(255, 0, 0);
    public static readonly TestColor Green = new(0, 255, 0);
    public static readonly TestColor Blue = new(0, 0, 255);

    /// <summary>A gray: 0 is black, 255 white.</summary>
    public static TestColor Gray(byte level) => new(level, level, level);
}

/// <summary>One thing a test page or a cut mark draws, in points on the sheet.</summary>
public abstract record TestPageItem
{
    private TestPageItem() { }

    /// <summary>A filled rectangle.</summary>
    public sealed record Rect(LayoutRect Bounds, TestColor Fill) : TestPageItem;
    /// <summary>A straight line of the given width.</summary>
    public sealed record Line(LayoutPoint From, LayoutPoint To, double Width, TestColor Color) : TestPageItem;
    /// <summary>A line of text; <paramref name="At"/> is the top-left corner of its line box.</summary>
    public sealed record Text(string Value, LayoutPoint At, double Size, bool Bold) : TestPageItem;
    /// <summary>An arrow filling <paramref name="Bounds"/>, pointing up or down.</summary>
    public sealed record Arrow(LayoutRect Bounds, bool Up) : TestPageItem;
}

/// <summary>What a test page says about the printer.</summary>
public sealed record TestPageInfo(string PrinterName, string Model, string Address, string Date);

public static class TestPage
{
    private const double Millimetre = 72 / 25.4;
    private const double Gutter = 28;

    /// <summary>
    /// The printer's name, model, address and the date; cyan, magenta, yellow, black, red, green and
    /// blue bars; a gray ramp in 10 % steps; a fine-line grid for clogged nozzles; a 1-inch square and
    /// a 10 cm ruler to check real size; and the printable area's edge drawn 2 mm inside it.
    /// </summary>
    public static IReadOnlyList<TestPageItem> Make(PrintableArea area, TestPageInfo info)
    {
        var printable = area.Printable;
        double left = printable.X + Gutter, width = printable.Width - 2 * Gutter, top = printable.Y + Gutter;
        var items = new List<TestPageItem>();

        double inset = 2 * Millimetre;
        var edge = new LayoutRect(printable.X + inset, printable.Y + inset, printable.Width - 2 * inset, printable.Height - 2 * inset);
        AddOutline(items, edge, 0.5);

        items.Add(new TestPageItem.Text(info.PrinterName, new(left, top), 16, true));
        items.Add(new TestPageItem.Text(info.Model, new(left, top + 22), 10, false));
        items.Add(new TestPageItem.Text(info.Address, new(left, top + 38), 10, false));
        items.Add(new TestPageItem.Text(info.Date, new(left, top + 54), 10, false));

        TestColor[] bars = [TestColor.Cyan, TestColor.Magenta, TestColor.Yellow, TestColor.Black, TestColor.Red, TestColor.Green, TestColor.Blue];
        double barWidth = width / bars.Length, barsTop = top + 84;
        for (int i = 0; i < bars.Length; i++)
        {
            items.Add(new TestPageItem.Rect(new(left + i * barWidth, barsTop, barWidth, 48), bars[i]));
        }

        double stepWidth = width / 11, rampTop = barsTop + 68;
        for (int i = 0; i <= 10; i++)
        {
            items.Add(new TestPageItem.Rect(new(left + i * stepWidth, rampTop, stepWidth, 32), TestColor.Gray((byte)Math.Round(255 - 25.5 * i))));
        }

        double rowTop = rampTop + 64;
        for (double offset = 0; offset <= 108; offset += 4)
        {
            items.Add(new TestPageItem.Line(new(left + offset, rowTop), new(left + offset, rowTop + 108), 0.25, TestColor.Black));
            items.Add(new TestPageItem.Line(new(left, rowTop + offset), new(left + 108, rowTop + offset), 0.25, TestColor.Black));
        }

        double squareLeft = left + 160;
        AddOutline(items, new LayoutRect(squareLeft, rowTop, 72, 72), PrintCalibration.LineWidth);
        items.Add(new TestPageItem.Text("1 in", new(squareLeft, rowTop + 78), 10, false));

        // Narrow paper gets a shorter ruler, in whole centimetres.
        int centimetres = Math.Min(10, (int)Math.Floor(width / PrintCalibration.Centimetre));
        double rulerTop = rowTop + 124;
        items.Add(new TestPageItem.Line(new(left, rulerTop), new(left + centimetres * PrintCalibration.Centimetre, rulerTop), PrintCalibration.LineWidth, TestColor.Black));
        for (int k = 0; k <= centimetres; k++)
        {
            double x = left + k * PrintCalibration.Centimetre, length = k % 5 == 0 ? PrintCalibration.LongTick : PrintCalibration.ShortTick;
            items.Add(new TestPageItem.Line(new(x, rulerTop), new(x, rulerTop + length), PrintCalibration.LineWidth, TestColor.Black));
        }
        items.Add(new TestPageItem.Text($"{centimetres} cm",new(left, rulerTop + 28), 10, false));
        return items;
    }

    private static void AddOutline(List<TestPageItem> items, LayoutRect rect, double width)
    {
        double right = rect.X + rect.Width, bottom = rect.Y + rect.Height;
        items.Add(new TestPageItem.Line(new(rect.X, rect.Y), new(right, rect.Y), width, TestColor.Black));
        items.Add(new TestPageItem.Line(new(right, rect.Y), new(right, bottom), width, TestColor.Black));
        items.Add(new TestPageItem.Line(new(right, bottom), new(rect.X, bottom), width, TestColor.Black));
        items.Add(new TestPageItem.Line(new(rect.X, bottom), new(rect.X, rect.Y), width, TestColor.Black));
    }
}

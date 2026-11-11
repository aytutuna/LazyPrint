namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/PaperSize.swift (Lazy Scan's PaperSize, without the scanner
// parts): one paper size model for settings and printing, sizes in points.

/// <summary>
/// A paper size. <see cref="Auto"/> comes first: it is the default and the fallback for a size a
/// newer version adds, and it means the printer's own paper. Stored as the camelCase name
/// ("a4", "b5Jis", "idCard"). Add new sizes after the existing ones.
/// </summary>
public enum PaperSize
{
    Auto,
    Letter,
    Legal,
    Executive,
    A4,
    A5,
    A6,
    B5Jis,
    /// <summary>An ID-1 card (credit card, most ID cards and driving licences), 85.6 × 54 mm.</summary>
    IdCard,
    Photo4x6,
    Photo5x7,
}

/// <summary>Dimensions of the paper sizes and where they apply.</summary>
public static class PaperSizes
{
    /// <summary>A size matches a sheet when each side is within this many points (0.05 in): rounding in drivers.</summary>
    public const double FitTolerance = 0.05 * 72;

    /// <summary>
    /// Countries and territories that use US Letter (the ICU paper-size list): everywhere else
    /// uses A4.
    /// </summary>
    public static readonly IReadOnlyList<string> LetterRegions =
        ["US", "CA", "MX", "PH", "CL", "CO", "CR", "DO", "GT", "NI", "PA", "PR", "SV", "VE"];

    /// <summary>Every size, in declaration order (Automatic first).</summary>
    public static IReadOnlyList<PaperSize> All { get; } = Enum.GetValues<PaperSize>();

    /// <summary>Portrait width × height in points; null for <see cref="PaperSize.Auto"/>.</summary>
    public static LayoutSize? Points(PaperSize size) => Inches(size) is { } inches
        ? new LayoutSize(inches.Width * 72, inches.Height * 72)
        : null;

    /// <summary>The stored name: "auto", "letter", "a4", "b5Jis", "idCard" (the Swift raw values).</summary>
    public static string RawValue(this PaperSize size) => size switch
    {
        PaperSize.Auto => "auto",
        PaperSize.Letter => "letter",
        PaperSize.Legal => "legal",
        PaperSize.Executive => "executive",
        PaperSize.A4 => "a4",
        PaperSize.A5 => "a5",
        PaperSize.A6 => "a6",
        PaperSize.B5Jis => "b5Jis",
        PaperSize.IdCard => "idCard",
        PaperSize.Photo4x6 => "photo4x6",
        PaperSize.Photo5x7 => "photo5x7",
        _ => throw new ArgumentOutOfRangeException(nameof(size), size, null),
    };

    /// <summary>
    /// The size stored as <paramref name="text"/> (its raw value, compared without regard to
    /// case and surrounding spaces); <see cref="PaperSize.Auto"/> for null and anything else.
    /// </summary>
    public static PaperSize Parse(string? text)
    {
        string trimmed = text?.Trim() ?? "";
        foreach (var size in All)
        {
            if (string.Equals(size.RawValue(), trimmed, StringComparison.OrdinalIgnoreCase)) return size;
        }
        return PaperSize.Auto;
    }

    /// <summary>
    /// The usual paper where the user lives: Letter in <see cref="LetterRegions"/>, A4
    /// everywhere else and when the region is unknown. <paramref name="regionCode"/> is a
    /// two-letter ISO 3166 code in any case.
    /// </summary>
    public static PaperSize DefaultForRegion(string? regionCode)
    {
        string code = regionCode?.Trim().ToUpperInvariant() ?? "";
        return LetterRegions.Contains(code) ? PaperSize.Letter : PaperSize.A4;
    }

    /// <summary>
    /// The named size a sheet of <paramref name="points"/> is (a printer's paper), either way round,
    /// each side within <see cref="FitTolerance"/>; null for a size without a name here.
    /// </summary>
    public static PaperSize? Match(LayoutSize points)
    {
        double shortSide = Math.Min(points.Width, points.Height), longSide = Math.Max(points.Width, points.Height);
        if (shortSide <= 0) return null;
        foreach (var size in All)
        {
            if (Points(size) is not { } paper) continue;
            if (Math.Abs(paper.Width - shortSide) <= FitTolerance && Math.Abs(paper.Height - longSide) <= FitTolerance) return size;
        }
        return null;
    }

    /// <summary>The sizes as pickers list them: Automatic, the region's usual size, then the others in declaration order.</summary>
    public static IReadOnlyList<PaperSize> DisplayOrder(string? regionCode)
    {
        var usual = DefaultForRegion(regionCode);
        return [PaperSize.Auto, usual, .. All.Where(size => size != PaperSize.Auto && size != usual)];
    }

    /// <summary>
    /// The size fits <paramref name="area"/> (portrait, within <see cref="FitTolerance"/>).
    /// Automatic always fits, and so does every size when the area is unknown.
    /// </summary>
    public static bool Fits(PaperSize size, LayoutSize? area)
    {
        if (Points(size) is not { } paper || area is not { } a || a.Width <= 0 || a.Height <= 0) return true;
        return paper.Width <= a.Width + FitTolerance && paper.Height <= a.Height + FitTolerance;
    }

    /// <summary>What a picker shows: "Automatic", "Letter", "B5 (JIS)", "ID card".</summary>
    public static string Label(this PaperSize size) => size switch
    {
        PaperSize.Auto => "Automatic",
        PaperSize.Letter => "Letter",
        PaperSize.Legal => "Legal",
        PaperSize.Executive => "Executive",
        PaperSize.A4 => "A4",
        PaperSize.A5 => "A5",
        PaperSize.A6 => "A6",
        PaperSize.B5Jis => "B5 (JIS)",
        PaperSize.IdCard => "ID card",
        PaperSize.Photo4x6 => "4 × 6 in",
        PaperSize.Photo5x7 => "5 × 7 in",
        _ => size.ToString(),
    };

    /// <summary>The dimensions as people know them: "8.5 × 11 in", "210 × 297 mm"; for Automatic, what it prints on.</summary>
    public static string Detail(this PaperSize size) => size switch
    {
        PaperSize.Auto => "The paper in the printer",
        PaperSize.Letter => "8.5 × 11 in",
        PaperSize.Legal => "8.5 × 14 in",
        PaperSize.Executive => "7.25 × 10.5 in",
        PaperSize.A4 => "210 × 297 mm",
        PaperSize.A5 => "148 × 210 mm",
        PaperSize.A6 => "105 × 148 mm",
        PaperSize.B5Jis => "182 × 257 mm",
        PaperSize.IdCard => "85.6 × 54 mm",
        PaperSize.Photo4x6 or PaperSize.Photo5x7 => "Photo paper",
        _ => "",
    };

    private static LayoutSize? Inches(PaperSize size) => size switch
    {
        PaperSize.Letter => new LayoutSize(8.5, 11),
        PaperSize.Legal => new LayoutSize(8.5, 14),
        PaperSize.Executive => new LayoutSize(7.25, 10.5),
        PaperSize.A4 => new LayoutSize(8.2677, 11.6929),
        PaperSize.A5 => new LayoutSize(5.8268, 8.2677),
        PaperSize.A6 => new LayoutSize(4.1339, 5.8268),
        PaperSize.B5Jis => new LayoutSize(7.1654, 10.1181),
        PaperSize.IdCard => new LayoutSize(2.125, 3.370),
        PaperSize.Photo4x6 => new LayoutSize(4, 6),
        PaperSize.Photo5x7 => new LayoutSize(5, 7),
        _ => null,
    };
}

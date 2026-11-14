namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Layout/PhotoLayout.swift: the print sizes a photo can be printed at.

/// <summary>A print size.</summary>
/// <param name="Id">"4x6", "5x7", "8x10", "3.5x5", "wallet", "10x15cm", "13x18cm" or "page".</param>
/// <param name="Title">What a picker shows: "4 × 6 in", "10 × 15 cm", "Largest that fits".</param>
/// <param name="Size">Portrait, in points; null is as large as the cell allows.</param>
public sealed record PhotoSize(string Id, string Title, LayoutSize? Size)
{
    private static LayoutSize Inches(double width, double height) => new(width * 72, height * 72);
    private static LayoutSize Centimetres(double width, double height) => new(width * 72 / 2.54, height * 72 / 2.54);

    public static IReadOnlyList<PhotoSize> All { get; } =
    [
        new("4x6", "4 × 6 in", Inches(4, 6)),
        new("5x7", "5 × 7 in", Inches(5, 7)),
        new("8x10", "8 × 10 in", Inches(8, 10)),
        new("3.5x5", "3.5 × 5 in", Inches(3.5, 5)),
        new("wallet", "Wallet, 2.5 × 3.5 in", Inches(2.5, 3.5)),
        new("10x15cm", "10 × 15 cm", Centimetres(10, 15)),
        new("13x18cm", "13 × 18 cm", Centimetres(13, 18)),
        new("page", "Largest that fits", null),
    ];
}

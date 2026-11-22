using LazyPrint.Core;

namespace LazyPrint.App.Printing;

internal static class PageTurns
{
    /// <summary>A crop given on the page after the user's <paramref name="turns"/>, as it lies on <paramref name="page"/>, the page before them.</summary>
    public static LayoutRect Unturn(LayoutRect crop, LayoutSize page, int turns) => turns switch
    {
        1 => new(crop.Y, page.Height - crop.X - crop.Width, crop.Height, crop.Width),
        2 => new(page.Width - crop.X - crop.Width, page.Height - crop.Y - crop.Height, crop.Width, crop.Height),
        3 => new(page.Width - crop.Y - crop.Height, crop.X, crop.Height, crop.Width),
        _ => crop,
    };
}

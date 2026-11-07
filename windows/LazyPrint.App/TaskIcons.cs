using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>Segoe Fluent Icons glyphs for the task icons (<see cref="TaskDefinition.IconKey"/>).</summary>
public static class TaskIcons
{
    public static string Glyph(string iconKey) => iconKey switch
    {
        "document" => "",
        "twoSided" => "",
        "booklet" => "",
        "handouts" => "",
        "photos" => "",
        "photoSheet" => "",
        "testPage" => "",
        "scanAndPrint" => "",
        "fromPhone" => "",
        _ => "",
    };
}


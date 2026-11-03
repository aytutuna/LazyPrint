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

/// <summary>A task card on the start screen: the task, whether it can be started now, and what it sets.</summary>
public sealed class TaskCardItem(TaskDefinition definition, TaskAvailability availability, bool isCurrent, string summary)
{
    public TaskDefinition Definition { get; } = definition;
    public PrintTask Task => Definition.Task;
    public string Title => Definition.Title;
    public string Subtitle => Definition.Subtitle;
    public string Glyph => TaskIcons.Glyph(Definition.IconKey);
    /// <summary>What the task sets, e.g. "2 per side · Borders".</summary>
    public string Summary { get; } = summary;
    public bool IsAvailable => availability.IsAvailable;
    /// <summary>Why the task cannot be started; null while it can.</summary>
    public string? Reason => availability.Reason;
    public bool IsCurrent { get; } = isCurrent;

    public string HelpText =>
        IsAvailable
            ? $"{Subtitle} {Summary}.{(IsCurrent ? " Current task." : "")}"
            : $"{Subtitle} Not available: {Reason}";
    public string TipDetail => IsAvailable ? Summary : "";
    public string? ShortReason => IsAvailable ? null : Reason ?? "";

    /// <summary>Equal for cards that look and behave the same, so an unchanged grid is not rebuilt (and keeps focus).</summary>
    internal string Signature => string.Join("\u001f", Task, IsAvailable, Reason ?? "", IsCurrent, Summary);
}

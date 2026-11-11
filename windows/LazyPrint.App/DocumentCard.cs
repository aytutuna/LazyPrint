using System.ComponentModel;
using System.Windows.Media;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>One document in the strip under the preview: its name, its pages, its first page as a thumbnail.</summary>
public sealed class DocumentCard(LoadedDocument document) : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    public LoadedDocument Document { get; } = document;

    public string Name => Document.Name;

    public string PagesText => $"{Document.Pages.Count} page{(Document.Pages.Count == 1 ? "" : "s")}";

    /// <summary>The name a screen reader says for the card.</summary>
    public string AutomationName => $"{Name}, {PagesText}";

    public ImageSource? Thumbnail { get; private set; }

    public bool CanMoveEarlier { get; private set; }

    public bool CanMoveLater { get; private set; }

    public bool CanRemove { get; private set; }

    public string EarlierTip { get; private set; } = "Move earlier";

    public string RemoveTip { get; private set; } = "Remove (Delete)";

    public string LaterTip { get; private set; } = "Move later";

    public void SetThumbnail(ImageSource? thumbnail)
    {
        Thumbnail = thumbnail;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Thumbnail)));
    }

    /// <param name="lockedReason">Why the documents cannot change now; null when they can.</param>
    public void SetPosition(int index, int count, string? lockedReason)
    {
        (CanMoveEarlier, CanMoveLater, CanRemove) = (lockedReason is null && index > 0, lockedReason is null && index < count - 1, lockedReason is null);
        (EarlierTip, RemoveTip, LaterTip) = (lockedReason ?? "Move earlier", lockedReason ?? "Remove (Delete)", lockedReason ?? "Move later");
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(string.Empty));
    }
}

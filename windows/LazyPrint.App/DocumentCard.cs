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

    public void SetThumbnail(ImageSource? thumbnail)
    {
        Thumbnail = thumbnail;
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(Thumbnail)));
    }

    public void SetPosition(int index, int count)
    {
        (CanMoveEarlier, CanMoveLater) = (index > 0, index < count - 1);
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CanMoveEarlier)));
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(nameof(CanMoveLater)));
    }
}

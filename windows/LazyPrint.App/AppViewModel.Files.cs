using System.IO;
using System.Runtime.CompilerServices;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App;

// The recent files, and handing a document to Lazy PDF.
public sealed partial class AppViewModel
{
    private RecentFiles? _recentFiles;
    private RecentFiles Recent => _recentFiles ??= new RecentFiles(_directory);

    /// <summary>Where each open document was read from; documents taken from the phone inbox have none.</summary>
    private readonly ConditionalWeakTable<LoadedDocument, string> _sourcePaths = new();

    private bool _lazyPdfInstalled;

    /// <summary>The recent files, newest first. One whose file is gone is dropped from the list as it is found.</summary>
    public IReadOnlyList<string> RecentPaths()
    {
        List<string> found = [];
        foreach (var file in Recent.Load())
        {
            // A network path that is offline can block for seconds; it stays in the list unchecked.
            if (file.Path.StartsWith(@"\\") || File.Exists(file.Path)) found.Add(file.Path);
            else Recent.Remove(file.Path);
        }
        return found;
    }

    private void RememberOpened(IEnumerable<LoadedDocument> opened)
    {
        foreach (var document in opened)
        {
            if (_sourcePaths.TryGetValue(document, out string? path)) Recent.Add(path);
        }
    }

    public void ClearRecent()
    {
        Recent.Clear();
        NotifyAll();
    }

    /// <summary>Looks for Lazy PDF again, off the UI thread: the look can take a couple of seconds.</summary>
    public async Task RefreshLazyPdfAsync() => _lazyPdfInstalled = await Task.Run(_system.LazyPdfInstalled);

    /// <summary>A PDF read from a file of its own can be edited in Lazy PDF, when that is installed.</summary>
    public bool CanEditInLazyPdf(LoadedDocument document) =>
        _lazyPdfInstalled && document.Kind is DocumentKind.Pdf && _sourcePaths.TryGetValue(document, out _);

    public void EditInLazyPdf(LoadedDocument document)
    {
        if (!_sourcePaths.TryGetValue(document, out string? path)) return;
        try
        {
            _system.OpenInLazyPdf(path);
        }
        catch (Exception e)
        {
            ShowFailure("Lazy PDF did not open", e.Message, null);
        }
    }
}

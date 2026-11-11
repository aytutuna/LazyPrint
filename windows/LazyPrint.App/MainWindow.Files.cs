using System.IO;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Microsoft.Win32;

namespace LazyPrint.App;

// Getting files into the print: the picker a task opens with and the Add files button, and files dropped anywhere on the
// window. The view model opens them and says in the error bar which it could not.
public partial class MainWindow
{
    /// <summary>The picker's filter: PDFs, pictures and text together first, then each alone, then every file.</summary>
    private static string FileFilter
    {
        get
        {
            var pictures = string.Join(";", DocumentLoader.PictureExtensions.Select(e => "*" + e));
            var text = string.Join(";", DocumentLoader.TextExtensions.Select(e => "*" + e));
            return $"PDFs, pictures and text|*.pdf;{pictures};{text}|PDFs|*.pdf|Pictures|{pictures}|Text|{text}|All files (*.*)|*.*";
        }
    }

    private void AddFiles_Click(object sender, RoutedEventArgs e) => AskForFiles();

    /// <summary>Asks for files with the picker and takes them.</summary>
    private void AskForFiles()
    {
        if (ViewModel.DocumentsLockedReason is not null) return;
        var dialog = new OpenFileDialog
        {
            Title = "Add files",
            Filter = FileFilter,
            CheckFileExists = true,
            Multiselect = true,
        };
        string documents = Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        if (Directory.Exists(documents)) dialog.InitialDirectory = documents;
        if (dialog.ShowDialog(this) == true) _ = TakeFilesAsync(dialog.FileNames);
    }

    /// <summary>The Recent button: a menu of the files opened before, and Clear recent. Nothing opens when there are none.</summary>
    private void Recent_Click(object sender, RoutedEventArgs e)
    {
        if (ViewModel.DocumentsLockedReason is not null || sender is not Button button) return;
        var menu = new ContextMenu { PlacementTarget = button, Placement = System.Windows.Controls.Primitives.PlacementMode.Bottom };
        foreach (string path in ViewModel.RecentPaths())
        {
            var item = new MenuItem { Header = Path.GetFileName(path).Replace("_", "__"), ToolTip = path };
            item.Click += (_, _) => _ = TakeFilesAsync([path]);
            menu.Items.Add(item);
        }
        if (menu.Items.Count == 0)
        {
            menu.Items.Add(new MenuItem { Header = "No recent files", IsEnabled = false });
        }
        else
        {
            menu.Items.Add(new Separator());
            var clear = new MenuItem { Header = "Clear recent" };
            clear.Click += (_, _) => ViewModel.ClearRecent();
            menu.Items.Add(clear);
        }
        menu.IsOpen = true;
    }

    /// <summary>
    /// Opens the files and shows the print screen. Files that come with no task are added with the settings as they are.
    /// </summary>
    private async Task TakeFilesAsync(IReadOnlyList<string> paths)
    {
        await ViewModel.AddFilesAsync(paths);
        if (ViewModel.Documents.Count > 0) ShowPrintTab();
    }

    private void ShowPrintTab()
    {
        if (ViewModel.SelectedTask is { } task) OpenSectionFor(task);
        MainTabs.SelectedItem = PrintTab;
    }

    /// <summary>
    /// Files named on the command line, or by a second start of the app: the window comes forward and takes them. An
    /// empty list only brings the window forward.
    /// </summary>
    internal void OpenFiles(IReadOnlyList<string> paths)
    {
        if (WindowState == WindowState.Minimized) WindowState = WindowState.Normal;
        Activate();
        if (paths.Count == 0) return;
        _ = TakeFilesAsync(paths);
    }

    /// <summary>Takes the files on the clipboard as a drop would; false when it holds none.</summary>
    private bool PasteFiles()
    {
        string[]? paths;
        try
        {
            // Another program holding the clipboard makes the read throw.
            if (!Clipboard.ContainsFileDropList()) return false;
            var listed = Clipboard.GetFileDropList().Cast<string>().ToList();
            paths = ExistingFiles(listed);
            if (paths is null) return ReportFolders(listed);
        }
        catch (ExternalException)
        {
            return false;
        }
        _ = TakeFilesAsync(paths);
        return true;
    }

    /// <summary>The files a drag carries, when the window takes them now.</summary>
    private string[]? DroppedFiles(DragEventArgs e)
    {
        if ((e.AllowedEffects & DragDropEffects.Copy) == 0) return null;
        return e.Data.GetData(DataFormats.FileDrop) is string[] paths ? ExistingFiles(paths) : null;
    }

    /// <summary>Says so when what was dropped or pasted, with no file in it, held folders; true when it did.</summary>
    private bool ReportFolders(IEnumerable<string> paths)
    {
        var folders = paths.Where(Directory.Exists).ToList();
        if (folders.Count == 0) return false;
        ViewModel.ReportFolders(folders);
        return true;
    }

    /// <summary>Folders are left; any file is taken, and the loader says why one is not a PDF or a picture.</summary>
    private static string[]? ExistingFiles(IEnumerable<string> paths)
    {
        var files = paths.Where(File.Exists).ToArray();
        return files.Length == 0 ? null : files;
    }

    /// <summary>
    /// Files dragged over the window (it takes drops everywhere): the ones it takes show the copy pointer (the files stay
    /// where they are), other drags of files the no-drop pointer. Drags of anything else go on to the control under the pointer.
    /// </summary>
    private void Window_PreviewDragOver(object sender, DragEventArgs e)
    {
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        bool takes = DroppedFiles(e) is not null;
        e.Effects = takes ? DragDropEffects.Copy : DragDropEffects.None;
        ShowDropOverlay(takes);
        e.Handled = true;
    }

    private void Window_PreviewDrop(object sender, DragEventArgs e)
    {
        ShowDropOverlay(false);
        if (!e.Data.GetDataPresent(DataFormats.FileDrop)) return;
        e.Handled = true;
        if (DroppedFiles(e) is not { } paths)
        {
            e.Effects = DragDropEffects.None;
            if (e.Data.GetData(DataFormats.FileDrop) is string[] dropped) ReportFolders(dropped);
            return;
        }
        // A copy: the source keeps its files. Let the drag finish in the other app before the files are opened.
        e.Effects = DragDropEffects.Copy;
        Dispatcher.BeginInvoke(() => _ = TakeFilesAsync(paths));
    }

    private void Window_PreviewDragLeave(object sender, DragEventArgs e) => ShowDropOverlay(false);

    private void ShowDropOverlay(bool show) =>
        DropOverlay.Visibility = show ? Visibility.Visible : Visibility.Collapsed;
}

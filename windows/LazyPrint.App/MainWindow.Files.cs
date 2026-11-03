using System.IO;
using System.Windows;
using LazyPrint.App.Services;
using LazyPrint.Core;
using Microsoft.Win32;

namespace LazyPrint.App;

// Getting files into the print: the picker a task opens with and the Add files button, and files dropped anywhere on the
// window. The view model opens them and says in the error bar which it could not.
public partial class MainWindow
{
    /// <summary>The picker's filter: PDFs and pictures together first, then each alone, then every file.</summary>
    private static string FileFilter
    {
        get
        {
            var pictures = string.Join(";", DocumentLoader.PictureExtensions.Select(e => "*" + e));
            return $"PDFs and pictures|*.pdf;{pictures}|PDFs|*.pdf|Pictures|{pictures}|All files (*.*)|*.*";
        }
    }

    private void AddFiles_Click(object sender, RoutedEventArgs e) => AskForFiles();

    /// <summary>Asks for files with the picker and takes them.</summary>
    private void AskForFiles()
    {
        if (ViewModel.IsBusy) return;
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

    /// <summary>
    /// Opens the files and shows the print screen. Files that come before any task was picked start the plain document task,
    /// so there is something to lay them out by.
    /// </summary>
    private async Task TakeFilesAsync(IReadOnlyList<string> paths)
    {
        if (ViewModel.SelectedTask is null) await ViewModel.StartTaskAsync(PrintTask.Document);
        await ViewModel.AddFilesAsync(paths);
        if (ViewModel.Documents.Count > 0)
        {
            if (ViewModel.SelectedTask is { } task) OpenSectionFor(task);
            MainTabs.SelectedItem = PrintTab;
        }
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
        if (ViewModel.IsBusy)
        {
            ViewModel.ShowNotice("Not added", "Wait for the job to finish, then add the files.");
            return;
        }
        _ = TakeFilesAsync(paths);
    }

    /// <summary>The files a drag carries, when the window takes them now.</summary>
    private string[]? DroppedFiles(DragEventArgs e)
    {
        if (ViewModel.IsBusy || (e.AllowedEffects & DragDropEffects.Copy) == 0) return null;
        if (e.Data.GetData(DataFormats.FileDrop) is not string[] paths) return null;
        // Folders are left; any file is taken, and the loader says why one is not a PDF or a picture.
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

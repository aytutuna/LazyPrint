namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppSpool.swift: the same file rules on both platforms.

/// <summary>
/// A job's document on disk while it is drawn and sent. Sheets are written one at a time, so a
/// job never holds more than one in memory, and the file is sent again as it is for every retry.
/// Disposing deletes the file, whether the job was sent or abandoned.
/// </summary>
public sealed class IppSpool : IDisposable
{
    private static readonly TimeSpan StaleAfter = TimeSpan.FromDays(1);

    private FileStream? _output;

    public string Path { get; }

    /// <summary>Creates an empty spool file in <paramref name="directory"/>, the system's temporary folder by default.</summary>
    public IppSpool(string? directory = null)
    {
        directory ??= System.IO.Path.GetTempPath();
        DeleteStale(directory);
        Path = System.IO.Path.Combine(directory, "lp-" + Guid.NewGuid().ToString("N") + ".spool");
        _output = new FileStream(Path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
    }

    /// <summary>Appends what <paramref name="write"/> puts on the stream: the file header, or one sheet.</summary>
    public void Write(Action<Stream> write)
    {
        write(_output ?? throw new InvalidOperationException("The spool is complete."));
    }

    /// <summary>Closes the file for writing and returns its path, ready to be sent.</summary>
    public string Complete()
    {
        _output?.Dispose();
        _output = null;
        return Path;
    }

    // What a run that was killed left behind.
    private static void DeleteStale(string directory)
    {
        try
        {
            foreach (string file in Directory.EnumerateFiles(directory, "lp-*.spool"))
            {
                if (DateTime.UtcNow - File.GetLastWriteTimeUtc(file) > StaleAfter) File.Delete(file);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }

    public void Dispose()
    {
        _output?.Dispose();
        _output = null;
        try { File.Delete(Path); } catch (IOException) { }
    }
}

using System.Text;

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Companion/CompanionInbox.swift: where uploads from paired phones
// land on the desktop, with the same checks, the same received.json per phone, the same idempotence
// by package id and the same batches.

/// <summary>A package a paired phone sent, checked and waiting in the inbox.</summary>
/// <param name="Path">The package file in the inbox.</param>
public sealed record ReceivedPackage(string DeviceId, string PackageId, string Path, PrintPackageInfo Info,
                                     DateTimeOffset Received);

/// <summary>A package received before (from received.json).</summary>
public sealed class ReceivedEntry
{
    public string PackageId { get; set; } = "";
    public DateTimeOffset? Received { get; set; }
}

/// <summary>The contents of a phone's received.json.</summary>
public sealed class ReceivedLog
{
    public List<ReceivedEntry> Packages { get; set; } = [];
}

/// <summary>A phone has as many files waiting in the inbox as it may; its uploads are refused until some are dealt with.</summary>
public sealed class CompanionInboxFullException(string message) : IOException(message);

/// <summary>
/// The files sent together, as far as they have arrived. A batch is whole when all
/// <paramref name="Count"/> files are in, or <see cref="CompanionInbox.BatchGrace"/> after the last
/// one arrived, so a phone that lost the link does not hold back what got through.
/// </summary>
/// <param name="Count">How many files the phone said the batch has.</param>
/// <param name="Arrived">How many are in the inbox.</param>
public sealed record PhoneBatch(string Id, string From, int Count, int Arrived, DateTimeOffset LastReceived)
{
    public bool IsWhole(DateTimeOffset now) => Arrived >= Count || now - LastReceived >= CompanionInbox.BatchGrace;
}

/// <summary>
/// Where uploads from paired phones land (one folder per phone under the inbox folder). A body is
/// streamed to "&lt;id&gt;.part", must be exactly as long as announced, is read as a
/// <see cref="PrintPackage"/> (header and first bytes checked) and only then renamed to
/// "&lt;id&gt;.lppkg" and logged in received.json, so a package is either received whole and valid
/// or not at all. Uploads are idempotent by package id: one received before is answered from the
/// log (the last <see cref="MaxLoggedPackages"/> per phone), and the same id cannot be received
/// twice at once. Ids are checked by <see cref="CompanionProtocol.IsValidId"/>, so they are safe
/// file names. A phone may have <see cref="MaxWaitingFiles"/> files and <see cref="MaxWaitingBytes"/>
/// bytes waiting at most. <see cref="Take"/> moves a batch to "&lt;batch&gt;/&lt;name&gt;" under the
/// inbox folder with the files' names, made safe; <see cref="Discard"/> deletes a batch. Anything
/// is deleted <see cref="KeepDays"/> days after it arrived. Safe to use from any thread.
/// </summary>
public sealed class CompanionInbox
{
    public const int MaxLoggedPackages = 1000;
    public const string LogFileName = "received.json";
    public const int KeepDays = 7;
    public const int MaxWaitingFiles = 100;
    public const long MaxWaitingBytes = 2L * 1024 * 1024 * 1024;
    public const string FullMessage = "This computer has too many files from your phone waiting. Add or dismiss them on the computer first.";
    public const long MinFreeBytes = 1L * 1024 * 1024 * 1024;
    public static readonly TimeSpan BatchGrace = TimeSpan.FromSeconds(30);

    // The longest name a taken file gets, so that " (2)" and so on still fit in 255 bytes.
    private const int MaxTakenNameBytes = 240;

    private static readonly Dictionary<string, string[]> Extensions = new()
    {
        ["application/pdf"] = [".pdf"],
        ["image/jpeg"] = [".jpg", ".jpeg"],
        ["image/png"] = [".png"],
        ["image/heic"] = [".heic", ".heif"],
        ["image/tiff"] = [".tif", ".tiff"],
    };

    // Windows opens these names as devices, with an extension or without.
    private static readonly HashSet<string> ReservedNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
        "COM0", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM¹", "COM²", "COM³",
        "LPT0", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT¹", "LPT²", "LPT³",
    };

    private readonly string _directory;
    private readonly object _gate = new();
    private readonly HashSet<string> _inProgress = [];
    // What uploads under way have been promised, per phone, so parallel ones count against the quota together.
    private readonly Dictionary<string, (int Files, long Bytes)> _reserved = [];

    /// <summary>The name a paired phone goes by on this computer, null when unknown. A batch shows it instead of the phone's own word.</summary>
    public Func<string, string?> NameOf { get; set; } = _ => null;

    /// <summary>The free bytes on the drive that holds the given folder.</summary>
    public Func<string, long> FreeSpace { get; set; } = FreeSpaceOf;

    public CompanionInbox(string directory)
    {
        _directory = directory;
    }

    /// <summary>The default inbox: %LOCALAPPDATA%\Lazy Print\Companion\Inbox.</summary>
    public static string DefaultDirectory =>
        System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                               "Lazy Print", "Companion", "Inbox");

    /// <summary>The package <paramref name="packageId"/> received from <paramref name="deviceId"/> before; null when it was not.</summary>
    public ReceivedEntry? Find(string deviceId, string packageId)
    {
        Check(deviceId, packageId);
        lock (_gate)
        {
            return Log(deviceId).Packages.FirstOrDefault(p => p.PackageId == packageId);
        }
    }

    /// <summary>Claims the package id for one upload; false while another upload of it runs.</summary>
    public bool TryBegin(string deviceId, string packageId)
    {
        Check(deviceId, packageId);
        lock (_gate) return _inProgress.Add(Key(deviceId, packageId));
    }

    /// <summary>Ends the claim of <see cref="TryBegin"/>.</summary>
    public void End(string deviceId, string packageId)
    {
        lock (_gate) _inProgress.Remove(Key(deviceId, packageId));
    }

    /// <summary>
    /// Receives the package: copies exactly <paramref name="length"/> bytes of
    /// <paramref name="body"/>, checks it and logs it. Throws <see cref="PrintPackageException"/>
    /// for a package that is refused, <see cref="EndOfStreamException"/> when the body ends early,
    /// <see cref="IOException"/> when it cannot be stored, <see cref="CompanionInboxFullException"/>
    /// (before any of the body is read) when the phone has too much waiting; nothing is kept then.
    /// </summary>
    public async Task<ReceivedPackage> ReceiveAsync(string deviceId, string packageId, Stream body, long length,
                                                    DateTimeOffset now, CancellationToken cancellation)
    {
        Check(deviceId, packageId);
        string folder = DeviceFolder(deviceId);
        Reserve(deviceId, folder, length);
        try
        {
            return await ReceiveReservedAsync(deviceId, packageId, folder, body, length, now, cancellation).ConfigureAwait(false);
        }
        finally
        {
            lock (_gate)
            {
                var (files, bytes) = _reserved[deviceId];
                if (files <= 1) _reserved.Remove(deviceId);
                else _reserved[deviceId] = (files - 1, bytes - length);
            }
        }
    }

    private async Task<ReceivedPackage> ReceiveReservedAsync(string deviceId, string packageId, string folder, Stream body,
                                                             long length, DateTimeOffset now, CancellationToken cancellation)
    {
        Directory.CreateDirectory(folder);
        string part = System.IO.Path.Combine(folder, packageId + ".part");
        string final = System.IO.Path.Combine(folder, packageId + "." + PrintPackage.FileExtension);
        try
        {
            await using (var file = new FileStream(part, FileMode.Create, FileAccess.Write, FileShare.None, 81920,
                                                   FileOptions.Asynchronous))
            {
                var buffer = new byte[81920];
                long remaining = length;
                while (remaining > 0)
                {
                    int read = await body.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, remaining)), cancellation).ConfigureAwait(false);
                    if (read == 0) throw new EndOfStreamException("The upload ended before all of it arrived.");
                    await file.WriteAsync(buffer.AsMemory(0, read), cancellation).ConfigureAwait(false);
                    remaining -= read;
                }
            }
            var info = PrintPackage.ReadFile(part);
            File.Move(part, final, overwrite: true);
            File.SetLastWriteTimeUtc(final, now.UtcDateTime);
            lock (_gate)
            {
                var log = Log(deviceId);
                log.Packages.RemoveAll(p => p.PackageId == packageId);
                log.Packages.Add(new ReceivedEntry { PackageId = packageId, Received = now });
                if (log.Packages.Count > MaxLoggedPackages) log.Packages.RemoveRange(0, log.Packages.Count - MaxLoggedPackages);
                if (!StoreFiles.Write(log, LogPath(deviceId)))
                {
                    File.Delete(final);
                    throw new IOException("The list of received files could not be saved.");
                }
            }
            return new ReceivedPackage(deviceId, packageId, final, info, now);
        }
        finally
        {
            TryDelete(part);
        }
    }

    /// <summary>
    /// The batches in the inbox, oldest first, whole or not (<see cref="PhoneBatch.IsWhole"/>).
    /// Files older than <see cref="KeepDays"/> days are deleted first.
    /// </summary>
    public IReadOnlyList<PhoneBatch> Batches(DateTimeOffset now)
    {
        lock (_gate)
        {
            Purge(now);
            return [.. Stored().GroupBy(p => p.Info.Batch).Select(group =>
                    {
                        var first = group.First();
                        string from = NameOf(first.DeviceId) is { Length: > 0 } paired ? paired : PairedDeviceStore.CleanName(first.Info.From);
                        return new PhoneBatch(group.Key, from, group.Max(p => p.Info.Count), group.Count(),
                                              group.Max(p => p.Received));
                    }).OrderBy(batch => batch.LastReceived)];
        }
    }

    /// <summary>
    /// Moves the files of <paramref name="batch"/> to "&lt;batch&gt;/&lt;name&gt;" under the inbox
    /// folder and returns their paths in the order the phone sent them, stamped <paramref name="now"/>
    /// so they are kept <see cref="KeepDays"/> days from now on if the app never deletes them. The name is the sender's word, so it
    /// is made safe: characters Windows does not allow become "_", trailing dots and spaces go, a
    /// device name like NUL gets "_" in front, the extension is the one the content type says
    /// (appended when the name has another) and the stem is cut to fit. A name already taken in the
    /// folder gets " (2)" and so on. A file that cannot be moved stays in the inbox; the others are
    /// still taken.
    /// </summary>
    public IReadOnlyList<string> Take(string batch, DateTimeOffset now)
    {
        if (!CompanionProtocol.IsValidId(batch)) return [];
        lock (_gate)
        {
            string folder = System.IO.Path.Combine(_directory, batch);
            var taken = new List<string>();
            foreach (var package in Stored().Where(p => p.Info.Batch == batch).OrderBy(p => p.Info.Index).ThenBy(p => p.Received))
            {
                string? target = null;
                try
                {
                    Directory.CreateDirectory(folder);
                    target = UniqueName(folder, package.Info);
                    using (var source = new FileStream(package.Path, FileMode.Open, FileAccess.Read, FileShare.Read))
                    using (var destination = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                    {
                        source.Seek(package.Info.DataOffset, SeekOrigin.Begin);
                        source.CopyTo(destination);
                    }
                    File.SetLastWriteTimeUtc(target, now.UtcDateTime);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    System.Diagnostics.Trace.TraceWarning($"Could not take a file from the inbox: {e.Message}");
                    if (target is not null) TryDelete(target);
                    continue;
                }
                TryDelete(package.Path);
                taken.Add(target!);
            }
            return taken;
        }
    }

    /// <summary>Deletes the files of <paramref name="batch"/> that wait in the inbox, without copying them.</summary>
    public void Discard(string batch)
    {
        if (!CompanionProtocol.IsValidId(batch)) return;
        lock (_gate)
        {
            foreach (var package in Stored().Where(p => p.Info.Batch == batch)) TryDelete(package.Path);
        }
    }

    /// <summary>
    /// Deletes the files that <see cref="Take"/> moved out: the folders with no phone's log and no package in them. Run at
    /// launch, for files taken by a run of the app that quit before they were printed or removed.
    /// </summary>
    public void DeleteTaken()
    {
        lock (_gate)
        {
            if (!Directory.Exists(_directory)) return;
            foreach (string folder in Directory.GetDirectories(_directory))
            {
                bool phone = File.Exists(System.IO.Path.Combine(folder, LogFileName))
                    || Directory.EnumerateFiles(folder).Any(path => System.IO.Path.GetExtension(path) is ".part" or "." + PrintPackage.FileExtension);
                if (phone) continue;
                try
                {
                    Directory.Delete(folder, recursive: true);
                }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException)
                {
                    System.Diagnostics.Trace.TraceWarning($"Could not delete files taken from the inbox: {e.Message}");
                }
            }
        }
    }

    /// <summary>The packages waiting in the phones' folders, each header read again; a file that no longer reads is deleted.</summary>
    private List<ReceivedPackage> Stored()
    {
        var stored = new List<ReceivedPackage>();
        if (!Directory.Exists(_directory)) return stored;
        foreach (string folder in Directory.GetDirectories(_directory))
        {
            string deviceId = System.IO.Path.GetFileName(folder);
            if (!CompanionProtocol.IsValidId(deviceId)) continue;
            foreach (string path in Directory.GetFiles(folder, "*." + PrintPackage.FileExtension))
            {
                string packageId = System.IO.Path.GetFileNameWithoutExtension(path);
                if (!CompanionProtocol.IsValidId(packageId)) continue;
                try
                {
                    var info = PrintPackage.ReadFile(path);
                    stored.Add(new ReceivedPackage(deviceId, packageId, path, info,
                                                   new DateTimeOffset(File.GetLastWriteTimeUtc(path), TimeSpan.Zero)));
                }
                catch (Exception e) when (e is IOException or PrintPackageException)
                {
                    TryDelete(path);
                }
            }
        }
        return stored;
    }

    private void Purge(DateTimeOffset now)
    {
        if (!Directory.Exists(_directory)) return;
        var oldest = now.UtcDateTime - TimeSpan.FromDays(KeepDays);
        foreach (string folder in Directory.GetDirectories(_directory))
        {
            foreach (string path in Directory.GetFiles(folder))
            {
                if (System.IO.Path.GetFileName(path) != LogFileName && File.GetLastWriteTimeUtc(path) <= oldest) TryDelete(path);
            }
            try
            {
                if (Directory.GetFileSystemEntries(folder).Length == 0) Directory.Delete(folder);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException)
            {
                System.Diagnostics.Trace.TraceWarning($"Could not delete an empty inbox folder: {e.Message}");
            }
        }
    }

    private static string FileName(PrintPackageInfo info)
    {
        var invalid = System.IO.Path.GetInvalidFileNameChars();
        string name = string.Create(info.Name.Length, info.Name, (span, text) =>
        {
            for (int i = 0; i < span.Length; i++) span[i] = invalid.Contains(text[i]) ? '_' : text[i];
        });
        string[] allowed = Extensions[info.ContentType];
        int dot = name.LastIndexOf('.');
        string extension = dot >= 0 ? name[dot..] : "";
        string stem = name;
        if (allowed.Contains(extension, StringComparer.OrdinalIgnoreCase)) stem = name[..dot];
        else extension = allowed[0];
        stem = CutToBytes(stem.TrimEnd('.', ' '), MaxTakenNameBytes - extension.Length).TrimEnd('.', ' ');
        if (stem.Length == 0) stem = "file";
        int firstDot = stem.IndexOf('.');
        if (ReservedNames.Contains((firstDot >= 0 ? stem[..firstDot] : stem).TrimEnd(' '))) stem = "_" + stem;
        return stem + extension;
    }

    private static string CutToBytes(string text, int limit)
    {
        var cut = new StringBuilder();
        int bytes = 0;
        foreach (var rune in text.EnumerateRunes())
        {
            if (bytes + rune.Utf8SequenceLength > limit) break;
            bytes += rune.Utf8SequenceLength;
            cut.Append(rune.ToString());
        }
        return cut.ToString();
    }

    private static string UniqueName(string folder, PrintPackageInfo info)
    {
        string name = FileName(info);
        string candidate = System.IO.Path.Combine(folder, name);
        string extension = name[name.LastIndexOf('.')..], stem = name[..^extension.Length];
        for (int n = 2; File.Exists(candidate); n++)
        {
            candidate = System.IO.Path.Combine(folder, $"{stem} ({n}){extension}");
        }
        return candidate;
    }

    /// <summary>Deletes everything received from <paramref name="deviceId"/> (the phone was removed).</summary>
    public void RemoveDevice(string deviceId)
    {
        if (!CompanionProtocol.IsValidId(deviceId)) return;
        try
        {
            string folder = DeviceFolder(deviceId);
            if (Directory.Exists(folder)) Directory.Delete(folder, recursive: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not delete a phone's inbox: {e.Message}");
        }
    }

    // Checks the quota and the free disk, then counts the upload against the quota until it ends.
    private void Reserve(string deviceId, string folder, long length)
    {
        lock (_gate)
        {
            _reserved.TryGetValue(deviceId, out var reserved);
            int files = reserved.Files;
            long bytes = reserved.Bytes + length;
            if (Directory.Exists(folder))
            {
                foreach (string path in Directory.EnumerateFiles(folder, "*." + PrintPackage.FileExtension))
                {
                    files++;
                    bytes += new FileInfo(path).Length;
                }
            }
            if (files >= MaxWaitingFiles || bytes > MaxWaitingBytes) throw new CompanionInboxFullException(FullMessage);
            long underWay = _reserved.Values.Sum(r => r.Bytes);
            if (FreeSpace(_directory) - underWay - length < MinFreeBytes) throw new CompanionInboxFullException(FullMessage);
            _reserved[deviceId] = (reserved.Files + 1, reserved.Bytes + length);
        }
    }

    private static long FreeSpaceOf(string folder)
    {
        try
        {
            return new DriveInfo(System.IO.Path.GetPathRoot(System.IO.Path.GetFullPath(folder))!).AvailableFreeSpace;
        }
        catch (Exception e) when (e is IOException or ArgumentException or UnauthorizedAccessException)
        {
            // A drive that cannot be asked (a network share, say) is not held against the upload.
            return long.MaxValue;
        }
    }

    private string DeviceFolder(string deviceId) => System.IO.Path.Combine(_directory, deviceId);

    private string LogPath(string deviceId) => System.IO.Path.Combine(DeviceFolder(deviceId), LogFileName);

    private ReceivedLog Log(string deviceId) => StoreFiles.Load<ReceivedLog>(LogPath(deviceId)) ?? new ReceivedLog();

    private static string Key(string deviceId, string packageId) => deviceId + "/" + packageId;

    private static void Check(string deviceId, string packageId)
    {
        if (!CompanionProtocol.IsValidId(deviceId)) throw new ArgumentException("The phone's id is not valid.", nameof(deviceId));
        if (!CompanionProtocol.IsValidId(packageId)) throw new ArgumentException("The package id is not valid.", nameof(packageId));
    }

    private static void TryDelete(string path)
    {
        try
        {
            if (File.Exists(path)) File.Delete(path);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            System.Diagnostics.Trace.TraceWarning($"Could not delete {System.IO.Path.GetFileName(path)}: {e.Message}");
        }
    }
}

namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/LazyPrintUrl.swift: the same URL, the same files from it. They
// differ only in what a path may be: here a local drive path, there any absolute path.

/// <summary>
/// The address Lazy Scan opens Lazy Print with: <c>lazyprint:open?file=C%3A%5CTemp%5Cscan.pdf</c>,
/// the <c>file</c> parameter repeated for each file. It only ever adds files to the job.
/// </summary>
public static class LazyPrintUrl
{
    public const string Scheme = "lazyprint";

    /// <summary>
    /// The files <paramref name="url"/> asks to add, in order; none for any other address. The
    /// address can come from a web page, so a path that is not a local drive path (<c>C:\...</c>) is
    /// dropped: reading a share (<c>\server\share</c>, <c>\?\UNC\...</c>) would send the user's
    /// credentials to it. Unknown parameters are ignored.
    /// </summary>
    public static IReadOnlyList<string> Parse(string? url)
    {
        if (url is null || !url.StartsWith(Scheme + ":", StringComparison.OrdinalIgnoreCase)) return [];
        string rest = url[(Scheme.Length + 1)..];
        int fragment = rest.IndexOf('#');
        if (fragment >= 0) rest = rest[..fragment];
        string path = rest, query = "";
        int mark = rest.IndexOf('?');
        if (mark >= 0)
        {
            path = rest[..mark];
            query = rest[(mark + 1)..];
        }
        if (path.StartsWith("//", StringComparison.Ordinal)) path = path[2..];
        path = path.Trim('/');
        if (path.Length > 0 && !path.Equals("open", StringComparison.OrdinalIgnoreCase)) return [];
        var files = new List<string>();
        foreach (string pair in query.Split('&'))
        {
            int equals = pair.IndexOf('=');
            if (equals < 0 || pair[..equals] != "file") continue;
            string file = Uri.UnescapeDataString(pair[(equals + 1)..]);
            if (IsLocalDrivePath(file)) files.Add(file);
        }
        return files;
    }

    private static bool IsLocalDrivePath(string path) =>
        path.Length >= 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] is '\\' or '/'
        && !path.Contains('\0');
}

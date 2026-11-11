using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using LazyPrint.Core;
using Microsoft.Win32;

namespace LazyPrint.App.Services;

/// <summary>
/// Opens <c>lazyprint:</c> addresses (<see cref="LazyPrintUrl"/>) with this app, which is how Lazy Scan hands it a scan:
/// the scheme is written for the current user only (HKCU\Software\Classes, never HKLM), each start, pointing at the exe
/// that runs. The app has no installer, so nothing removes it; a value already right is not written again. The file
/// types it opens are added to those types' Open with lists only (OpenWithProgids), never as their default.
/// </summary>
public static class FileAssociation
{
    private const string ProgId = "LazyPrint.File";

    private static readonly string[] Extensions = [".pdf", .. DocumentLoader.PictureExtensions, .. DocumentLoader.TextExtensions];

    /// <summary>The keys under Software\Classes and the value each gets (name "" is the default value), for the app at <paramref name="exePath"/>.</summary>
    public static IReadOnlyList<(string Key, string Name, string Value)> Entries(string exePath)
    {
        string open = $"\"{exePath}\" \"%1\"";
        string application = @"Applications\" + Path.GetFileName(exePath);
        var entries = new List<(string, string, string)>
        {
            (LazyPrintUrl.Scheme, "", "URL:Lazy Print"),
            (LazyPrintUrl.Scheme, "URL Protocol", ""),
            (LazyPrintUrl.Scheme + @"\DefaultIcon", "", $"\"{exePath}\",0"),
            (LazyPrintUrl.Scheme + @"\shell\open\command", "", open),
            (application, "FriendlyAppName", "Lazy Print"),
            (application + @"\shell\open\command", "", open),
            (ProgId, "", "Lazy Print"),
            (ProgId + @"\shell\open\command", "", open),
        };
        foreach (string extension in Extensions)
        {
            entries.Add((application + @"\SupportedTypes", extension, ""));
            entries.Add((extension + @"\OpenWithProgids", ProgId, ""));
        }
        return entries;
    }

    /// <summary>Writes <see cref="Entries"/> under <paramref name="classes"/>; true when anything changed.</summary>
    public static bool Register(RegistryKey classes, string exePath)
    {
        bool changed = false;
        foreach (var (name, valueName, value) in Entries(exePath))
        {
            using var key = classes.CreateSubKey(name);
            if (key.GetValue(valueName) as string == value) continue;
            key.SetValue(valueName, value);
            changed = true;
        }
        return changed;
    }

    /// <summary>
    /// Registers the running exe for the current user and, when that changed anything, tells File
    /// Explorer so its icons follow. A policy that keeps the user's classes read-only leaves it as it was. A packaged
    /// app does nothing: its manifest registers the address, and a key written from inside the package would only be
    /// the package's own copy.
    /// </summary>
    public static void RegisterForCurrentUser()
    {
        if (Packaging.IsPackaged) return;
        if (Environment.ProcessPath is not { } exe) return;
        try
        {
            using var classes = Registry.CurrentUser.CreateSubKey(@"Software\Classes");
            if (Register(classes, exe)) SHChangeNotify(ShcneAssocChanged, ShcnfIdList, IntPtr.Zero, IntPtr.Zero);
        }
        catch (Exception e) when (e is UnauthorizedAccessException or SecurityException or IOException)
        {
        }
    }

    private const int ShcneAssocChanged = 0x08000000;
    private const uint ShcnfIdList = 0x0000;

    [DllImport("shell32.dll", ExactSpelling = true)]
    private static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);
}

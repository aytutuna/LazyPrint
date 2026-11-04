using System.IO;
using System.Runtime.InteropServices;
using System.Security;
using LazyPrint.Core;
using Microsoft.Win32;

namespace LazyPrint.App.Services;

/// <summary>
/// Opens <c>lazyprint:</c> addresses (<see cref="LazyPrintUrl"/>) with this app, which is how Lazy Scan hands it a scan:
/// the scheme is written for the current user only (HKCU\Software\Classes, never HKLM), each start, pointing at the exe
/// that runs. The app has no installer, so nothing removes it; a value already right is not written again.
/// </summary>
public static class FileAssociation
{
    /// <summary>The keys under Software\Classes and the value each gets (name "" is the default value), for the app at <paramref name="exePath"/>.</summary>
    public static IReadOnlyList<(string Key, string Name, string Value)> Entries(string exePath) =>
    [
        (LazyPrintUrl.Scheme, "", "URL:Lazy Print"),
        (LazyPrintUrl.Scheme, "URL Protocol", ""),
        (LazyPrintUrl.Scheme + @"\DefaultIcon", "", $"\"{exePath}\",0"),
        (LazyPrintUrl.Scheme + @"\shell\open\command", "", $"\"{exePath}\" \"%1\""),
    ];

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
    /// Explorer so its icons follow. A policy that keeps the user's classes read-only leaves it as it was.
    /// </summary>
    public static void RegisterForCurrentUser()
    {
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

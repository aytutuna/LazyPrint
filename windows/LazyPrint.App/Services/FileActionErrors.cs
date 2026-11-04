using System.ComponentModel;
using System.Runtime.InteropServices;

namespace LazyPrint.App.Services;

/// <summary>Turns a refused clipboard or shell action into a message for the user.</summary>
internal static class FileActionErrors
{
    public static string Describe(Exception e) => e switch
    {
        COMException { HResult: unchecked((int)0x800401D0) } => "The clipboard is in use by another app. Try again.",
        ExternalException when e.Message.Length > 0 => e.Message,
        Win32Exception win32 => win32.Message,
        _ => e.Message,
    };
}

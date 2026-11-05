using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows;
using LazyPrint.Core;
using Microsoft.Win32;

namespace LazyPrint.App.Services;

/// <summary>
/// Windows facts the troubleshooter reads, kept apart from the calls that read them so they can be tested.
/// Values are from the Windows SDK headers (winsvc.h, netlistmgr.h).
/// </summary>
internal static class WindowsSystemStatus
{
    public const string SpoolerServiceName = "Spooler";

    // SERVICE_STATUS.dwCurrentState
    public const int ServiceStopped = 1;
    public const int ServiceStartPending = 2;
    public const int ServiceStopPending = 3;
    public const int ServiceRunning = 4;
    public const int ServiceContinuePending = 5;
    public const int ServicePausePending = 6;
    public const int ServicePaused = 7;

    // QUERY_SERVICE_CONFIG.dwStartType
    public const int ServiceDisabledStart = 4;

    // NLM_NETWORK_CATEGORY
    public const int NetworkCategoryPublic = 0;
    public const int NetworkCategoryPrivate = 1;
    public const int NetworkCategoryDomainAuthenticated = 2;

    /// <summary>A stopped service set not to start is Disabled; a start type that could not be read counts as stopped.</summary>
    public static ServiceStatus Service(int currentState, int? startType) => currentState switch
    {
        ServiceRunning => ServiceStatus.Running,
        ServiceStartPending or ServiceContinuePending => ServiceStatus.Starting,
        ServiceStopPending => ServiceStatus.Stopping,
        ServicePausePending or ServicePaused => ServiceStatus.Paused,
        ServiceStopped => startType == ServiceDisabledStart ? ServiceStatus.Disabled : ServiceStatus.Stopped,
        _ => ServiceStatus.Unknown,
    };

    public static NetworkStatus Network(int category) => category switch
    {
        NetworkCategoryPublic => NetworkStatus.PublicNetwork,
        NetworkCategoryPrivate => NetworkStatus.PrivateNetwork,
        NetworkCategoryDomainAuthenticated => NetworkStatus.DomainNetwork,
        _ => NetworkStatus.Unknown,
    };
}

/// <summary>
/// The Windows implementation: the spooler through the Service Control Manager (read-only access), the network
/// category through the Network List Manager (COM), Settings through its ms-settings: links.
/// </summary>
public sealed class WindowsSystemDiagnostics : ISystemDiagnostics
{
    public const string PrinterSettingsUri = "ms-settings:printers";
    public const string NetworkSettingsUri = "ms-settings:network-status";

    public ServiceStatus Spooler()
    {
        IntPtr manager = IntPtr.Zero, service = IntPtr.Zero;
        try
        {
            manager = OpenSCManager(null, null, ScManagerConnect);
            if (manager == IntPtr.Zero) return ServiceStatus.Unknown;
            service = OpenService(manager, WindowsSystemStatus.SpoolerServiceName, ServiceQueryStatus | ServiceQueryConfig);
            if (service == IntPtr.Zero)
            {
                return Marshal.GetLastWin32Error() == ErrorServiceDoesNotExist ? ServiceStatus.NotInstalled : ServiceStatus.Unknown;
            }
            if (!QueryServiceStatus(service, out var status)) return ServiceStatus.Unknown;
            return WindowsSystemStatus.Service(status.CurrentState, StartType(service));
        }
        catch (Exception e)
        {
            // Never throws: the troubleshooter shows no spooler check rather than failing.
            Trace.TraceWarning($"Could not read the Print Spooler: {e.Message}");
            return ServiceStatus.Unknown;
        }
        finally
        {
            if (service != IntPtr.Zero) CloseServiceHandle(service);
            if (manager != IntPtr.Zero) CloseServiceHandle(manager);
        }
    }

    /// <summary>The service's start type (QUERY_SERVICE_CONFIG.dwStartType); null when it cannot be read.</summary>
    private static int? StartType(IntPtr service)
    {
        QueryServiceConfig(service, IntPtr.Zero, 0, out uint needed);
        if (Marshal.GetLastWin32Error() != ErrorInsufficientBuffer || needed == 0) return null;
        IntPtr buffer = Marshal.AllocHGlobal((int)needed);
        try
        {
            if (!QueryServiceConfig(service, buffer, needed, out _)) return null;
            // QUERY_SERVICE_CONFIG starts with dwServiceType, then dwStartType.
            return Marshal.ReadInt32(buffer, 4);
        }
        finally
        {
            Marshal.FreeHGlobal(buffer);
        }
    }

    public NetworkStatus Network()
    {
        INetworkListManager? manager = null;
        IEnumNetworks? networks = null;
        try
        {
            var type = Type.GetTypeFromCLSID(NetworkListManagerClsid, throwOnError: false);
            if (type is null) return NetworkStatus.Unknown;
            manager = (INetworkListManager)Activator.CreateInstance(type)!;
            if (!manager.IsConnected) return NetworkStatus.Offline;
            networks = manager.GetNetworks(NlmEnumNetworkConnected);
            var categories = new List<NetworkStatus>();
            while (networks.Next(1, out var network, out int fetched) == 0 && fetched == 1 && network is not null)
            {
                try
                {
                    categories.Add(WindowsSystemStatus.Network(network.GetCategory()));
                }
                finally
                {
                    Marshal.ReleaseComObject(network);
                }
            }
            return categories.Count == 0 ? NetworkStatus.Unknown : Troubleshooter.CombineNetworks(categories);
        }
        catch (Exception e)
        {
            // Never throws: the troubleshooter shows no network check rather than failing.
            Trace.TraceWarning($"Could not read the network category: {e.Message}");
            return NetworkStatus.Unknown;
        }
        finally
        {
            if (networks is not null) Marshal.ReleaseComObject(networks);
            if (manager is not null) Marshal.ReleaseComObject(manager);
        }
    }

    public void OpenSettings(TroubleshootAction action)
    {
        string uri = action switch
        {
            TroubleshootAction.OpenPrinterSettings => PrinterSettingsUri,
            TroubleshootAction.OpenNetworkSettings => NetworkSettingsUri,
            _ => throw new ArgumentOutOfRangeException(nameof(action), action, "Not a Windows Settings page."),
        };
        using var process = Process.Start(new ProcessStartInfo(uri) { UseShellExecute = true });
    }

    public void CopyText(string text)
    {
        var data = new DataObject();
        data.SetText(text, TextDataFormat.UnicodeText);
        // copy: true keeps the text on the clipboard after the app exits.
        Clipboard.SetDataObject(data, copy: true);
    }

    public bool LazyScanInstalled()
    {
        try
        {
            using var key = Registry.ClassesRoot.OpenSubKey("lazyscan");
            if (key is not null) return true;
            // A Lazy Scan installed from the Store may not show its address under HKCR on every Windows build.
            var support = global::Windows.System.Launcher.QueryUriSupportAsync(new Uri("lazyscan:"), global::Windows.System.LaunchQuerySupportType.Uri).AsTask().GetAwaiter().GetResult();
            return support == global::Windows.System.LaunchQuerySupportStatus.Available;
        }
        catch (Exception e)
        {
            Trace.TraceWarning($"Could not look for Lazy Scan: {e.Message}");
            return false;
        }
    }

    public void OpenLazyScan()
    {
        using var process = Process.Start(new ProcessStartInfo("lazyscan:") { UseShellExecute = true });
    }

    public void OpenFolder(string path)
    {
        using var process = Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    }

    // Service Control Manager (winsvc.h); read-only access rights only.

    private const uint ScManagerConnect = 0x0001;
    private const uint ServiceQueryConfig = 0x0001;
    private const uint ServiceQueryStatus = 0x0004;
    private const int ErrorInsufficientBuffer = 122;
    private const int ErrorServiceDoesNotExist = 1060;

    [StructLayout(LayoutKind.Sequential)]
    private struct ServiceStatusRecord
    {
        public int ServiceType;
        public int CurrentState;
        public int ControlsAccepted;
        public int Win32ExitCode;
        public int ServiceSpecificExitCode;
        public int CheckPoint;
        public int WaitHint;
    }

    [DllImport("advapi32.dll", EntryPoint = "OpenSCManagerW", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr OpenSCManager(string? machineName, string? databaseName, uint desiredAccess);

    [DllImport("advapi32.dll", EntryPoint = "OpenServiceW", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    private static extern IntPtr OpenService(IntPtr manager, string serviceName, uint desiredAccess);

    [DllImport("advapi32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceStatus(IntPtr service, out ServiceStatusRecord status);

    [DllImport("advapi32.dll", EntryPoint = "QueryServiceConfigW", CharSet = CharSet.Unicode, SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryServiceConfig(IntPtr service, IntPtr config, uint bufferSize, out uint bytesNeeded);

    [DllImport("advapi32.dll", SetLastError = true, ExactSpelling = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseServiceHandle(IntPtr handle);

    // Network List Manager (netlistmgr.h). Only reading members are called; the others are declared
    // because the interfaces are called through their vtables, in header order.

    private static readonly Guid NetworkListManagerClsid = new("DCB00C01-570F-4A9B-8D69-199FDBA5723B");
    private const int NlmEnumNetworkConnected = 0x01;

    [ComImport, Guid("DCB00000-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetworkListManager
    {
        IEnumNetworks GetNetworks(int flags);
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetwork(Guid networkId);
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetworkConnections();
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetworkConnection(Guid connectionId);
        bool IsConnectedToInternet { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        bool IsConnected { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
    }

    [ComImport, Guid("DCB00003-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface IEnumNetworks
    {
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNewEnum();
        [PreserveSig] int Next(int count, out INetwork? network, out int fetched);
    }

    [ComImport, Guid("DCB00002-570F-4A9B-8D69-199FDBA5723B"), InterfaceType(ComInterfaceType.InterfaceIsDual)]
    private interface INetwork
    {
        [return: MarshalAs(UnmanagedType.BStr)] string GetName();
        void SetName([MarshalAs(UnmanagedType.BStr)] string name);
        [return: MarshalAs(UnmanagedType.BStr)] string GetDescription();
        void SetDescription([MarshalAs(UnmanagedType.BStr)] string description);
        Guid GetNetworkId();
        int GetDomainType();
        [return: MarshalAs(UnmanagedType.IUnknown)] object GetNetworkConnections();
        void GetTimeCreatedAndConnected(out uint lowCreated, out uint highCreated, out uint lowConnected, out uint highConnected);
        bool IsConnectedToInternet { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        bool IsConnected { [return: MarshalAs(UnmanagedType.VariantBool)] get; }
        int GetConnectivity();
        int GetCategory();
    }
}

using System.Runtime.InteropServices;
using System.Text.RegularExpressions;

namespace LazyPrint.App.Services;

/// <summary>
/// Finds the host of a printer on a WSD port. The port's name holds only a GUID; the device node Windows makes for the
/// printer (under the SWD enumerator, its instance id holding that GUID) carries the address the printer announced.
/// </summary>
internal static partial class WsdDevices
{
    private static readonly Guid PnpxKeys = new("656A3BB3-ECC0-43FD-8477-4AE0404A96CD");
    private static readonly Guid DeviceKeys = new("A45C254E-DF1C-4EFD-8020-67D146A850E0");

    // DEVPKEY_PNPX_IpAddress, then DEVPKEY_Device_LocationInfo, which for a WSD device is the URL of its web service.
    private static readonly (Guid Key, uint Id)[] Properties = [(PnpxKeys, 12297), (DeviceKeys, 15)];

    [GeneratedRegex(@"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex PortGuid();

    public static string? HostOf(string port)
    {
        if (PortGuid().Match(port) is not { Success: true } match) return null;
        try
        {
            var values = new List<string?>();
            foreach (string id in DeviceIds().Where(id => id.Contains(match.Value, StringComparison.OrdinalIgnoreCase)))
            {
                if (CM_Locate_DevNodeW(out uint node, id, 0) != 0) continue;
                foreach (var (key, property) in Properties) values.AddRange(Read(node, key, property));
            }
            return PrinterMapping.WsdHost(values);
        }
        catch (Exception e) when (e is DllNotFoundException or EntryPointNotFoundException)
        {
            return null;
        }
    }

    private static IEnumerable<string> DeviceIds()
    {
        if (CM_Get_Device_ID_List_SizeW(out uint length, "SWD", CmGetIdListFilterEnumerator) != 0 || length < 2) return [];
        var buffer = new char[length];
        if (CM_Get_Device_ID_ListW("SWD", buffer, length, CmGetIdListFilterEnumerator) != 0) return [];
        return Split(buffer);
    }

    private static IEnumerable<string> Read(uint node, Guid key, uint id)
    {
        var property = new DevPropKey { Fmtid = key, Pid = id };
        uint size = 0;
        CM_Get_DevNode_PropertyW(node, ref property, out _, null, ref size, 0);
        if (size == 0) return [];
        var bytes = new byte[size];
        if (CM_Get_DevNode_PropertyW(node, ref property, out uint type, bytes, ref size, 0) != 0) return [];
        // A string, or a list of them.
        return type is DevPropTypeString or DevPropTypeStringList ? Split(System.Text.Encoding.Unicode.GetChars(bytes, 0, (int)size)) : [];
    }

    private static IEnumerable<string> Split(char[] chars) =>
        new string(chars).Split('\0', StringSplitOptions.RemoveEmptyEntries);

    private const uint CmGetIdListFilterEnumerator = 1;
    private const uint DevPropTypeString = 0x12;
    private const uint DevPropTypeStringList = 0x2012;

    [StructLayout(LayoutKind.Sequential)]
    private struct DevPropKey
    {
        public Guid Fmtid;
        public uint Pid;
    }

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint CM_Get_Device_ID_List_SizeW(out uint length, string filter, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint CM_Get_Device_ID_ListW(string filter, [Out] char[] buffer, uint length, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint CM_Locate_DevNodeW(out uint node, string deviceId, uint flags);

    [DllImport("cfgmgr32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern uint CM_Get_DevNode_PropertyW(uint node, ref DevPropKey key, out uint type, byte[]? buffer, ref uint size, uint flags);
}

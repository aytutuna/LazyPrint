using System.Text;
using LazyPrint.Core;

namespace LazyPrint.App.Services;

/// <summary>The part of printers.txt before the troubleshooter's checks: the queues, the network services and the rows made of them.</summary>
internal static class PrinterLog
{
    public static string Report(IReadOnlyList<SystemPrinter> queues, IReadOnlyList<IppService> services,
                                IReadOnlyList<PrinterInfo> printers, IReadOnlyDictionary<string, AddressCheck> reads)
    {
        var text = new StringBuilder();
        text.AppendLine("Print queues");
        foreach (var queue in queues)
        {
            text.AppendLine($"  {queue.Name} | driver {queue.Model ?? "-"} | port {queue.Port ?? "-"}"
                            + (queue.IsDefault ? " | default" : "") + (queue.IsVirtual ? " | virtual" : ""));
        }
        if (queues.Count == 0) text.AppendLine("  none");

        text.AppendLine("Network services");
        foreach (var service in services)
        {
            text.AppendLine($"  {service.InstanceName} | {(service.Secure ? "ipps" : "ipp")} | {service.HostName ?? "-"} | "
                            + $"{string.Join(", ", service.Addresses)} | port {service.Port}");
        }
        if (services.Count == 0) text.AppendLine("  none");

        text.AppendLine("Printers");
        foreach (var printer in printers)
        {
            string ipp = printer.IppEndpoint is { } endpoint
                ? $" | network {string.Join(", ", endpoint.Addresses)} | " + Answer(reads.GetValueOrDefault(printer.Id))
                : "";
            text.AppendLine($"  {printer.Id} | {printer.Route} | {printer.State}"
                            + (printer.Problems.Count > 0 ? " | " + string.Join(", ", printer.Problems.Select(p => p.Title)) : "") + ipp);
        }
        return text.ToString();
    }

    private static string Answer(AddressCheck? read) => read switch
    {
        null => "not asked yet",
        { Capabilities: not null } => "answered",
        { Certificate: { } certificate } => $"certificate {certificate.Verdict}",
        _ => read.Error ?? "no answer",
    };
}

using System.Printing;
using LazyPrint.App.Printing;
using LazyPrint.Core;

namespace LazyPrint.App.Services;

/// <summary>The jobs a printer holds, whoever sent them: the spooler's queue for a system printer, Get-Jobs for a network one.</summary>
public sealed class PrinterQueue
{
    private readonly Func<PrinterInfo, IppClient> _connect = IppSheetPrinter.DefaultClient(new IppTrustStore());

    /// <summary>The demo printer, and a printer with no way to ask, have no queue.</summary>
    public static bool Has(PrinterInfo printer) =>
        printer.Route == PrinterRoute.System || printer.Route == PrinterRoute.Ipp && printer.IppEndpoint is not null;

    public Task<IReadOnlyList<QueuedJob>> JobsAsync(PrinterInfo printer, CancellationToken token) =>
        printer.Route == PrinterRoute.System
            ? StaWork.Run(() => Spooled(printer))
            : IppJobsAsync(printer, token);

    public Task CancelAsync(PrinterInfo printer, int id, CancellationToken token) =>
        printer.Route == PrinterRoute.System
            ? StaWork.Run(() =>
            {
                using var server = new LocalPrintServer();
                using var queue = SpoolerPrinter.FindQueue(server, printer);
                try
                {
                    using var job = queue?.GetJob(id);
                    job?.Cancel();
                }
                catch (PrintJobException)
                {
                    // The job finished before the cancel arrived.
                }
                return 0;
            })
            : IppCancelAsync(printer, id, token);

    private async Task<IReadOnlyList<QueuedJob>> IppJobsAsync(PrinterInfo printer, CancellationToken token)
    {
        using var client = _connect(printer);
        return await client.JobsAsync(token);
    }

    private async Task IppCancelAsync(PrinterInfo printer, int id, CancellationToken token)
    {
        using var client = _connect(printer);
        await client.CancelAsync(id, token);
    }

    private static IReadOnlyList<QueuedJob> Spooled(PrinterInfo printer)
    {
        using var server = new LocalPrintServer();
        using var queue = SpoolerPrinter.FindQueue(server, printer);
        if (queue is null) return [];
        var jobs = new List<QueuedJob>();
        using var infos = queue.GetPrintJobInfoCollection();
        foreach (var info in infos)
        {
            using (info)
            {
                if ((info.JobStatus & (PrintJobStatus.Printed | PrintJobStatus.Completed | PrintJobStatus.Deleted | PrintJobStatus.Deleting)) != 0)
                    continue;
                jobs.Add(new QueuedJob(info.JobIdentifier, info.Name ?? "", info.Submitter ?? "", StateOf(info.JobStatus), info.NumberOfPages,
                    string.Equals(info.Submitter, Environment.UserName, StringComparison.OrdinalIgnoreCase)));
            }
        }
        return jobs;
    }

    internal static QueuedJobState StateOf(PrintJobStatus status)
    {
        const PrintJobStatus stuck = PrintJobStatus.Error | PrintJobStatus.Offline | PrintJobStatus.PaperOut
                                     | PrintJobStatus.UserIntervention | PrintJobStatus.Blocked;
        if ((status & stuck) != 0) return QueuedJobState.Stopped;
        if ((status & PrintJobStatus.Paused) != 0) return QueuedJobState.Held;
        if ((status & PrintJobStatus.Printing) != 0) return QueuedJobState.Printing;
        return QueuedJobState.Waiting;
    }
}

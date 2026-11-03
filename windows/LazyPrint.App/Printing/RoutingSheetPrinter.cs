using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App.Printing;

/// <summary>Hands each job to the printer its route names: the system's queue, IPP, or the demo printer.</summary>
public sealed class RoutingSheetPrinter(ISheetPrinter system, ISheetPrinter ipp, ISheetPrinter demo) : ISheetPrinter
{
    public Task PrintAsync(SheetJob job, int pass, IProgress<JobStatus> progress, CancellationToken token)
    {
        var printer = job.Printer.Route switch
        {
            PrinterRoute.System => system,
            PrinterRoute.Ipp => ipp,
            _ => demo,
        };
        return printer.PrintAsync(job, pass, progress, token);
    }
}

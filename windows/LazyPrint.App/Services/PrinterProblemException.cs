using LazyPrint.Core;

namespace LazyPrint.App.Services;

/// <summary>A job stopped by a condition the user can fix ("Out of paper"); the error bar is titled by the problem.</summary>
internal sealed class PrinterProblemException(PrinterProblem problem) : Exception(problem.Advice)
{
    public PrinterProblem Problem { get; } = problem;
}

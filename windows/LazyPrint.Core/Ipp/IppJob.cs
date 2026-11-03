namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Ipp/IppJob.swift: a job as the printer reports it.

/// <summary>The job-state of RFC 8011 §5.3.7. A value the printer sends that is not listed reads as <see cref="Unknown"/>.</summary>
public enum IppJobState
{
    Unknown = 0,
    Pending = 3,
    PendingHeld = 4,
    Processing = 5,
    ProcessingStopped = 6,
    Canceled = 7,
    Aborted = 8,
    Completed = 9,
}

/// <summary>A job on a printer: <see cref="Reasons"/> are its job-state-reasons, <see cref="Impressions"/> the sides printed so far.</summary>
public sealed record IppJob(int Id, IppJobState State, IReadOnlyList<string> Reasons, int Impressions)
{
    /// <summary>The printer is done with it, one way or another.</summary>
    public bool IsFinished => State is IppJobState.Canceled or IppJobState.Aborted or IppJobState.Completed;

    public bool Equals(IppJob? other) =>
        other is not null && Id == other.Id && State == other.State && Impressions == other.Impressions
        && Reasons.SequenceEqual(other.Reasons);

    public override int GetHashCode() => HashCode.Combine(Id, State, Impressions);

    /// <summary>The job a Print-Job or Get-Job-Attributes response describes; <paramref name="id"/> is used when it names none.</summary>
    internal static IppJob? From(IppMessage message, int? id = null)
    {
        int? jobId = message["job-id"]?.Values.FirstOrDefault() is IppValue.Integer number ? number.Value : id;
        if (jobId is not { } known) return null;
        var state = message["job-state"]?.Values.FirstOrDefault() is IppValue.EnumValue { Value: var code }
                    && Enum.IsDefined(typeof(IppJobState), code)
            ? (IppJobState)code
            : IppJobState.Unknown;
        IReadOnlyList<string> reasons = message["job-state-reasons"] is { } attribute
            ? [.. attribute.Values.OfType<IppValue.Keyword>().Select(k => k.Value)]
            : [];
        int impressions = message["job-impressions-completed"]?.Values.FirstOrDefault() is IppValue.Integer done ? done.Value : 0;
        return new IppJob(known, state, reasons, impressions);
    }
}

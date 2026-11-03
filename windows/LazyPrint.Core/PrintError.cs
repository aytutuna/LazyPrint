namespace LazyPrint.Core;

// Twin of Sources/LazyPrintKit/Core/PrintError.swift: what goes wrong when printing, thrown across modules.

/// <summary>Why a print or a conversation with a printer failed; <see cref="Message"/> is for the user.</summary>
public abstract record PrintError
{
    public abstract string Message { get; }

    /// <summary>An answer that is not IPP, or is cut short.</summary>
    public sealed record BadResponse : PrintError
    {
        public override string Message => "The printer's answer could not be read";
    }

    public sealed record Unreachable(string Name, string Reason) : PrintError
    {
        public override string Message => $"Can't reach {Name}: {Reason}";
    }

    /// <summary>The printer answered with an IPP status that is an error.</summary>
    public sealed record Refused(ushort Status, string Detail) : PrintError
    {
        public override string Message => Detail.Length == 0 ? $"The printer refused the job (0x{Status:X4})" : Detail;
    }

    public sealed record NeedsDriver : PrintError
    {
        public override string Message => "This printer needs its driver";
    }

    public sealed record Busy : PrintError
    {
        public override string Message => "The printer is busy";
    }

    public sealed record CertificateChanged : PrintError
    {
        public override string Message => "The printer's certificate has changed";
    }

    /// <summary>A sheet was drawn with the wrong line length for its raster header (a bug, not the printer's doing).</summary>
    public sealed record BadRaster(int Line, int Length, int Expected) : PrintError
    {
        public override string Message => "A page could not be prepared for the printer";
    }

    public sealed record NeedsSignIn : PrintError
    {
        public override string Message => "This printer asks for a sign-in, which Lazy Print can't do yet";
    }

    /// <summary>A file that can't be printed; the sentence says why (<see cref="DocumentText"/>).</summary>
    public sealed record Unreadable(string Sentence) : PrintError
    {
        public override string Message => Sentence;
    }

    public sealed record NoPrinter : PrintError
    {
        public override string Message => PrintText.NoPrinterMessage;
    }
}

/// <summary>A <see cref="PrintError"/> as an exception.</summary>
public sealed class PrintException(PrintError error) : Exception(error.Message)
{
    public PrintError Error { get; } = error;
}

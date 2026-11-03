using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Controls;
using LazyPrint.App.Services;
using LazyPrint.Core;

namespace LazyPrint.App;

/// <summary>
/// "Add printer by address": checks that a printer answers Get-Printer-Attributes at the typed address (asking
/// first when it presents a certificate to trust), then adds it to ipp-hosts.json. On success
/// <see cref="Address"/> is the address it was added under.
/// </summary>
public partial class AddPrinterWindow : Window
{
    private readonly INetworkPrinters _network;
    private CancellationTokenSource? _check;

    /// <summary>The address the printer was added at; null until one was added.</summary>
    public PrinterAddress? Address { get; private set; }

    /// <summary>Asks the user to trust a printer's certificate (replaced in harnesses).</summary>
    internal Func<IppCertificateException, bool> ConfirmCertificate { get; set; }

    public AddPrinterWindow(INetworkPrinters network)
    {
        InitializeComponent();
        Placeholders.Attach(AddressBox, AddressPlaceholder);
        _network = network;
        ConfirmCertificate = certificate =>
            new CertificateTrustWindow(certificate, CertificateTrustWindow.AddAction) { Owner = this }.ShowDialog() == true;
        Loaded += (_, _) => AddressBox.Focus();
        // Closing (Cancel, Esc, the close box) abandons a check in progress.
        Closed += (_, _) => _check?.Cancel();
    }

    private async void Add_Click(object sender, RoutedEventArgs e) => await AddAsync();

    /// <summary>Checks the address and adds the printer; the dialog closes once it is added.</summary>
    internal async Task AddAsync()
    {
        if (_check is not null) return;
        if (!PrinterAddress.TryParse(AddressBox.Text, out var parsed, out string error))
        {
            ShowProblem(error);
            AddressBox.Focus();
            AddressBox.SelectAll();
            return;
        }
        var address = parsed!;
        var secure = address.HttpsFallback(AddressBox.Text.Trim());
        using var cancellation = new CancellationTokenSource();
        _check = cancellation;
        ShowProgress($"Connecting to {address}…");
        try
        {
            var result = await _network.CheckAsync(address, null, cancellation.Token);
            // Closing the dialog cancels, but a check that had already finished still resumes
            // here: nothing may be trusted or added after that.
            if (cancellation.IsCancellationRequested) return;
            // A bare host that did not answer over plain ipp may serve ipps.
            if (result.Capabilities is null && result.Certificate is null && secure is not null)
            {
                address = secure;
                ShowProgress($"Connecting to {address}…");
                result = await _network.CheckAsync(address, null, cancellation.Token);
                if (cancellation.IsCancellationRequested) return;
            }
            // A new certificate is trusted once the printer's UUID shows it is not a changed
            // certificate of a printer trusted before; a changed one is asked about as such.
            bool firstUseAsked = false, trusted = false;
            while (!trusted && result.Certificate is { CanTrust: true } certificate)
            {
                ShowProgress("Confirm the printer's certificate to continue.");
                if (!ConfirmCertificate(certificate))
                {
                    ShowProblem("The printer was not added, because its certificate was not trusted.");
                    return;
                }
                if (cancellation.IsCancellationRequested) return;
                ShowProgress($"Connecting to {address}…");
                if (certificate.Verdict == IppTrustVerdict.Unknown && !firstUseAsked)
                {
                    firstUseAsked = true;
                    result = await _network.CheckAsync(address, certificate.Fingerprint, cancellation.Token);
                }
                else
                {
                    _network.Trust(certificate, deviceUuid: null, certificate.DeviceName);
                    trusted = true;
                    result = await _network.CheckAsync(address, null, cancellation.Token);
                }
                if (cancellation.IsCancellationRequested) return;
            }
            if (result.Capabilities is { } capabilities)
            {
                // The address that answered: the client may have moved from ipp to ipps on its own.
                Address = result.Address;
                _network.Add(result.Address, capabilities);
                if (IsVisible) DialogResult = true;
                return;
            }
            ShowProblem(result.Certificate?.Message ?? result.Error ?? $"No printer answered at {address}.");
        }
        catch (OperationCanceledException)
        {
            // The dialog was closed while checking.
        }
        finally
        {
            _check = null;
            AddButton.IsEnabled = true;
            AddressBox.IsReadOnly = false;
            Progress.Visibility = Visibility.Collapsed;
        }
    }

    private void AddressBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        // A message about the previous text no longer applies.
        if (_check is null) StatusPanel.Visibility = Visibility.Collapsed;
    }

    private void ShowProgress(string text)
    {
        AddButton.IsEnabled = false;
        AddressBox.IsReadOnly = true;
        StatusGlyph.Visibility = Visibility.Collapsed;
        Progress.Visibility = Visibility.Visible;
        SetStatus(text);
    }

    private void ShowProblem(string text)
    {
        StatusGlyph.Visibility = Visibility.Visible;
        Progress.Visibility = Visibility.Collapsed;
        SetStatus(text);
    }

    /// <summary>Error or progress text the dialog currently shows (harnesses read it).</summary>
    internal string StatusMessage => StatusPanel.Visibility == Visibility.Visible ? StatusText.Text : "";

    private void SetStatus(string text)
    {
        StatusText.Text = text;
        StatusPanel.Visibility = Visibility.Visible;
        var peer = UIElementAutomationPeer.FromElement(StatusText) ?? UIElementAutomationPeer.CreatePeerForElement(StatusText);
        peer?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }
}

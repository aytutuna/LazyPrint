using System.IO;
using System.Net;
using System.Net.Security;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using LazyPrint.App.Services;
using LazyPrint.App.Services.Companion;
using LazyPrint.Core;
using Xunit;

namespace LazyPrint.App.Tests;

// The phone link's Windows pieces: the firewall and network readers (read only) and the certificate
// kept in the user's store. Windows only; the protocol and its loopback tests are in
// LazyPrint.Core.Tests. DNS-SD is never exercised here: it would advertise on the real network.

/// <summary>
/// A test that adds a certificate and a key to a store of the user's own (named for the tests) and
/// removes them again. It runs where LAZYPRINT_CERT_STORE_TESTS=1 (CI); elsewhere it is
/// skipped, so a developer's certificate stores are left alone.
/// </summary>
public sealed class CertificateStoreFactAttribute : FactAttribute
{
    public CertificateStoreFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("LAZYPRINT_CERT_STORE_TESTS") != "1")
        {
            Skip = "Set LAZYPRINT_CERT_STORE_TESTS=1 to let this test use a certificate store of its own.";
        }
    }
}

public class CompanionAppTests
{
    [Fact]
    public void FirewallState_JudgesTheNetworksReceivedOn()
    {
        const string app = @"C:\Program Files\Lazy Print\LazyPrint.exe";
        // Allowed for Private at the firewall's question, which blocks Public; a public virtual switch is connected too.
        FirewallRule[] rules =
        [
            new("Lazy Print", app, true, true, true, FirewallProfiles.Private, 6, "*"),
            new("Lazy Print", app, true, false, true, FirewallProfiles.Public, 6, "*"),
        ];
        var state = new FirewallState(true, FirewallProfiles.Private | FirewallProfiles.Public, true, rules,
                                      FirewallProfiles.Domain | FirewallProfiles.Private | FirewallProfiles.Public);
        Assert.Equal(CompanionFirewallVerdict.Blocked, state.Verdict(app, 52732));
        Assert.Equal(CompanionFirewallVerdict.Allowed, state.Verdict(app, 52732, FirewallProfiles.Private));
        Assert.Empty(state.BlockingRules(app, FirewallProfiles.Private));
        Assert.Equal(CompanionFirewallVerdict.Blocked, state.Verdict(app, 52732, FirewallProfiles.Public));
        Assert.Equal(["Lazy Print"], state.BlockingRules(app, FirewallProfiles.Public));
        // The firewall off for the profile received on.
        var privateOff = state with { EnabledProfiles = FirewallProfiles.Public };
        Assert.Equal(CompanionFirewallVerdict.Off, privateOff.Verdict(app, 52732, FirewallProfiles.Private));
        Assert.Empty(privateOff.BlockingRules(app, FirewallProfiles.Private));
        Assert.Equal(CompanionFirewallVerdict.Unknown, FirewallState.Unknown.Verdict(app, 52732, FirewallProfiles.Private));
        Assert.Empty(FirewallState.Unknown.BlockingRules(app));
    }

    [Fact]
    public void FirewallReader_ReadsWithoutChangingAnything()
    {
        // A program that has no rules: whatever the firewall says, nothing is about it.
        string path = Path.Combine(Path.GetTempPath(), "LazyPrint-no-such-program-" + Guid.NewGuid().ToString("N") + ".exe");
        var state = FirewallReader.Read(path);
        Assert.Empty(state.Rules);
        if (state.Read)
        {
            Assert.Contains(state.Verdict(path, CompanionProtocol.DefaultPort),
                            new[] { CompanionFirewallVerdict.WillAsk, CompanionFirewallVerdict.Off });
        }
        else
        {
            Assert.Equal(CompanionFirewallVerdict.Unknown, state.Verdict(path, CompanionProtocol.DefaultPort));
        }
    }

    [Fact]
    public void NetworkSource_ReadsTheConnectedNetworks()
    {
        using var source = new WindowsNetworkSource();
        var networks = source.Networks();
        foreach (var network in networks)
        {
            Assert.StartsWith("{", network.Id);
            Assert.All(network.Interfaces, adapter => Assert.True(Guid.TryParse(adapter.AdapterId, out _)));
        }
    }

    [CertificateStoreFact]
    public async Task Certificate_IsKeptRenewedWithItsKeyAndServesTls()
    {
        const string storeName = "LazyPrintTests";
        var store = new CompanionCertificateStore(storeName, StoreLocation.CurrentUser);
        try
        {
            var first = store.Current();
            Assert.True(first.HasPrivateKey);
            using (var key = first.GetECDsaPublicKey())
            {
                Assert.Equal(256, key!.KeySize);
            }
            Assert.Equal(CompanionCertificateStore.FriendlyName, first.FriendlyName);
            byte[] pin = SpkiFingerprint.Of(first.RawData)!;
            // A second store object (the next app start) finds the same certificate.
            var again = new CompanionCertificateStore(storeName, StoreLocation.CurrentUser).Current();
            Assert.Equal(first.Thumbprint, again.Thumbprint);

            // SChannel serves TLS with the stored key (an ephemeral one would fail here).
            using var listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start();
            int port = ((IPEndPoint)listener.LocalEndpoint).Port;
            var serve = Task.Run(async () =>
            {
                using var client = await listener.AcceptTcpClientAsync();
                await using var tls = new SslStream(client.GetStream());
                await tls.AuthenticateAsServerAsync(again, false, false);
            });
            using (var tcp = new TcpClient())
            {
                await tcp.ConnectAsync(IPAddress.Loopback, port);
                await using var tls = new SslStream(tcp.GetStream(), false,
                    (_, certificate, _, _) => certificate is not null && SpkiFingerprint.Matches(SpkiFingerprint.Of(certificate.GetRawCertData())!, pin));
                await tls.AuthenticateAsClientAsync("localhost");
                Assert.True(tls.IsAuthenticated);
            }
            await serve.WaitAsync(TimeSpan.FromSeconds(10));

            // Reset pairing: a new key, so the old pin no longer matches.
            var renewed = store.Renew();
            Assert.False(SpkiFingerprint.Matches(SpkiFingerprint.Of(renewed.RawData)!, pin));
            using var check = new X509Store(storeName, StoreLocation.CurrentUser);
            check.Open(OpenFlags.ReadOnly);
            Assert.Single(check.Certificates.Cast<X509Certificate2>(), c => c.FriendlyName == CompanionCertificateStore.FriendlyName);
        }
        finally
        {
            EmptyStore(storeName);
        }
    }

    [CertificateStoreFact]
    public void Certificate_KeepsTheOldOneWhenNoNewKeyCanBeMade()
    {
        const string storeName = "LazyPrintTestsRenew";
        var store = new CompanionCertificateStore(storeName, StoreLocation.CurrentUser);
        try
        {
            var first = store.Current();
            string keyName = KeyName(first)!;
            Assert.True(CngKey.Exists(keyName));

            // Reset pairing when no key can be made: it fails, and the old certificate and key stay.
            var makeKey = store.NewKey;
            store.NewKey = () => throw new CryptographicException("The key storage provider is not available.");
            Assert.Throws<CryptographicException>(() => store.Renew());
            Assert.Equal(first.Thumbprint, store.Current().Thumbprint);
            Assert.True(CngKey.Exists(keyName));
            var reopened = new CompanionCertificateStore(storeName, StoreLocation.CurrentUser).Current();
            Assert.Equal(first.Thumbprint, reopened.Thumbprint);
            Assert.True(reopened.HasPrivateKey);

            // Once a key can be made, the reset replaces the certificate and deletes the old key.
            store.NewKey = makeKey;
            var renewed = store.Renew();
            Assert.NotEqual(first.Thumbprint, renewed.Thumbprint);
            Assert.Equal(renewed.Thumbprint, store.Current().Thumbprint);
            Assert.False(CngKey.Exists(keyName));
            using var check = new X509Store(storeName, StoreLocation.CurrentUser);
            check.Open(OpenFlags.ReadOnly);
            Assert.Single(check.Certificates.Cast<X509Certificate2>(), c => c.FriendlyName == CompanionCertificateStore.FriendlyName);
        }
        finally
        {
            EmptyStore(storeName);
        }
    }

    private static string? KeyName(X509Certificate2 certificate)
    {
        using var key = certificate.GetECDsaPrivateKey();
        return (key as ECDsaCng)?.Key.KeyName;
    }

    /// <summary>Removes every certificate and its key from the tests' own store.</summary>
    private static void EmptyStore(string storeName)
    {
        using var cleanup = new X509Store(storeName, StoreLocation.CurrentUser);
        cleanup.Open(OpenFlags.ReadWrite);
        foreach (var certificate in cleanup.Certificates.Cast<X509Certificate2>().ToList())
        {
            try
            {
                using var key = certificate.GetECDsaPrivateKey();
                if (key is ECDsaCng cng) cng.Key.Delete();
            }
            catch (CryptographicException)
            {
            }
            cleanup.Remove(certificate);
        }
    }
}

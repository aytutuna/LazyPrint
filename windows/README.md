# Lazy Print for Windows

The Windows app is .NET 10 and WPF. The solution is `LazyPrint.sln`, with four projects.

`LazyPrint.Core` is the shared logic: page layout, the IPP codec and client, printer problems, settings, the troubleshooter and the phone link (`Companion/`). It targets plain `net10.0`. Its only package is `System.Security.Cryptography.ProtectedData`, which keeps the phone link's sync keys under DPAPI. `LazyPrint.App` is the WPF app and builds `LazyPrint.exe`. It targets `net10.0-windows10.0.19041.0` for the WinRT PDF and device-watcher APIs, and uses ZXing.Net for the pairing QR code. `LazyPrint.Core.Tests` and `LazyPrint.App.Tests` are xUnit projects. The App tests need WPF but no window and no printer; they use a loopback IPP printer and stand-in services.

Core mirrors `Sources/LazyPrintKit` in the Swift package, with the same file and type names. The golden files both sides read are in `../Tests/Fixtures`. `../CONTRACTS.md` describes the app and the phone link in detail.

## Build, test, run

From the repo root:

```
dotnet build windows/LazyPrint.sln -c Release
dotnet test windows/LazyPrint.sln
dotnet run --project windows/LazyPrint.App
```

Two tests in `LazyPrint.App.Tests` (`CompanionAppTests`, the phone link's certificate) are skipped locally. They create and remove certificates in the Windows certificate store, so they only run when `LAZYPRINT_CERT_STORE_TESTS=1` is set, which CI does on its runner. To run them on your own machine, set it in the shell first:

```
$env:LAZYPRINT_CERT_STORE_TESTS = '1'
dotnet test windows/LazyPrint.sln
```

## What the app registers

At each start the app writes the `lazyprint:` scheme under `HKCU\Software\Classes\lazyprint`, pointing at the running exe, so Lazy Scan can open it with files to print. Nothing is written to `HKLM`. Only one instance runs per user session; a second start passes its files to the first.

## The phone link

While a phone is paired, or a pairing code is on screen, the app listens for TLS connections on a TCP port (52732 by default) and announces itself on the local network as `_lazyprint._tcp`. It does this on trusted networks only, and takes at most 8 connections, 4 of them from one address. The app does not add or change any Windows Defender Firewall rule. It reads the rules (`FirewallReader`) and tells the user in the phone window whether the port is allowed, blocked by a rule, or will make Windows ask the first time. The decision is in `LazyPrint.Core/Companion/CompanionFirewall.cs`.

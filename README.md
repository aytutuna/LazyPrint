# Lazy Print

A native printing app for Windows, Mac and iPhone: documents and photos to driverless IPP printers, with guided two-sided printing and a troubleshooter for the printer that does not show up. It is the sister of Lazy Scan and shares its layout and conventions.

You pick a task (print a document, print photos, a booklet, several pages to a sheet, a test page), drop files in, and see the sheets as they will come out before anything is sent. Printers come from the system's own list and from the network: on a network the app finds IPP printers by DNS-SD, and a printer that does not announce itself can be added by address. A printer that only prints one side gets a two-sided card that walks through printing the fronts, reloading the paper and printing the backs, with a one-sheet check first so the reload guess can be tested. When a printer is missing or stops, the troubleshooter reads what the system and the network report and says what is wrong in plain words. There is also a demo printer that writes to a folder, for trying the app without hardware.

The phone link lets an iPhone pair with the computer by scanning a QR code and then send files to it. They arrive in a bar at the top of the window; nothing prints until you choose to add them to a job or start a new one. The link is local only, over TLS on the home network, and the phone pins the computer's certificate from the pairing code.

Lazy Print and Lazy Scan open each other through the `lazyprint:` and `lazyscan:` addresses. "Print with Lazy Print" in Lazy Scan sends it a scan to print, and the Scan and print task here opens Lazy Scan.

## Status

The app has only been tested by its automated suites and by CI. It has not yet been run against a real printer, a real iPhone or a real Mac.

## Layout

The code is written twice. `windows/LazyPrint.Core` (C#) and `Sources/LazyPrintKit` (Swift) are twins: the same folders (`Core`, `Ipp`, `Layout`, `Companion`), the same file and type names, and the same tests in `windows/LazyPrint.Core.Tests` and `Tests/LazyPrintTests`. Golden files in `Tests/Fixtures` (`Documents`, `Ipp`, `Companion`) are read by both test suites, so the two sides are checked against the same bytes.

`CONTRACTS.md` is the spec. It says what each module does, the names both sides use, the wire formats and what the tests check. Change it with the code.

```
CONTRACTS.md          the spec
Sources/LazyPrintKit  shared Swift core (no AppKit, UIKit or SwiftUI)
Sources/LazyPrintMac  Mac views and system services
Sources/LazyPrint     Mac app entry point
Sources/LazyPrintIOS  iPhone views and services
Tests/                Swift tests and Tests/Fixtures
ios/project.yml       XcodeGen spec for the iPhone app
windows/              C# solution, see windows/README.md
scripts/              app bundle script and fixture generators
```

## Build and test

Windows needs the .NET 10 SDK:

```
dotnet build windows/LazyPrint.sln -c Release
dotnet test windows/LazyPrint.sln
dotnet run --project windows/LazyPrint.App
```

The Mac needs Xcode 16.4 or later. The package targets macOS 14 and iOS 18:

```
swift build
swift test --parallel
bash scripts/make_app.sh
```

`make_app.sh` writes `dist/Lazy Print.app`. The iPhone app's Xcode project is not checked in; XcodeGen writes it from `ios/project.yml`:

```
xcodegen generate --spec ios/project.yml
```

The package's own scheme, `LazyPrint-Package`, runs the shared and iPhone tests on a simulator with `xcodebuild test`. The app's UI tests use the generated project and the `LazyPrintiOS` scheme.

The Swift side cannot be built or run on Windows, so it is checked on CI.

## CI

`.github/workflows/ci.yml` runs on pushes to `main` and `ci/**` branches and on pull requests to `main`. The `windows` job builds and tests the solution. The `macos` job runs `swift build`, `swift test --parallel` and builds the app bundle. The `ios` job runs after it and runs the package tests and the app's UI tests on the iOS Simulator. A change to the Swift code is only known to work once these jobs are green.

## Release

Three workflows run by hand only, from the Actions tab. None of them has been run yet.

- `release.yml` builds the Windows and Mac apps and attaches them to the run as artifacts. `lazyprint-windows` is `dotnet publish` output zipped (framework-dependent, so it needs the .NET 10 Desktop Runtime). `lazyprint-mac` is `Lazy Print.app` from `scripts/make_app.sh`, ad-hoc signed and not notarised, and built for Apple silicon only, so a downloaded copy needs System Settings, Privacy & Security, Open Anyway once (Control-click, Open on macOS 14). Neither is an installer, as with Lazy Scan.
- `testflight.yml` archives the iPhone app (bundle id `com.lazyprint.lazyprint`), signs it on export and uploads it to TestFlight. The run number is the build number.
- `pages.yml` publishes `site/` to GitHub Pages. The pages are plain HTML and CSS; open `site/index.html` to preview them.

`testflight.yml` reads four repository secrets, the same names Lazy Scan uses: `APPLE_TEAM_ID`, `APPSTORE_ISSUER_ID`, `APPSTORE_KEY_ID` and `APPSTORE_PRIVATE_KEY` (the contents of the `.p8` file). It stops at the first step when one is missing. `release.yml` and `pages.yml` need none.

GitHub lists a manually run workflow only when its file is on the default branch, and Pages deploys are tied to it too. Push `main` to the repository and make it the default branch before using any of these.

Only the owner can do these:

- Push `main` and set it as the default branch (Settings, Branches). Today only `ci/*` branches are on GitHub.
- Join the Apple Developer Program and give the account's team id as `APPLE_TEAM_ID`.
- Create the app in App Store Connect with the bundle id `com.lazyprint.lazyprint`, and register the identifier if Xcode's cloud signing does not.
- Create a team App Store Connect API key with the Admin role (cloud signing fails with a lower role) and add its issuer id, key id and `.p8` as repository secrets. No distribution certificate or provisioning profile has to be uploaded: the export step has Apple create and manage them.
- Fill in the store listing, the privacy answers and a support address. The privacy page names no contact, so add one before giving its URL to App Store Connect.
- Turn on Pages (Settings, Pages, source GitHub Actions). On a private repository that needs a paid GitHub plan; otherwise the repository has to be public. A custom domain is set up there and at the DNS provider.
- Sign and notarise the Mac app with a Developer ID certificate, if it should open without the Open Anyway step. That would also call for a real bundle id in place of `local.lazyprint.app`. The workflow does not do this.

The site does not link to a download, because there is none yet. When there is one, link it from `site/index.html` and drop the "Not released yet" line.

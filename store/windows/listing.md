# Microsoft Store listing

Text for Partner Center. The limits are the Store's: name 100 characters, short description 100, description 10000, each feature 200, up to 7 search terms of 30 characters. The package is `Package.appxmanifest` in this folder, built by the `store` job of `.github/workflows/release.yml`. The Store ID is 9NF8R01V2PHC.

## English

**Name:** Lazy Print

**Short description:** Print documents and photos from your PC and see the sheets first. Free, no account.

**Description:**

Lazy Print sends documents and photos to your printer and shows the sheets as they will come out before anything is printed. It is free, and it has no account, no ads and no analytics.

Pick what you want to do on the start screen and drop your files in: a document shrunk to fit the paper, a two-sided print, a booklet with the pages in the order that folds into one, handouts with two pages to a sheet, photo prints at 4 x 6, or a photo sheet with four photos and cut marks. The task sets up the options, and you can change them beside the preview before you print. Files can be PDFs and pictures.

Lazy Print prints through the printers Windows already has and straight to driverless IPP printers on your network. It finds network printers by itself, and a printer that does not announce itself can be added by its address. If a printer only prints one side, a card walks you through printing the fronts, turning the paper and printing the backs. When a printer does not show up, "Why isn't my printer listed?" reads what Windows and the network report and says what is wrong in plain words. A demo printer that is always in the list writes each sheet as a picture to a folder, so you can try the printing tasks without a printer.

Scan and print opens Lazy Scan, which hands the scan back to Lazy Print to print. It needs a version of Lazy Scan that supports this, and it stays greyed out until one is installed. From your phone pairs an iPhone or iPad running Lazy Print with your PC by a QR code. The files it sends wait at the top of the window, and nothing prints until you add them to a job.

Lazy Print is free, and its source is public to read. It is a sister app of Lazy Scan and Lazy PDF.

Lazy Print is new, and it has not been run on a real printer yet. If a printer does not print as it should, write to support@alazy.app.

**Features:**

- Print a document shrunk to fit the paper, two-sided when the printer can.
- Print a booklet, with the pages in the order that folds into one.
- Print handouts with two pages to a sheet, and photos at 4 x 6 or a photo sheet with cut marks.
- See every sheet, front and back, before anything is sent. Copies, color or gray, quality, paper size and page range are set beside the preview.
- Print two-sided on a printer that only prints one side, with a card that walks through the reload.
- Use the printers Windows has set up, find network IPP printers, or add one by its address.
- Find out in plain words why a printer is not listed.
- Try the printing tasks with the demo printer, without a printer.
- Send files from an iPhone or iPad to the PC, after pairing with a QR code, over your network or through a cloud folder you both sync.
- Hand a scan from Lazy Scan to Lazy Print.

**Search terms:** print, printer, photo print, two-sided printing, booklet, ipp printer, print pdf

**What's new in this version:** First release.

**Category:** Productivity.

**Support contact:** support@alazy.app

**Website:** https://aytutuna.github.io/LazyPrint/

**Privacy policy URL:** https://aytutuna.github.io/LazyPrint/privacy.html

Both addresses move to alazy.app when that site is up.

**Screenshots:** `screenshots/` in this folder, four PNGs at 1920x1080, light. They were taken from the running app, with the demo printer and a made-up sample document called Quarterly report.pdf, so no printer name, local path or test file name shows. Each window was grabbed on a 2880x1620 pixel area (1920x1080 at the 150 percent scale of the capturing PC) and scaled down. The troubleshooter picture is the main window with the troubleshooter window placed where it sat on screen. They were not taken from the Store package. Retake them before submitting if the look has changed. A two-sided card picture (a printer that prints one side) and one of the phone window are missing: the demo printer prints both sides, and the phone window needs a paired phone.

| File | Caption |
|---|---|
| 1-start.png | Start: pick what you want to print. |
| 2-print.png | The sheets as they will come out, with the options beside them. |
| 3-jobs.png | Jobs: what was sent, and Print again. |
| 4-troubleshooter.png | Why isn't my printer listed? |

**Store logos:** `Listing/Logo-300x300.png` (1:1 app tile icon), `Listing/Box-1080x1080.png` (1:1 box art) and `Listing/Poster-720x1080.png` (2:3 poster art).

## Age rating

The IARC questionnaire in Partner Center, with what backs each answer. The rating this should give is 3+ (PEGI 3, ESRB Everyone); the questionnaire result is the Store's, not ours.

| Question | Answer | What backs it |
|---|---|---|
| Violence, fear, sexual content, bad language, drugs, gambling | No | The app prints the user's own files and has no content of its own besides its tool windows. |
| Users can talk to or share with each other | No | There is no account, chat, feed or sharing feature. The phone link moves files between a person's own paired devices on their network. |
| Shares the user's location | No | No location API is called. |
| Shares personal information with others | No | The only network code talks to printers (IPP, and DNS-SD to find them) and to a paired phone on the local network. A print job carries the document, its name and the Windows user name, to the printer the user chose. |
| Purchases, ads | No | None in the code or the manifest. |
| Unrestricted web access | No | The app has no browser and opens no web pages. It starts Lazy Scan and the Windows settings pages. |
| Collects or sends diagnostics | No | No analytics, crash reporting or update check in the code. |

## Privacy answers

- **Collects personal data:** No. Nothing is sent to the developer or to a server run for the app. `site/privacy.html` says so and lists what the app connects to.
- **Network use:** To printers the user prints to or adds by address, over IPP, and to find them on the local network (DNS-SD). When a phone is paired or a pairing code is on screen, the PC listens on TCP port 52732 on networks Windows calls Private, and on any other network only after the user approves it, and a phone connects over TLS. A phone can also leave files, encrypted, in a cloud folder (iCloud Drive or OneDrive) that the user chose and the PC syncs; the cloud service handles that folder under its own terms.
- **Data kept on the PC:** settings and what the app has learned about each printer, the paired phones with their pairing keys (protected with DPAPI), files a phone sent that wait in the inbox (removed after 7 days, when dismissed or when the phone is forgotten), and the printer log `printers.txt`. In the Store build Windows keeps these files in the package's own store and removes them when the app is uninstalled. The phone link's certificate ("Lazy Print phone link") and its private key are kept separately in the user's Windows certificate store (Current User, Personal), not in the app's files, so uninstalling may leave them. The demo printer writes its pages to Documents\Lazy Print\Demo prints, outside the package, and uninstalling leaves them. `site/privacy.html` says so.
- **Account needed:** No.
- **Uses encryption:** Yes: TLS for the phone link and for IPPS printers, and DPAPI for the stored keys, through .NET and Windows. Partner Center asks about this in the export compliance part of the submission.

## Restricted capability

The package declares `runFullTrust` and nothing else. Partner Center asks for a reason:

> Lazy Print is a desktop app built with .NET and WPF. It reads the PDF and picture files the user picks anywhere on the PC, prints through the Windows print spooler and straight to IPP printers, listens on the local network for a paired phone, receives files from Lazy Scan through a lazyprint: address, starts Lazy Scan through a lazyscan: address, and reads the state of the print spooler and Windows Firewall to say why a printer or phone cannot be reached. It does not need to be sandboxed to do this, and it has no other capability.

## What only the owner can do in Partner Center

In this order.

1. The app is already created in Partner Center with the name "Lazy Print" (Store ID 9NF8R01V2PHC).
2. Open Product management, Product identity. Copy three values into the repository's Actions variables: Package/Identity/Name (`Aytu.LazyPrint`) as `STORE_IDENTITY_NAME`, Package/Identity/Publisher (`CN=54BA56B9-1B6C-4B6E-886D-07694CF02BF5`) as `STORE_PUBLISHER`, and Package/Properties/PublisherDisplayName (`Aytu`) as `STORE_PUBLISHER_DISPLAY_NAME`.
3. Run the Release workflow from the Actions tab and download the `lazyprint-store` artifact, a file named `LazyPrint_1.0.0.msixupload`.
4. Optional but wise: install the package on a clean Windows 10 PC and a Windows 11 PC with a test signature, run the Windows App Certification Kit, and try a phone pairing and the hand-off from Lazy Scan and from Lazy PDF (both pass a path under %TEMP%, which a package may redirect). Nobody has done this yet.
5. Check the screenshots above, and add one of the phone window if you have a phone to pair.
6. Start the submission. Pricing and availability: Free, all markets you want, visible in the Store.
7. Properties: category Productivity, the privacy policy URL and support contact above, and the system requirements (Windows 10 version 2004 or later; x64 and arm64).
8. Age ratings: answer the questionnaire as in the table above.
9. Packages: upload the `.msixupload`. Give the `runFullTrust` reason above when asked.
10. Store listing: English. Paste the texts, upload the screenshots with their captions and the three logos from `Listing/`.
11. Notes for certification: "No account is needed. Add any PDF or picture with Add files. The demo printer in the printer list works without a printer."
12. Submit. When it is certified, add the Store link to `site/index.html` and drop the "Not released yet" line.

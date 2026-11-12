using LazyPrint.Core;
using Xunit;

namespace LazyPrint.Core.Tests;

// Mirrored by Tests/LazyPrintTests/PrintTaskTests.swift: the same cases.

public class PrintTaskTests
{
    private static readonly PrinterCapabilities Duplex = new() { SidesSupported = ["one-sided", "two-sided-long-edge", "two-sided-short-edge"] };
    private static readonly PrinterCapabilities OneSidedOnly = new() { SidesSupported = ["one-sided"] };

    [Fact]
    public void RawValues_AreTheStoredNames()
    {
        Assert.Equal(["document", "twoSided", "booklet", "handouts", "photos", "photoSheet", "testPage", "scanAndPrint", "fromPhone"],
                     PrintTasks.All.Select(t => t.RawValue()));
    }

    [Fact]
    public void TryParse_IsExact()
    {
        foreach (var task in PrintTasks.All) Assert.Equal(task, PrintTasks.TryParse(task.RawValue()));
        Assert.Null(PrintTasks.TryParse(null));
        Assert.Null(PrintTasks.TryParse(""));
        Assert.Null(PrintTasks.TryParse("poster"));
        Assert.Null(PrintTasks.TryParse("Document"));
        Assert.Null(PrintTasks.TryParse("photosheet"));
    }

    [Fact]
    public void Catalog_ListsEveryTaskOnce_InStartScreenOrder()
    {
        Assert.Equal(PrintTasks.All, TaskCatalog.All.Select(d => d.Task));
        Assert.Equal(["Print a document", "Two-sided", "Booklet", "Handouts", "Photo prints", "Photo sheet",
                      "Test page", "Scan and print", "From your phone"],
                     TaskCatalog.All.Select(d => d.Title));
        Assert.Equal(PrintTasks.All.Select(t => t.RawValue()), TaskCatalog.All.Select(d => d.IconKey));
        Assert.Equal([TaskGroup.Documents, TaskGroup.Documents, TaskGroup.Documents, TaskGroup.Documents,
                      TaskGroup.Photos, TaskGroup.Photos, TaskGroup.Other, TaskGroup.Other, TaskGroup.Other],
                     TaskCatalog.All.Select(d => d.Group));
        Assert.Equal([true, true, true, true, true, true, false, false, false], TaskCatalog.All.Select(d => d.OpensFiles));
        foreach (var definition in TaskCatalog.All) Assert.Same(definition, TaskCatalog.Definition(definition.Task));
    }

    [Fact]
    public void Catalog_Texts_AreShort()
    {
        Assert.Equal(["Documents", "Photos", "Other"], TaskGroups.All.Select(g => g.Title()));
        foreach (var definition in TaskCatalog.All)
        {
            Assert.InRange(StatusLine.Words(definition.Title), 1, 6);
            Assert.InRange(StatusLine.Words(definition.Subtitle), 1, 15);
            Assert.EndsWith(".", definition.Subtitle);
        }
    }

    [Fact]
    public void Tasks_TheIPhoneHasNoPhoneWindow()
    {
        Assert.Equal(PrintTasks.All, TaskCatalog.Tasks(AppPlatform.Windows).Select(d => d.Task));
        Assert.Equal(PrintTasks.All, TaskCatalog.Tasks(AppPlatform.Mac).Select(d => d.Task));
        Assert.Equal(PrintTasks.All.Where(t => t != PrintTask.FromPhone), TaskCatalog.Tasks(AppPlatform.Ios).Select(d => d.Task));
    }

    [Fact]
    public void Availability_TestPageNeedsAPrinter_ScanAndPrintNeedsLazyScan()
    {
        var all = new TaskContext(true, true, AppPlatform.Windows);
        Assert.All(PrintTasks.All, task => Assert.Equal(TaskAvailability.Available, TaskCatalog.Availability(task, all)));

        var noPrinter = TaskCatalog.Availability(PrintTask.TestPage, all with { HasPrinter = false });
        Assert.False(noPrinter.IsAvailable);
        Assert.Equal("Needs a printer", noPrinter.Reason);

        var noScan = TaskCatalog.Availability(PrintTask.ScanAndPrint, all with { LazyScanInstalled = false });
        Assert.False(noScan.IsAvailable);
        Assert.Equal("Needs Lazy Scan", noScan.Reason);

        // The others can be started before a printer is found.
        var none = new TaskContext(false, false, AppPlatform.Mac);
        foreach (var task in PrintTasks.All.Where(t => t is not (PrintTask.TestPage or PrintTask.ScanAndPrint)))
        {
            Assert.Equal(TaskAvailability.Available, TaskCatalog.Availability(task, none));
        }
    }

    [Fact]
    public void Apply_Document_OnePerSide_TwoSidedWhenThePrinterCan()
    {
        var start = new PrintSettings { PagesPerSheet = 4, Booklet = true, Scaling = Scaling.Fill, Copies = 3 };
        var s = TaskCatalog.Apply(PrintTask.Document, start, Duplex);
        Assert.Equal("document", s.TaskId);
        Assert.Equal(1, s.PagesPerSheet);
        Assert.False(s.Booklet);
        Assert.Equal(Scaling.ShrinkToFit, s.Scaling);
        Assert.Equal(Sides.LongEdge, s.Sides);
        Assert.Equal(3, s.Copies);

        Assert.Equal(Sides.OneSided, TaskCatalog.Apply(PrintTask.Document, new PrintSettings { Sides = Sides.LongEdge }, OneSidedOnly).Sides);
        Assert.Equal(Sides.OneSided, TaskCatalog.Apply(PrintTask.Document, new PrintSettings { Sides = Sides.LongEdge }, null).Sides);
    }

    [Fact]
    public void Apply_DocumentAndTwoSided_BackToFullScale()
    {
        var start = new PrintSettings { Scale = 50 };
        Assert.Equal(100, TaskCatalog.Apply(PrintTask.Document, start, null).Scale);
        Assert.Equal(100, TaskCatalog.Apply(PrintTask.TwoSided, start, null).Scale);
    }

    [Fact]
    public void Apply_TwoSided_LongEdge_WhateverThePrinterCan()
    {
        foreach (var printer in new[] { Duplex, OneSidedOnly, null })
        {
            var s = TaskCatalog.Apply(PrintTask.TwoSided, new PrintSettings { PagesPerSheet = 2, Booklet = true }, printer);
            Assert.Equal("twoSided", s.TaskId);
            Assert.Equal(Sides.LongEdge, s.Sides);
            Assert.Equal(1, s.PagesPerSheet);
            Assert.False(s.Booklet);
        }
    }

    [Fact]
    public void Apply_Booklet_Handouts()
    {
        var booklet = TaskCatalog.Apply(PrintTask.Booklet, new PrintSettings(), null);
        Assert.Equal("booklet", booklet.TaskId);
        Assert.True(booklet.Booklet);
        Assert.Equal(Sides.LongEdge, booklet.Sides);

        var handouts = TaskCatalog.Apply(PrintTask.Handouts, booklet, null);
        Assert.Equal("handouts", handouts.TaskId);
        Assert.Equal(2, handouts.PagesPerSheet);
        Assert.True(handouts.PageBorders);
        Assert.False(handouts.Booklet);
        // The booklet's two-sided choice is not carried over.
        Assert.Equal(Sides.OneSided, handouts.Sides);
    }

    [Fact]
    public void Apply_BookletAndHandouts_AfterPhotoSheet_DoNotKeepItsFill()
    {
        var sheet = TaskCatalog.Apply(PrintTask.PhotoSheet, new PrintSettings(), null);
        Assert.Equal(Scaling.Fill, sheet.Scaling);
        Assert.Equal(Scaling.ShrinkToFit, TaskCatalog.Apply(PrintTask.Booklet, sheet, null).Scaling);
        Assert.Equal(Scaling.ShrinkToFit, TaskCatalog.Apply(PrintTask.Handouts, sheet, null).Scaling);
    }

    [Fact]
    public void Apply_DocumentTasks_PutQualityBackToNormalAndLeaveColor()
    {
        var start = new PrintSettings { Quality = QualityChoice.Best, Color = ColorChoice.Gray };
        foreach (var task in new[] { PrintTask.Document, PrintTask.TwoSided, PrintTask.Booklet, PrintTask.Handouts })
        {
            var applied = TaskCatalog.Apply(task, start, null);
            Assert.Equal(QualityChoice.Normal, applied.Quality);
            Assert.Equal(ColorChoice.Gray, applied.Color);
        }
        var photos = TaskCatalog.Apply(PrintTask.Photos, new PrintSettings(), null);
        Assert.Equal(QualityChoice.Normal, TaskCatalog.Apply(PrintTask.Document, photos, null).Quality);
    }

    [Fact]
    public void Apply_Photos_PhotoSheet()
    {
        var start = new PrintSettings { Color = ColorChoice.Gray, PhotoSizeId = "5x7", PhotoFill = false, Booklet = true, CutMarks = false };
        var photos = TaskCatalog.Apply(PrintTask.Photos, start, null);
        Assert.Equal("photos", photos.TaskId);
        Assert.Equal(LayoutStyle.PhotoPrints, photos.LayoutStyle);
        Assert.Equal("4x6", photos.PhotoSizeId);
        Assert.True(photos.PhotoFill);
        Assert.Equal(QualityChoice.Best, photos.Quality);
        Assert.Equal(ColorChoice.Color, photos.Color);
        Assert.False(photos.Booklet);
        Assert.True(photos.CutMarks);

        var sheet = TaskCatalog.Apply(PrintTask.PhotoSheet, start, null);
        Assert.Equal("photoSheet", sheet.TaskId);
        Assert.Equal(LayoutStyle.PhotoSheet, sheet.LayoutStyle);
        Assert.Equal(LayoutStyle.Pages, TaskCatalog.Apply(PrintTask.Booklet, sheet, null).LayoutStyle);
        Assert.Equal(4, sheet.PagesPerSheet);
        Assert.Equal(Scaling.Fill, sheet.Scaling);
        Assert.True(sheet.CutMarks);
        Assert.False(sheet.Booklet);
        Assert.Equal(ColorChoice.Gray, sheet.Color);
    }

    [Fact]
    public void Apply_Document_StartsFromTheDefaults()
    {
        var booklet = TaskCatalog.Apply(PrintTask.Booklet, new PrintSettings { PaperId = "a4", Copies = 2, Color = ColorChoice.Gray }, null);
        var worn = booklet with
        {
            Margin = MarginChoice.Custom,
            Orientation = SheetOrientation.Landscape,
            RightToLeft = true,
            PhotoSizeId = "5x7",
        };
        var fresh = new PrintSettings { PaperId = "a4", Copies = 2, Color = ColorChoice.Gray };
        Assert.Equal(TaskCatalog.Apply(PrintTask.Document, fresh, null), TaskCatalog.Apply(PrintTask.Document, worn, null));
    }

    [Fact]
    public void Apply_TasksWithoutSettings_OnlyRememberTheTask()
    {
        var start = new PrintSettings { Copies = 5, Sides = Sides.ShortEdge, Booklet = true };
        foreach (var task in new[] { PrintTask.TestPage, PrintTask.ScanAndPrint, PrintTask.FromPhone })
        {
            Assert.Equal(start with { TaskId = task.RawValue() }, TaskCatalog.Apply(task, start, Duplex));
        }
        // The start is left as it was.
        Assert.Null(start.TaskId);
    }

    [Fact]
    public void SameInUse_IgnoresOptionsTheLayoutDoesNotUse()
    {
        var document = TaskCatalog.Apply(PrintTask.Document, new PrintSettings(), Duplex);
        Assert.True(PrintSettings.SameInUse(document, document with { MarginMm = 15 }));
        Assert.True(PrintSettings.SameInUse(document, document with { PhotoSizeId = "5x7" }));
        Assert.False(PrintSettings.SameInUse(document, document with { Orientation = SheetOrientation.Landscape }));

        var booklet = TaskCatalog.Apply(PrintTask.Booklet, new PrintSettings(), Duplex);
        Assert.True(PrintSettings.SameInUse(booklet, booklet with { Orientation = SheetOrientation.Landscape }));
    }

    [Fact]
    public void SameInUse_IgnoresSidesWhenTheLayoutDoesNotUseThem()
    {
        var booklet = TaskCatalog.Apply(PrintTask.Booklet, new PrintSettings(), Duplex);
        Assert.True(PrintSettings.SameInUse(booklet, booklet with { Sides = Sides.OneSided }));
    }

    [Fact]
    public void SameInUse_CountsScaleForALonePageOnAPhotoSheet()
    {
        var sheet = new PrintSettings
        {
            LayoutStyle = LayoutStyle.PhotoSheet, PagesPerSheet = 1, Scaling = Scaling.ShrinkToFit, Scale = 50,
        };
        Assert.False(PrintSettings.SameInUse(sheet, sheet with { Scale = 100 }));
    }
}

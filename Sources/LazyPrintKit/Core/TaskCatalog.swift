import Foundation

// Twin of windows/LazyPrint.Core/Core/TaskCatalog.cs (Lazy Scan's TaskCatalog, for print tasks).

/// The groups of tasks in the Preset menu, in the order it shows them. Twin of C# `TaskGroup`.
public enum TaskGroup: String, CaseIterable, Sendable {
    case documents
    case photos
    case other

    /// "Documents", "Photos", "Other".
    public var title: String {
        switch self {
        case .documents: return "Documents"
        case .photos: return "Photos"
        case .other: return "Other"
        }
    }
}

/// A task.
public struct TaskDefinition: Equatable, Sendable {
    public let task: PrintTask
    public let title: String
    /// What the task does, in one short line: the menu item's tooltip, not shown in the menu.
    public let subtitle: String
    /// Names the task's icon; each platform maps it to its own symbol (the task's raw value).
    public let iconKey: String
    public let group: TaskGroup
    /// The task starts by asking for files.
    public let opensFiles: Bool

    public init(task: PrintTask, title: String, subtitle: String, iconKey: String, group: TaskGroup, opensFiles: Bool) {
        self.task = task
        self.title = title
        self.subtitle = subtitle
        self.iconKey = iconKey
        self.group = group
        self.opensFiles = opensFiles
    }
}

/// Whether a task can be started, and if not, why (the one line a menu item shows).
public struct TaskAvailability: Equatable, Sendable {
    public let isAvailable: Bool
    public let reason: String?

    public init(isAvailable: Bool, reason: String? = nil) {
        self.isAvailable = isAvailable
        self.reason = reason
    }

    public static let available = TaskAvailability(isAvailable: true)
}

/// Twin of C# `AppPlatform` (`Ios` there).
public enum AppPlatform: String, Sendable {
    case windows
    case mac
    case ios
}

/// What decides whether a task can be started.
public struct TaskContext: Equatable, Sendable {
    public var hasPrinter: Bool
    public var lazyScanInstalled: Bool
    public var platform: AppPlatform

    public init(hasPrinter: Bool, lazyScanInstalled: Bool, platform: AppPlatform) {
        self.hasPrinter = hasPrinter
        self.lazyScanInstalled = lazyScanInstalled
        self.platform = platform
    }
}

/// The tasks of the Preset menu, in code rather than in a settings file. Picking a task builds its
/// settings from the defaults (`apply`). Twin of C# `TaskCatalog`.
public enum TaskCatalog {
    /// Every task, in menu order.
    public static let all = [
        TaskDefinition(task: .document, title: "Print a document", subtitle: "PDFs and images, one page per side.",
                       iconKey: "document", group: .documents, opensFiles: true),
        TaskDefinition(task: .twoSided, title: "Two-sided", subtitle: "Both sides of the paper, even without duplex.",
                       iconKey: "twoSided", group: .documents, opensFiles: true),
        TaskDefinition(task: .booklet, title: "Booklet", subtitle: "Pages in booklet order, to fold and staple.",
                       iconKey: "booklet", group: .documents, opensFiles: true),
        TaskDefinition(task: .handouts, title: "Handouts", subtitle: "Two pages on each side, with borders.",
                       iconKey: "handouts", group: .documents, opensFiles: true),
        TaskDefinition(task: .photos, title: "Photo prints", subtitle: "Photos at 4 \u{00D7} 6 or another size.",
                       iconKey: "photos", group: .photos, opensFiles: true),
        TaskDefinition(task: .photoSheet, title: "Photo sheet", subtitle: "Four photos on a sheet, with cut marks.",
                       iconKey: "photoSheet", group: .photos, opensFiles: true),
        TaskDefinition(task: .testPage, title: "Test page", subtitle: "Check your printer with one page.",
                       iconKey: "testPage", group: .other, opensFiles: false),
        TaskDefinition(task: .scanAndPrint, title: "Scan and print", subtitle: "Scan with Lazy Scan, then print.",
                       iconKey: "scanAndPrint", group: .other, opensFiles: false),
        TaskDefinition(task: .fromPhone, title: "From your phone", subtitle: "Print what your phone sends.",
                       iconKey: "fromPhone", group: .other, opensFiles: false),
    ]

    public static func definition(_ task: PrintTask) -> TaskDefinition {
        all.first { $0.task == task }!
    }

    /// The tasks the platform shows: the phone window is not on the iPhone.
    public static func tasks(for platform: AppPlatform) -> [TaskDefinition] {
        all.filter { platform != .ios || $0.task != .fromPhone }
    }

    /// The test page needs a printer and Scan and print needs Lazy Scan. The rest can be started
    /// without a printer, which may still be found while the layout shows.
    public static func availability(of task: PrintTask, context: TaskContext) -> TaskAvailability {
        switch task {
        case .testPage where !context.hasPrinter:
            return TaskAvailability(isAvailable: false, reason: PrintText.noPrinterReason)
        case .scanAndPrint where !context.lazyScanInstalled:
            return TaskAvailability(isAvailable: false, reason: PrintText.needsLazyScanReason)
        default:
            return .available
        }
    }

    /// A preset starts from the defaults; only the printer, its paper, tray, paper type and color, and this job's copies, collation and page choices carry over.
    public static func apply(_ task: PrintTask, to settings: PrintSettings, printer: PrinterCapabilities?) -> PrintSettings {
        var s = PrintSettings()
        s.taskId = task.rawValue
        s.printerId = settings.printerId
        s.printerName = settings.printerName
        s.paperId = settings.paperId
        s.mediaSource = settings.mediaSource
        s.mediaType = settings.mediaType
        s.color = settings.color
        s.copies = settings.copies
        s.collate = settings.collate
        s.pageSelection = settings.pageSelection
        s.reverseOrder = settings.reverseOrder
        switch task {
        case .document:
            s.sides = printer?.sidesSupported.contains("two-sided-long-edge") == true ? .longEdge : .oneSided
        case .twoSided:
            // A printer that can't turn the sheet itself gets two passes: the plan decides, not the setting.
            s.sides = .longEdge
        case .booklet:
            s.booklet = true
            s.sides = .longEdge
        case .handouts:
            s.pagesPerSheet = 2
            s.pageBorders = true
        case .photos:
            s.layoutStyle = .photoPrints
            s.quality = .best
            s.color = .color
        case .photoSheet:
            s.layoutStyle = .photoSheet
            s.pagesPerSheet = 4
            s.scaling = .fill
        case .testPage, .scanAndPrint, .fromPhone:
            s = settings
            s.taskId = task.rawValue
        }
        return s
    }
}

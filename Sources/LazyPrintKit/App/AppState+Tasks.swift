import Foundation

// Twin of windows/LazyPrint.App/AppViewModel.Tasks.cs: the start screen's tasks, which tiles there are and whether they
// can be started, and what picking one does.

extension AppState {
    var taskContext: TaskContext {
        TaskContext(hasPrinter: selectedPrinter != nil, lazyScanInstalled: lazyScanInstalled, platform: platform)
    }

    /// The start screen's tiles, in catalog order.
    public var taskDefinitions: [TaskDefinition] {
        TaskCatalog.tasks(for: platform)
    }

    /// Whether a tile can be started, and why not.
    public func availability(of task: PrintTask) -> TaskAvailability {
        TaskCatalog.availability(of: task, context: taskContext)
    }

    /// What a task sets, for its tile's tooltip: the summaries of the sections it changes.
    public func summary(of task: PrintTask) -> String {
        let s = TaskCatalog.apply(task, to: settings, printer: capabilities)
        var parts = [InspectorSections.pagesSummary(s), InspectorSections.layoutSummary(s), InspectorSections.paperSummary(s)]
        if task == .photos || task == .photoSheet { parts.append(InspectorSections.photosSummary(s)) }
        let summary = parts.filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
        return summary.isEmpty ? "One page per side" : summary
    }

    /// Picks a task: its settings are applied over the user's, the rest stay as they were. The test page prints at once;
    /// Scan and print hands over to Lazy Scan; From your phone asks the shell to open the phone window.
    public func startTask(_ task: PrintTask) async {
        guard availability(of: task).isAvailable else { return }
        statusOverride = nil
        switch task {
        case .scanAndPrint:
            do {
                try fileActions.openLazyScan()
            } catch {
                showFailure("Lazy Scan did not open", error.localizedDescription)
            }
        case .fromPhone:
            phoneWindowRequested?()
        case .testPage:
            // Prints at once; it is not a task the settings stay in.
            clearMessages()
            await printTestPage()
        default:
            clearMessages()
            self.task = task
            settings = TaskCatalog.apply(task, to: settings, printer: capabilities)
        }
    }

    /// Leaves the task: the settings stay, the tile is no longer current.
    public func clearTask() {
        task = nil
        settings.taskId = nil
    }
}

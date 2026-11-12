import Foundation

// Twin of windows/LazyPrint.App/AppViewModel.Tasks.cs: the tasks of the Preset menu, which there are and whether they
// can be started, and what picking one does.

extension AppState {
    var taskContext: TaskContext {
        TaskContext(hasPrinter: selectedPrinter != nil, lazyScanInstalled: lazyScanInstalled, platform: platform)
    }

    /// The tasks of the Preset menu, in catalog order.
    public var taskDefinitions: [TaskDefinition] {
        TaskCatalog.tasks(for: platform)
    }

    /// Whether a task can be started, and why not.
    public func availability(of task: PrintTask) -> TaskAvailability {
        TaskCatalog.availability(of: task, context: taskContext)
    }

    /// What a task sets, for its menu item's tooltip: the summaries of the sections it changes.
    public func summary(of task: PrintTask) -> String {
        let s = TaskCatalog.apply(task, to: settings, printer: capabilities)
        var parts = [InspectorSections.pagesSummary(s), InspectorSections.layoutSummary(s), InspectorSections.paperSummary(s)]
        if s.layoutStyle.isPhoto { parts.append(InspectorSections.photosSummary(s)) }
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
            appliedPreset = nil
            settings = TaskCatalog.apply(task, to: settings, printer: capabilities)
            sidesPickedBlind = task == .document && capabilities == nil ? settings.sides : nil
        }
    }

    /// Leaves the task: the settings stay, the task is no longer current.
    public func clearTask() {
        task = nil
        sidesPickedBlind = nil
        settings.taskId = nil
    }

    /// The document preset is two-sided only for a printer that can turn the sheet. Picked before the printer was read (the preset
    /// a fresh install starts with), it chose one-sided; it chooses again each time the printer in use is read or changes, until
    /// the user changes the sides. Only the document preset is ever picked blind.
    func chooseSidesAgain() {
        guard sidesPickedBlind != nil else { return }
        let sides = TaskCatalog.apply(.document, to: settings, printer: capabilities).sides
        sidesPickedBlind = sides
        if settings.sides != sides { settings.sides = sides }
    }
}

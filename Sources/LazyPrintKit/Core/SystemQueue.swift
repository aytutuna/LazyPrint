import Foundation

// Twin of windows/LazyPrint.Core/Core/SystemQueue.cs: a print queue the system has set up, and its problems.

/// What the system says is wrong with, or going on in, a queue (Windows' PrintQueueStatus, the Mac's printer state).
public enum SystemQueueState: String, Sendable {
    case paused
    case error
    case offline
    case paperOut
    case paperJam
    case doorOpen
    case tonerLow
    case noToner
    case busy
    case userIntervention
}

/// The jobs waiting in a queue; `oldestMinutes` is the age of the oldest.
public struct SystemQueueJobs: Equatable, Sendable {
    public var count: Int
    public var anyInError: Bool
    public var oldestMinutes: Int

    public init(count: Int, anyInError: Bool, oldestMinutes: Int) {
        self.count = count
        self.anyInError = anyInError
        self.oldestMinutes = oldestMinutes
    }

    public static let none = SystemQueueJobs(count: 0, anyInError: false, oldestMinutes: 0)
}

/// A queue the platform has set up. `port` is the port name or the device URI, `model` the driver's name, `uuid` the
/// printer's UUID when the system knows it (the merge also looks for one in the port).
public struct SystemPrinter: Equatable, Sendable {
    public var name: String
    public var model: String?
    public var port: String?
    public var isDefault: Bool
    public var isVirtual: Bool
    public var states: [SystemQueueState]
    public var jobs: SystemQueueJobs
    public var uuid: String?

    public init(name: String, model: String?, port: String?, isDefault: Bool, isVirtual: Bool, states: [SystemQueueState],
                jobs: SystemQueueJobs, uuid: String? = nil) {
        self.name = name
        self.model = model
        self.port = port
        self.isDefault = isDefault
        self.isVirtual = isVirtual
        self.states = states
        self.jobs = jobs
        self.uuid = uuid
    }
}

public enum SystemQueueProblems {
    /// The states of a queue as problems, with the titles and advice IPP's reasons get, errors first and each kind once.
    /// A queue that is offline is that alone. Busy is not a problem.
    public static func describe(_ states: [SystemQueueState]) -> [PrinterProblem] {
        if states.contains(.offline) {
            return [PrinterProblem(title: IppProblemText.offline, advice: IppProblemText.offlineAdvice, isError: true)]
        }

        var problems = [PrinterProblem]()
        for state in states {
            if let problem = known(state), !problems.contains(problem) { problems.append(problem) }
        }
        return problems.filter { $0.isError } + problems.filter { !$0.isError }
    }

    private static func known(_ state: SystemQueueState) -> PrinterProblem? {
        switch state {
        case .paused:
            return PrinterProblem(title: IppProblemText.paused, advice: IppProblemText.pausedAdvice, isError: true)
        case .error, .userIntervention:
            return PrinterProblem(title: IppProblemText.printerError, advice: IppProblemText.printerErrorAdvice, isError: true)
        case .paperOut:
            return PrinterProblem(title: IppProblemText.outOfPaper, advice: IppProblemText.outOfPaperAdvice, isError: true)
        case .paperJam:
            return PrinterProblem(title: IppProblemText.paperJam, advice: IppProblemText.paperJamAdvice, isError: true)
        case .doorOpen:
            return PrinterProblem(title: IppProblemText.coverOpen, advice: IppProblemText.coverOpenAdvice, isError: true)
        case .noToner:
            return PrinterProblem(title: IppProblemText.tonerEmpty, advice: IppProblemText.tonerEmptyAdvice, isError: true)
        case .tonerLow:
            return PrinterProblem(title: IppProblemText.tonerLow, advice: IppProblemText.tonerLowAdvice, isError: false)
        case .offline, .busy:
            return nil
        }
    }
}

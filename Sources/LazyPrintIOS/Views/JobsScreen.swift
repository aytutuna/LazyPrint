#if os(iOS)
import LazyPrintKit
import SwiftUI

/// This session's jobs, newest first, each with its state, Cancel while it runs, Print again once it is over and Show for
/// the demo printer's pictures (the share sheet). Twin of the Mac's Jobs tab. Shown in the panel the Print screen opens.
struct JobsScreen: View {
    @EnvironmentObject private var state: AppState
    let close: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if state.jobs.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text("No jobs yet")
                            .font(.title3.weight(.semibold))
                        Text("What you print in this session appears here.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("jobs.empty")
                } else {
                    List {
                        ForEach(state.jobs) { (record: JobRecord) in
                            JobRow(record: record)
                        }
                    }
                    .readableWidth()
                    .background(Color(uiColor: .systemGroupedBackground))
                }
            }
            .navigationTitle("Jobs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: close) {
                        Label("Close", systemImage: "xmark")
                    }
                    .accessibilityIdentifier("jobs.close")
                }
            }
        }
    }
}

private struct JobRow: View {
    @EnvironmentObject private var state: AppState
    let record: JobRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(record.name)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
                    .accessibilityIdentifier("jobs.state")
            }
            Text(summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            if running || finished || state.demoFolder(of: record) != nil {
                HStack(spacing: 16) {
                    if running {
                        Button {
                            state.cancelJob(record.id)
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                        .accessibilityIdentifier("jobs.cancel")
                    }
                    if finished {
                        Button {
                            Task { await state.printAgain(record) }
                        } label: {
                            Label("Print again", systemImage: "arrow.clockwise")
                        }
                        .disabled(state.isBusy || state.duplexCard != nil)
                        .accessibilityIdentifier("jobs.again")
                    }
                    if state.demoFolder(of: record) != nil {
                        Button {
                            state.showDemoFolder(of: record)
                        } label: {
                            Label("Show", systemImage: "folder")
                        }
                        .disabled(state.isBusy)
                        .accessibilityIdentifier("jobs.show")
                    }
                }
                .buttonStyle(.borderless)
                .font(.callout)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(record.name), \(stateText), \(summary)")
    }

    private var running: Bool {
        let states: [JobState] = [.preparing, .sending, .waiting, .printing, .needsUser]
        return states.contains(record.state)
    }

    private var finished: Bool {
        let states: [JobState] = [.done, .failed, .canceled]
        return states.contains(record.state)
    }

    private var stateText: String {
        switch record.state {
        case .preparing: return "Preparing"
        case .sending: return "Sending"
        case .waiting: return "Waiting"
        case .printing: return "Printing"
        case .done: return "Done"
        case .failed: return "Failed"
        case .canceled: return "Canceled"
        case .needsUser: return "Needs you"
        }
    }

    /// The printer, the sheets, and what went wrong or what the printer needs.
    private var summary: String {
        let sheets: String = "\(record.sheets) sheet\(record.sheets == 1 ? "" : "s")" + (record.copies > 1 ? " \u{00D7} \(record.copies)" : "")
        return [record.printerName, sheets, record.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}
#endif

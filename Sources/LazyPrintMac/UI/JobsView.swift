#if os(macOS)
import LazyPrintKit
import SwiftUI

/// This session's jobs, newest first, each with its state, Cancel while it runs, Print again once it is over and Show for
/// the demo printer's folder. Twin of the Windows Jobs tab.
struct JobsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.jobs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(.secondary)
                    Text("No jobs yet")
                        .font(.title3.weight(.semibold))
                    Text("What you print in this session appears here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .combine)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.jobs) { record in
                            JobRow(record: record)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct JobRow: View {
    @EnvironmentObject var state: AppState
    let record: JobRecord

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 12)
            Text(stateText)
                .font(.caption)
                .foregroundStyle(record.state == .failed ? Color.red : Color.secondary)
            if running {
                Button {
                    state.cancelJob(record.id)
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            }
            if finished {
                Button {
                    Task { await state.printAgain(record) }
                } label: {
                    Label("Print again", systemImage: "arrow.clockwise")
                }
                .disabled(state.isBusy || state.duplexCard != nil)
            }
            if state.demoFolder(of: record) != nil {
                Button {
                    state.showDemoFolder(of: record)
                } label: {
                    Label("Show folder", systemImage: "folder")
                }
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 10)
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
        let sheets = PrintText.sheetCount(record.sheets, copies: record.copies)
        return [record.printerName, sheets, record.detail ?? ""].filter { !$0.isEmpty }.joined(separator: " \u{00B7} ")
    }
}
#endif

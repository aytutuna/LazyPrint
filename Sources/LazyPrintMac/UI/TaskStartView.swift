#if os(macOS)
import AppKit
import LazyPrintKit
import SwiftUI

/// SF Symbols for the task icons (`TaskDefinition.iconKey`); the Windows app maps the same keys to Segoe Fluent glyphs.
enum TaskSymbols {
    static func systemImage(_ iconKey: String) -> String {
        switch iconKey {
        case "document": return "doc"
        case "twoSided": return "arrow.left.arrow.right.square"
        case "booklet": return "book"
        case "handouts": return "square.grid.2x2"
        case "photos": return "photo"
        case "photoSheet": return "photo.on.rectangle"
        case "testPage": return "printer"
        case "scanAndPrint": return "scanner"
        case "fromPhone": return "iphone"
        default: return "doc"
        }
    }
}

/// The start screen: what are you printing? One tile per task of the catalog in its group, with an icon and the title; what
/// the task does and what it sets are the tile's help. A task that cannot be started is dimmed with one short line saying
/// why. Twin of the Windows `TaskStartView`.
struct TaskStartView: View {
    @EnvironmentObject var state: AppState

    /// A tile was picked.
    var onPick: (PrintTask) -> Void

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 12, alignment: .top)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("What are you printing?")
                    .font(.largeTitle.weight(.semibold))
                ForEach(TaskGroup.allCases, id: \.self) { group in
                    let definitions = state.taskDefinitions.filter { $0.group == group }
                    if !definitions.isEmpty {
                        Text(group.title)
                            .font(.headline)
                            .padding(.top, 8)
                            .accessibilityAddTraits(.isHeader)
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                            ForEach(definitions, id: \.task) { definition in
                                tile(definition)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 1180, alignment: .leading)
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityHint(Text("Picking a task sets everything up. You can change any setting later."))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func tile(_ definition: TaskDefinition) -> some View {
        let availability = state.availability(of: definition.task)
        let summary = state.summary(of: definition.task)
        let reason = availability.reason ?? ""
        return Button {
            onPick(definition.task)
        } label: {
            TaskTileLabel(symbol: TaskSymbols.systemImage(definition.iconKey), title: definition.title,
                          reason: availability.isAvailable ? nil : reason, isCurrent: state.task == definition.task)
        }
        .buttonStyle(TaskCardButtonStyle())
        .disabled(!availability.isAvailable || state.isBusy)
        .help(definition.subtitle + "\n" + summary)
        .accessibilityLabel(Text(definition.title))
        .accessibilityHint(Text(availability.isAvailable ? "\(definition.subtitle) \(summary)."
                                : "\(definition.subtitle) Not available: \(reason)"))
    }
}

/// The inside of a start-screen tile: the icon, the title (two lines at most, never cut), and for a task that cannot be
/// started, one line saying why.
private struct TaskTileLabel: View {
    let symbol: String
    let title: String
    let reason: String?
    let isCurrent: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 22))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .opacity(reason == nil ? 1 : 0.4)
                    .accessibilityHidden(true)
                Spacer(minLength: 4)
                if isCurrent {
                    Text("Current")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor))
                }
            }
            Text(title)
                .font(.headline)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .contentShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// A whole-tile button: card surface, hairline border, pressed feedback.
private struct TaskCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.secondary.opacity(configuration.isPressed ? 0.5 : 0.22), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
    }
}
#endif

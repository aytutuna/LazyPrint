#if os(macOS)
import AppKit
import LazyPrintKit
import SwiftUI

/// The bar above the tabs when a paired phone sent files: "3 files from Aytu's iPhone", with Add to this job, Start a new
/// job and Dismiss. Nothing is printed or added until one is chosen; a choice made while a job goes out is taken when it ends. It is announced,
/// and the Dock icon bounces once when the app is in the background. Twin of the Windows phone bar (MainWindow.Phone.cs).
struct PhoneBarView: View {
    let batch: PhoneBatch
    let queued: Bool
    let add: () -> Void
    let startNew: () -> Void
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "iphone")
                .font(.system(size: 15))
                .foregroundStyle(Color.accentColor)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.12)))
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            if queued {
                Text("Taken when the job ends")
                    .foregroundStyle(.secondary)
            } else {
                Button("Add to this job", action: add)
                Button("Start a new job", action: startNew)
            }
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Delete these files")
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .onAppear { arrived(message) }
        .onChange(of: PhoneBarView.announcementKey(batch)) { _, _ in arrived(message) }
    }

    private var message: String { PhoneBarView.message(batch) }

    /// What the bar is announced for: the batch and its words, so a queued batch that reads the same is announced too.
    static func announcementKey(_ batch: PhoneBatch) -> String {
        batch.id + " " + message(batch)
    }

    /// "3 files from Aytu's iPhone".
    static func message(_ batch: PhoneBatch) -> String {
        "\(batch.arrived) file\(batch.arrived == 1 ? "" : "s") from \(batch.from.isEmpty ? "a phone" : batch.from)"
    }

    private func arrived(_ text: String) {
        AccessibilityNotification.Announcement(text).post()
        if !NSApp.isActive { _ = NSApp.requestUserAttention(.informationalRequest) }
    }
}
#endif

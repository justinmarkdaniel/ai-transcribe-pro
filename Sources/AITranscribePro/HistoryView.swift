import SwiftUI
import AppKit

struct HistoryView: View {
    @EnvironmentObject var history: HistoryStore
    @State private var flashID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("History")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 8)

            Divider().background(Color.white.opacity(0.06))

            if history.entries.isEmpty {
                Text("No recordings yet")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(history.entries) { entry in
                            row(entry)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: 340, height: 360)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
    }

    private func row(_ entry: TranscriptionEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.text)
                .font(.system(size: 11, design: .rounded))
                .foregroundColor(.white.opacity(0.9))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(entry.date, style: .relative)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(entry.text, forType: .string)
                    flashID = entry.id
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                        if flashID == entry.id { flashID = nil }
                    }
                } label: {
                    Image(systemName: flashID == entry.id ? "checkmark" : "doc.on.clipboard")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(flashID == entry.id ? .green : .white.opacity(0.6))
                }
                .buttonStyle(.plain)
                Button {
                    history.delete(entry)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
        )
    }
}

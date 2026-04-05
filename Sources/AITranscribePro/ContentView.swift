import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var engine: TranscriptionEngine
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var settings: SettingsStore
    @State private var showHistory = false
    @State private var showSettings = false
    @State private var copiedFlash = false

    var body: some View {
        ZStack {
            // Dark glass background.
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(red: 0.07, green: 0.07, blue: 0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )

            HStack(spacing: 10) {
                // Live transcript area.
                ScrollView(.vertical, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        Text(displayText)
                            .font(.system(size: 12, weight: .regular, design: .rounded))
                            .foregroundColor(Color.white.opacity(0.92))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("end")
                            .onChange(of: engine.transcript) { _ in
                                withAnimation(.easeOut(duration: 0.1)) {
                                    proxy.scrollTo("end", anchor: .bottom)
                                }
                            }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.leading, 12)
                .padding(.vertical, 8)

                // Controls — fixed 2×3 square grid, flush right, so cells never shift.
                // Row 1: stop (reserved) · primary (mic/pause) · reset
                // Row 2: copy            · history             · gear
                Grid(alignment: .trailing, horizontalSpacing: 6, verticalSpacing: 6) {
                    GridRow {
                        stopSlot
                        primaryButton
                        iconButton(system: "arrow.counterclockwise", tint: .white.opacity(0.7)) {
                            engine.reset()
                        }
                    }
                    GridRow {
                        iconButton(
                            system: copiedFlash ? "checkmark" : "doc.on.clipboard",
                            tint: copiedFlash ? .green : .white.opacity(0.7)
                        ) {
                            copyCurrent()
                        }
                        .disabled(!hasCopyableText)
                        .opacity(hasCopyableText ? 1 : 0.4)

                        iconButton(system: "clock.arrow.circlepath", tint: .white.opacity(0.7)) {
                            showHistory.toggle()
                        }
                        .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                            HistoryView()
                                .environmentObject(history)
                        }

                        iconButton(system: "gearshape.fill", tint: .white.opacity(0.7)) {
                            showSettings.toggle()
                        }
                        .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                            SettingsView()
                                .environmentObject(settings)
                        }
                    }
                }
                .padding(.trailing, 10)
                .padding(.vertical, 8)
            }
        }
        .frame(minWidth: 360, minHeight: 104)
        .onAppear {
            engine.onCommit = { [weak history] text in
                history?.add(text)
            }
        }
    }

    private var displayText: String {
        if let err = engine.errorMessage { return err }
        if !engine.transcript.isEmpty { return engine.transcript }
        switch engine.state {
        case .recording: return "Listening…"
        case .paused:    return "Paused"
        case .idle, .stopped:
            // Fall back to the most recent history entry so the window is never empty after the
            // first use. The text is a real, copyable transcript — press mic to start a new one.
            if let last = history.entries.first { return last.text }
            return "Press record to start transcribing…"
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch engine.state {
        case .idle, .stopped, .paused:
            iconButton(system: "mic.fill", tint: .red) { engine.toggleRecord() }
        case .recording:
            iconButton(system: "pause.fill", tint: .yellow.opacity(0.9)) { engine.toggleRecord() }
        }
    }

    /// Stop button cell — reserves its grid slot even when inactive so the layout never shifts.
    @ViewBuilder
    private var stopSlot: some View {
        if engine.state == .recording || engine.state == .paused {
            iconButton(system: "stop.fill", tint: .red.opacity(0.85)) {
                engine.stop()
            }
        } else {
            Color.clear.frame(width: 24, height: 24)
        }
    }

    private func iconButton(system: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(tint)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                )
        }
        .buttonStyle(.plain)
    }

    /// What the copy button will put on the clipboard — current transcript if we have one,
    /// otherwise the most recent history entry (which is what's displayed in the panel).
    private var copyableText: String? {
        let current = engine.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        return history.entries.first?.text
    }

    private var hasCopyableText: Bool { copyableText != nil }

    private func copyCurrent() {
        guard let text = copyableText else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copiedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation { copiedFlash = false }
        }
    }
}

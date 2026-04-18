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

            // Transcript fills the whole area; padding reserves space for the X (top-left)
            // and the bottom control row. Long transcripts scroll behind the controls — the
            // controls carry a subtle glow so they stay legible.
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
            .padding(.horizontal, 12)
            .padding(.top, 22)
            .padding(.bottom, 38)
        }
        .frame(minWidth: 360, minHeight: 104)
        .overlay(alignment: .topLeading) {
            Button(action: {
                NotificationCenter.default.post(name: .hidePanelRequest, object: nil)
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Color(white: 0.5))
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .padding(.top, 6)
            .help("Hide window (reopen with the shortcut or menu bar)")
        }
        .overlay(alignment: .bottom) {
            bottomControls
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .onAppear {
            engine.onCommit = { [weak history] text in
                history?.add(text)
            }
        }
        // Auto-copy + flash whenever recording is paused or stopped (via button or hotkey).
        .onChange(of: engine.state) { newState in
            if newState == .paused || newState == .stopped {
                autoCopyTranscript()
            }
        }
    }

    /// Bottom row: gear (leading) · stop/primary/reset (true-centered) · history/copy (trailing, 6pt).
    /// Uses a ZStack so the center group stays optically centered regardless of the side
    /// clusters' widths (left has 1 button, right has 2).
    private var bottomControls: some View {
        ZStack {
            // Center group — positioned at the true center of the panel.
            HStack(spacing: 6) {
                stopSlot
                primaryButton
                iconButton(system: "arrow.counterclockwise", tint: .white.opacity(0.7)) {
                    engine.reset()
                }
            }

            // Leading cluster.
            HStack {
                iconButton(system: "gearshape.fill", tint: .white.opacity(0.7)) {
                    showSettings.toggle()
                }
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    SettingsView()
                        .environmentObject(settings)
                }
                Spacer(minLength: 0)
            }

            // Trailing cluster.
            HStack {
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    iconButton(system: "clock.arrow.circlepath", tint: .white.opacity(0.7)) {
                        showHistory.toggle()
                    }
                    .popover(isPresented: $showHistory, arrowEdge: .bottom) {
                        HistoryView()
                            .environmentObject(history)
                    }

                    iconButton(
                        system: copiedFlash ? "checkmark" : "doc.on.clipboard",
                        tint: copiedFlash ? .green : .white.opacity(0.7)
                    ) {
                        copyCurrent()
                    }
                    .disabled(!hasCopyableText)
                    .opacity(hasCopyableText ? 1 : 0.4)
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var displayText: String {
        if let err = engine.errorMessage { return err }
        if !engine.transcript.isEmpty { return engine.transcript }
        switch engine.state {
        case .recording: return "Listening…"
        case .paused:    return "Paused"
        case .idle:      return "Press record to start transcribing…"
        case .stopped:   return "Press record to start transcribing…"
        }
        // Past transcripts are surfaced via the history popover, not in the live display area —
        // this keeps the reset button's effect visible (it previously looked broken because the
        // display was falling back to history.entries.first after reset).
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
                // Subtle dark halo so buttons stay readable when transcript scrolls behind them.
                .shadow(color: .black.opacity(0.55), radius: 3, x: 0, y: 0)
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
        writeToClipboardAndFlash(text)
    }

    /// Called on pause/stop transitions — copies the current transcript only (not history)
    /// so the flash is a true confirmation of "what you just recorded is on the clipboard".
    private func autoCopyTranscript() {
        let current = engine.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !current.isEmpty else { return }
        writeToClipboardAndFlash(current)
    }

    private func writeToClipboardAndFlash(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        withAnimation { copiedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            withAnimation { copiedFlash = false }
        }
    }
}

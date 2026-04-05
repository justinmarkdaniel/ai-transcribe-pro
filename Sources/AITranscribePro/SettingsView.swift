import SwiftUI
import AppKit
import Carbon.HIToolbox

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @State private var isCapturing = false
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.9))

            VStack(alignment: .leading, spacing: 6) {
                Text("Global shortcut")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))

                Button(action: toggleCapture) {
                    HStack {
                        Text(isCapturing ? "Press any key combo…" : settings.hotKey.display)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(isCapturing ? .yellow : .white.opacity(0.95))
                        Spacer()
                        if isCapturing {
                            Text("esc to cancel")
                                .font(.system(size: 9))
                                .foregroundColor(.white.opacity(0.4))
                        } else {
                            Image(systemName: "pencil")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.5))
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.white.opacity(isCapturing ? 0.1 : 0.05))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(
                                        isCapturing ? Color.yellow.opacity(0.6) : Color.white.opacity(0.08),
                                        lineWidth: 1
                                    )
                            )
                    )
                }
                .buttonStyle(.plain)
            }

            Text("Toggles the transcribe window from anywhere.")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.4))
        }
        .padding(14)
        .frame(width: 260)
        .background(Color(red: 0.07, green: 0.07, blue: 0.08))
        .onDisappear { stopCapture() }
    }

    private func toggleCapture() {
        if isCapturing { stopCapture() } else { startCapture() }
    }

    private func startCapture() {
        isCapturing = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event: event)
            return nil // swallow the event
        }
    }

    private func stopCapture() {
        isCapturing = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handle(event: NSEvent) {
        // Escape cancels capture without changing anything.
        if event.keyCode == kVK_Escape {
            stopCapture()
            return
        }

        var mods = HotKeyModifiers()
        let flags = event.modifierFlags
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option)  { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift)   { mods.insert(.shift) }

        // Require at least one modifier — bare keys make terrible global hotkeys.
        guard !mods.isEmpty else { return }

        settings.hotKey = HotKeyConfig(
            keyCode: UInt32(event.keyCode),
            modifiersRaw: mods.rawValue
        )
        stopCapture()
    }
}

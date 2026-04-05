import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private let engine = TranscriptionEngine()
    private let history = HistoryStore()
    private let settings = SettingsStore()
    let hotKey = HotKeyManager()
    private var cancellables = Set<AnyCancellable>()
    private var visibilityObservation: NSKeyValueObservation?
    private var escapeMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("app", "launched (log file: \(Log.fileURL.path))")
        buildPanel()
        buildStatusItem()
        applyHotKey(settings.hotKey)
        // Re-register the hotkey whenever the user changes the binding in settings.
        settings.$hotKey
            .dropFirst()
            .sink { [weak self] new in
                Log.log("settings", "hotkey changed to \(new.display)")
                self?.applyHotKey(new)
            }
            .store(in: &cancellables)
        // Ask for mic + speech access up front so the first record press works instantly.
        engine.prewarmAuthorization()
        installEscapeMonitor()
        // Show once on launch so the user sees it exists.
        showPanel()
    }

    /// Escape key behaviour:
    ///   – if a recording is in progress and the panel is key: stop the recording and swallow the event
    ///   – otherwise: let the event propagate (default behaviour closes the panel)
    private func installEscapeMonitor() {
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard event.keyCode == UInt16(kVK_Escape), self.panel.isKeyWindow else { return event }
            if self.engine.state == .recording || self.engine.state == .paused {
                Log.log("app", "escape pressed while recording → stopping (keeping panel open)")
                self.engine.stop()
                return nil
            }
            Log.log("app", "escape pressed while idle → allowing default close")
            return event
        }
    }

    private var panelCloseObserver: NSObjectProtocol?

    private func buildPanel() {
        // Small floating utility panel: ~ width of fingers, 2 fingers tall.
        let size = NSSize(width: 360, height: 104)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let origin = NSPoint(
            x: screen.maxX - size.width - 24,
            y: screen.maxY - size.height - 24
        )

        let panel = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Transcribe"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.appearance = NSAppearance(named: .darkAqua)

        let root = ContentView()
            .environmentObject(engine)
            .environmentObject(history)
            .environmentObject(settings)
        panel.contentView = NSHostingView(rootView: root)
        panel.delegate = self
        self.panel = panel

        // Log every close so we can see exactly why the window is disappearing.
        panelCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { _ in
            Log.log("app", "panel willClose")
        }

        // KVO on isVisible to catch orderOut / hide paths that don't fire willClose.
        visibilityObservation = panel.observe(\.isVisible, options: [.old, .new]) { _, change in
            let old = change.oldValue ?? false
            let new = change.newValue ?? false
            if old != new {
                DispatchQueue.main.async {
                    Log.log("panel", "isVisible \(old) → \(new)")
                }
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // User clicked the close button (or something is closing the panel). Make absolutely sure
        // we tear down the mic / recognition session so we don't keep the mic hot in the background.
        Log.log("app", "windowShouldClose → shutting down engine")
        engine.shutdown()
        return true
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Transcribe")
            button.image?.isTemplate = true
            button.action = #selector(togglePanel)
            button.target = self
        }
    }

    private func applyHotKey(_ config: HotKeyConfig) {
        Log.log("app", "applyHotKey → \(config.display)")
        hotKey.register(keyCode: config.keyCode, modifiers: config.modifiers) { [weak self] in
            self?.handleHotKey()
        }
    }

    /// Global-hotkey action: reveal the panel and toggle the recording state.
    /// The hotkey NEVER hides the panel — if you want to dismiss, use the close button or menu bar.
    private func handleHotKey() {
        Log.log("app", "handleHotKey panelVisible=\(panel.isVisible) engineState=\(engine.state)")
        // Always bring the panel forward, even if it's already "visible" — defensive against any
        // path where something else has hidden it.
        showPanel()
        engine.hotKeyTriggered()
    }

    /// Menu bar icon action — toggles panel visibility only, does not touch recording state.
    @objc private func togglePanel() {
        if panel.isVisible {
            Log.log("app", "panel hidden (menu bar toggle)")
            panel.orderOut(nil)
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        Log.log("app", "panel shown")
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.log("app", "applicationWillTerminate → shutting down engine")
        engine.shutdown()
    }
}

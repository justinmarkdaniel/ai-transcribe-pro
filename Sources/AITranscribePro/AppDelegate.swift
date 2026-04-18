import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private var panel: NSPanel!
    private var statusItem: NSStatusItem!
    private let engine = TranscriptionEngine()
    private let history = HistoryStore()
    private let settings = SettingsStore()
    let hotKey = HotKeyManager()
    private var cancellables = Set<AnyCancellable>()
    private var visibilityObservation: NSKeyValueObservation?
    private var escapeMonitor: Any?
    private var quitMonitor: Any?
    private var panelToggleMenuItem: NSMenuItem?
    private var loadOnStartupMenuItem: NSMenuItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("app", "launched (log file: \(Log.fileURL.path))")
        buildPanel()
        buildStatusItem()
        applyHotKeys()
        // Re-register whenever either binding changes in settings.
        settings.$hotKey
            .dropFirst()
            .sink { [weak self] new in
                Log.log("settings", "hotkey1 changed to \(new.display)")
                self?.applyHotKeys()
            }
            .store(in: &cancellables)
        settings.$hotKey2
            .dropFirst()
            .sink { [weak self] new in
                Log.log("settings", "hotkey2 changed to \(new.display)")
                self?.applyHotKeys()
            }
            .store(in: &cancellables)
        // Ask for mic + speech access up front so the first record press works instantly.
        engine.prewarmAuthorization()
        installEscapeMonitor()
        installQuitMonitor()
        // Show once on launch so the user sees it exists.
        showPanel()
    }

    /// Cmd+Q when the panel is key terminates the app. The app is LSUIElement so there's no
    /// main menu wiring cmd+Q automatically — do it explicitly here. Escape is handled separately
    /// and its behaviour is unchanged.
    private func installQuitMonitor() {
        quitMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            let isCmdQ = event.modifierFlags.contains(.command)
                && event.charactersIgnoringModifiers?.lowercased() == "q"
            guard isCmdQ, self.panel.isKeyWindow else { return event }
            Log.log("app", "cmd+Q in panel → terminate")
            NSApp.terminate(nil)
            return nil
        }
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
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
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
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let toggleItem = NSMenuItem(title: "Show Window", action: #selector(togglePanel), keyEquivalent: "")
        toggleItem.target = self
        menu.addItem(toggleItem)
        panelToggleMenuItem = toggleItem

        menu.addItem(.separator())

        let startupItem = NSMenuItem(title: "Load on Startup", action: #selector(toggleLoadOnStartup), keyEquivalent: "")
        startupItem.target = self
        menu.addItem(startupItem)
        loadOnStartupMenuItem = startupItem

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit AI Transcribe Pro", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        panelToggleMenuItem?.title = panel.isVisible ? "Hide Window" : "Show Window"
        loadOnStartupMenuItem?.state = isLaunchAtLoginEnabled() ? .on : .off
    }

    // MARK: - Load on Startup

    private func isLaunchAtLoginEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLoadOnStartup() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
                Log.log("app", "load on startup → disabled")
            } else {
                try service.register()
                Log.log("app", "load on startup → enabled")
            }
        } catch {
            Log.log("app", "load on startup toggle failed: \(error.localizedDescription)")
            let alert = NSAlert()
            alert.messageText = "Couldn't update login item"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private func applyHotKeys() {
        let primary = settings.hotKey
        let secondary = settings.hotKey2
        Log.log("app", "applyHotKeys → \(primary.display), \(secondary.display)")
        hotKey.replaceAll([
            HotKeyBinding(keyCode: primary.keyCode, modifiers: primary.modifiers) { [weak self] in
                self?.handleHotKey()
            },
            HotKeyBinding(keyCode: secondary.keyCode, modifiers: secondary.modifiers) { [weak self] in
                self?.handleHotKey()
            }
        ])
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

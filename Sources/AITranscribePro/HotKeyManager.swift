import Carbon.HIToolbox
import AppKit

struct HotKeyModifiers: OptionSet {
    let rawValue: UInt32
    static let command = HotKeyModifiers(rawValue: UInt32(cmdKey))
    static let option  = HotKeyModifiers(rawValue: UInt32(optionKey))
    static let control = HotKeyModifiers(rawValue: UInt32(controlKey))
    static let shift   = HotKeyModifiers(rawValue: UInt32(shiftKey))
}

final class HotKeyManager {
    private var hotKeyRef: EventHotKeyRef?
    private var handler: (() -> Void)?
    private var eventHandlerRef: EventHandlerRef?

    func register(keyCode: UInt32, modifiers: HotKeyModifiers, action: @escaping () -> Void) {
        // Clear any prior registration so we can be called again when the user changes the binding.
        unregister()
        self.handler = action

        if eventHandlerRef == nil {
            var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                          eventKind: UInt32(kEventHotKeyPressed))
            let selfPtr = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    Log.log("hotkey", "fired")
                    manager.handler?()
                }
                return noErr
            }, 1, &eventType, selfPtr, &eventHandlerRef)
        }

        let hotKeyID = EventHotKeyID(signature: OSType(0x41495450 /* 'AITP' */), id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers.rawValue, hotKeyID,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        Log.log("hotkey", "register keyCode=\(keyCode) modifiers=0x\(String(modifiers.rawValue, radix: 16)) status=\(status)")
    }

    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
            Log.log("hotkey", "unregistered")
        }
    }

    deinit {
        unregister()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

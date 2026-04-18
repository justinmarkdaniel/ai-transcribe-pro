import Carbon.HIToolbox
import AppKit

struct HotKeyModifiers: OptionSet {
    let rawValue: UInt32
    static let command = HotKeyModifiers(rawValue: UInt32(cmdKey))
    static let option  = HotKeyModifiers(rawValue: UInt32(optionKey))
    static let control = HotKeyModifiers(rawValue: UInt32(controlKey))
    static let shift   = HotKeyModifiers(rawValue: UInt32(shiftKey))
}

struct HotKeyBinding {
    let keyCode: UInt32
    let modifiers: HotKeyModifiers
    let action: () -> Void
}

final class HotKeyManager {
    private struct Registration {
        let ref: EventHotKeyRef
        let action: () -> Void
    }

    private var registrations: [UInt32: Registration] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Replaces all current hotkey registrations with the given bindings. Each binding fires
    /// its own action; duplicate combos (e.g. user bound both slots to the same keys) cause
    /// RegisterEventHotKey to fail on the second — we just log and skip.
    func replaceAll(_ bindings: [HotKeyBinding]) {
        unregisterAll()
        installHandlerIfNeeded()
        for binding in bindings {
            let id = nextID
            nextID &+= 1
            let hotKeyID = EventHotKeyID(signature: OSType(0x41495450 /* 'AITP' */), id: id)
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(
                binding.keyCode,
                binding.modifiers.rawValue,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                registrations[id] = Registration(ref: ref, action: binding.action)
            }
            Log.log("hotkey", "register id=\(id) keyCode=\(binding.keyCode) modifiers=0x\(String(binding.modifiers.rawValue, radix: 16)) status=\(status)")
        }
    }

    private func installHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            let firedID = hotKeyID.id
            DispatchQueue.main.async {
                Log.log("hotkey", "fired id=\(firedID)")
                manager.registrations[firedID]?.action()
            }
            return noErr
        }, 1, &eventType, selfPtr, &eventHandlerRef)
    }

    private func unregisterAll() {
        for (_, reg) in registrations {
            UnregisterEventHotKey(reg.ref)
        }
        registrations.removeAll()
        Log.log("hotkey", "unregistered all")
    }

    deinit {
        unregisterAll()
        if let eventHandlerRef { RemoveEventHandler(eventHandlerRef) }
    }
}

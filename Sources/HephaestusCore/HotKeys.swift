import Carbon.HIToolbox

/// Global hotkeys via Carbon (works without extra permissions).
/// Defaults: ⌃⌥← left, ⌃⌥↑ center, ⌃⌥→ right, ⌃⌥Z toggle overlay.
final class HotKeys {
    private var refs: [EventHotKeyRef?] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let me = Unmanaged<HotKeys>.fromOpaque(userData!).takeUnretainedValue()
            me.handlers[hk.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
    }

    func register(keyCode: Int, modifiers: Int = controlKey | optionKey, action: @escaping () -> Void) {
        let id = nextID; nextID += 1
        handlers[id] = action
        var ref: EventHotKeyRef?
        RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                            EventHotKeyID(signature: OSType(0x48455048), id: id),
                            GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}

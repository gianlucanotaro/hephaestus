import Carbon.HIToolbox

/// Global hotkeys via Carbon (works without extra permissions).
/// Defaults: ⌃⌥← left, ⌃⌥↑ center, ⌃⌥→ right, ⌃⌥Z toggle overlay.
final class HotKeys {
    private var refs: [UInt32: EventHotKeyRef] = [:]
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

    /// Registers a hotkey; returns its id for `unregister`, or nil if the system refused it (e.g. already taken).
    @discardableResult
    func register(keyCode: Int, modifiers: Int = controlKey | optionKey, action: @escaping () -> Void) -> UInt32? {
        let id = nextID; nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers),
                                         EventHotKeyID(signature: OSType(0x48455048), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return nil }
        handlers[id] = action
        refs[id] = ref
        return id
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
    }
}

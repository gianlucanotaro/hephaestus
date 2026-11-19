import Carbon.HIToolbox

/// Global hotkeys via Carbon (works without extra permissions).
///
/// There is exactly ONE instance, `HotKeys.shared`: each instance installs its own application event handler and has
/// its own id space, so a second instance would swallow the first one's events (the first handler returns `noErr`
/// for ids it does not know) and collide on ids. Every controller takes it as `hotKeys: HotKeys = .shared`.
final class HotKeys {
    static let shared = HotKeys()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var specs: [UInt32: (keyCode: Int, modifiers: Int)] = [:]
    private var suspendCount = 0

    /// Posted (main thread) whenever the set of combinations the system refused changes.
    static let failuresDidChange = Notification.Name("HephaestusHotKeyFailuresDidChange")
    /// Combinations the system refused to register (e.g. owned by another app or a system shortcut). Cleared per
    /// combination as soon as it registers successfully.
    private(set) var failures = RegistrationFailures()

    private func record(_ keyCode: Int, _ modifiers: Int, succeeded: Bool) {
        let before = failures
        failures.record(Shortcut(keyCode: keyCode, modifiers: HotkeyModifiers(carbon: modifiers)), succeeded: succeeded)
        if failures != before { NotificationCenter.default.post(name: Self.failuresDidChange, object: nil) }
    }

    private init() {
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
        specs[id] = (keyCode, modifiers)
        handlers[id] = action
        if suspendCount == 0 {
            guard let ref = carbonRegister(id) else {
                specs[id] = nil; handlers[id] = nil
                record(keyCode, modifiers, succeeded: false)
                return nil
            }
            refs[id] = ref
        }
        record(keyCode, modifiers, succeeded: true)
        return id
    }

    private func carbonRegister(_ id: UInt32) -> EventHotKeyRef? {
        guard let spec = specs[id] else { return nil }
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(spec.keyCode), UInt32(spec.modifiers),
                                         EventHotKeyID(signature: OSType(0x48455048), id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    func unregister(_ id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        handlers[id] = nil
        specs[id] = nil
    }

    /// Temporarily releases every combination (the shortcut recorder needs to see keys that a registered hotkey
    /// would otherwise swallow). Calls nest; registrations made meanwhile are applied on resume.
    func setSuspended(_ suspended: Bool) {
        if suspended {
            suspendCount += 1
            guard suspendCount == 1 else { return }
            for (_, ref) in refs { UnregisterEventHotKey(ref) }
            refs = [:]
        } else {
            guard suspendCount > 0 else { return }
            suspendCount -= 1
            guard suspendCount == 0 else { return }
            for id in specs.keys.sorted() {
                if let ref = carbonRegister(id) { refs[id] = ref } else if let s = specs[id] {
                    record(s.keyCode, s.modifiers, succeeded: false)
                }
            }
        }
    }
}

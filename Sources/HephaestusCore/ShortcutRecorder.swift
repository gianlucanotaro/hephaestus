import AppKit
import SwiftUI

/// True while a recorder is capturing keys. Global hotkeys are released then (`HotKeys.setSuspended`) and the
/// rotation event tap stands aside, so the pressed combination reaches the recorder instead of triggering its action.
enum ShortcutRecording {
    static var isActive = false
}

/// Key-capturing session: a local `NSEvent` monitor active only while recording. MAIN THREAD ONLY.
final class RecorderSession: ObservableObject {
    @Published var recording = false
    @Published var message: String?
    private var monitor: Any?

    func start(mode: RecorderMode, canClear: Bool, onOutcome: @escaping (RecorderOutcome) -> Void) {
        stop()
        message = nil
        recording = true
        ShortcutRecording.isActive = true
        HotKeys.shared.setSuspended(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let outcome = RecorderPolicy.evaluate(keyCode: Int(event.keyCode),
                                                  modifiers: HotkeyModifiers(flags: event.modifierFlags),
                                                  mode: mode, canClear: canClear)
            if case .rejected(let why) = outcome {
                self.message = why
            } else {
                self.stop()
                onOutcome(outcome)
            }
            return nil   // swallow everything while recording
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        ShortcutRecording.isActive = false
        HotKeys.shared.setSuspended(false)
    }

    deinit { if recording { stop() } }
}

/// Reusable recorder button. Click -> "Press shortcut…"; a key with modifiers is reported through `onOutcome`;
/// Esc cancels; Delete clears when `canClear`; combinations without a modifier are refused with an inline message.
struct ShortcutRecorder: View {
    let display: String
    var mode: RecorderMode = .any
    var canClear = false
    let onOutcome: (RecorderOutcome) -> Void
    @StateObject private var session = RecorderSession()

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Button {
                if session.recording { session.stop() } else { session.start(mode: mode, canClear: canClear, onOutcome: onOutcome) }
            } label: {
                Text(session.recording ? "Press shortcut…" : display)
                    .monospacedDigit().frame(minWidth: 120)
            }
            .help(canClear ? "Click, then press the shortcut. Esc cancels, Delete clears." : "Click, then press the shortcut. Esc cancels.")
            if let message = session.message {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        }
        .onDisappear { session.stop() }
    }
}

/// A labelled recorder bound to a `ShortcutID`, with duplicate and "system refused" warnings.
struct ShortcutRow: View {
    let id: ShortcutID
    @State private var tick = 0

    private var spec: ShortcutSpec { ShortcutSpecs.spec(id) }

    var body: some View {
        _ = tick
        let shortcut = ShortcutStore.read(id)
        let combos = ShortcutStore.combos(id)
        let conflicts = ShortcutConflicts.conflicts(of: id, in: ShortcutStore.entries())
        let refused = HotKeys.shared.failures.contains(anyOf: combos)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(spec.title)
                Spacer()
                ShortcutRecorder(display: Self.display(shortcut, spec: spec), mode: spec.mode, canClear: spec.canClear) { outcome in
                    switch outcome {
                    case .accepted(let s): ShortcutStore.write(s, for: id)
                    case .cleared: ShortcutStore.write(nil, for: id)
                    default: break
                    }
                }
                if shortcut != spec.defaultShortcut || ShortcutStore.read(id) == nil {
                    Button("Reset") { ShortcutStore.write(spec.defaultShortcut, for: id) }.buttonStyle(.link)
                }
            }
            if !conflicts.isEmpty {
                Text("Same shortcut as: \(conflicts.map { ShortcutSpecs.spec($0).title }.joined(separator: ", ")). Only one of them will work.")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if refused {
                Text("macOS refused this shortcut (another app or a system shortcut already uses it). Pick another.")
                    .font(.footnote).foregroundStyle(.red)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in tick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: HotKeys.failuresDidChange)) { _ in tick += 1 }
    }

    static func display(_ shortcut: Shortcut?, spec: ShortcutSpec) -> String {
        guard let shortcut else { return "Not set" }
        if case .group(let keys) = spec.kind { return shortcut.modifiers.symbols + keys.map(KeyNames.name(for:)).joined() }
        return shortcut.display
    }
}

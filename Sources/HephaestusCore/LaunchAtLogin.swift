import AppKit
import ServiceManagement
import SwiftUI

// Launch at login via SMAppService.mainApp (public API, macOS 13+). Needs a bundled, signed app: when running via
// `swift run` there is no bundle and the toggle is disabled with an explanation.

enum LoginItemStatus: Equatable {
    case enabled, requiresApproval, notRegistered, notFound
}

/// Seam over `SMAppService.mainApp` so the logic is testable.
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

struct SMLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered: return .notRegistered
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }
    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

/// What the General tab shows for a status. Pure.
struct LaunchAtLoginState: Equatable {
    var isOn: Bool
    var canToggle: Bool
    var hint: String?
    var showsOpenSettings: Bool

    static func make(status: LoginItemStatus, isAppBundle: Bool) -> LaunchAtLoginState {
        guard isAppBundle else {
            return LaunchAtLoginState(isOn: false, canToggle: false,
                                      hint: "Launch at login needs the bundled app (build/Hephaestus.app); it is unavailable when running from the command line.",
                                      showsOpenSettings: false)
        }
        switch status {
        case .enabled: return LaunchAtLoginState(isOn: true, canToggle: true, hint: nil, showsOpenSettings: false)
        case .notRegistered: return LaunchAtLoginState(isOn: false, canToggle: true, hint: nil, showsOpenSettings: false)
        case .requiresApproval:
            return LaunchAtLoginState(isOn: true, canToggle: true,
                                      hint: "Approve Hephaestus in System Settings → General → Login Items to finish enabling this.",
                                      showsOpenSettings: true)
        case .notFound:
            return LaunchAtLoginState(isOn: false, canToggle: false,
                                      hint: "macOS cannot find this app as a login item. Run the signed Hephaestus.app from a stable location (e.g. /Applications).",
                                      showsOpenSettings: false)
        }
    }
}

final class LaunchAtLoginModel: ObservableObject {
    @Published private(set) var state: LaunchAtLoginState
    @Published private(set) var error: String?
    private let service: LoginItemService
    private let isAppBundle: Bool

    init(service: LoginItemService = SMLoginItemService(), isAppBundle: Bool = Bundle.main.bundleURL.pathExtension == "app") {
        self.service = service
        self.isAppBundle = isAppBundle
        state = .make(status: service.status, isAppBundle: isAppBundle)
    }

    func refresh() { state = .make(status: service.status, isAppBundle: isAppBundle) }

    /// Registers / unregisters; failures are kept in `error` (shown inline) and the state re-read from the system.
    func setEnabled(_ on: Bool) {
        error = nil
        do {
            if on { try service.register() } else { try service.unregister() }
        } catch {
            self.error = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() { service.openSystemSettings() }
}

/// Accessibility permission row. Pure text mapping so it is testable.
enum AccessibilityStatusText {
    static func message(trusted: Bool) -> String {
        trusted
            ? "Accessibility access is granted."
            : "Accessibility access is not granted. Hephaestus cannot move windows until you allow it. After granting it, quit and relaunch Hephaestus: rotation and mouse-wheel layout cycling use event taps that only start with the permission."
    }
}

struct GeneralSettingsView: View {
    @StateObject private var login = LaunchAtLoginModel()
    @State private var trusted = AXIsProcessTrusted()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "development build"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("General").font(.headline)
            Toggle("Launch Hephaestus at login", isOn: Binding(get: { login.state.isOn }, set: { login.setEnabled($0) }))
                .disabled(!login.state.canToggle)
            if let hint = login.state.hint { Text(hint).font(.footnote).foregroundStyle(.secondary) }
            if login.state.showsOpenSettings {
                Button("Open Login Items Settings…") { login.openLoginItemsSettings() }
            }
            if let error = login.error { Text(error).font(.footnote).foregroundStyle(.red) }

            Divider()
            Text("Accessibility").font(.headline)
            HStack {
                Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(trusted ? .green : .orange)
                Text(trusted ? "Trusted" : "Not trusted")
            }
            Text(AccessibilityStatusText.message(trusted: trusted)).font(.footnote).foregroundStyle(.secondary)
            if !trusted {
                Button("Open Accessibility Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Divider()
            Text("About").font(.headline)
            Text("Hephaestus \(version)")
            Text("A FancyZones-style window manager for macOS. Choose the layout from the menu bar; the full hotkey list is in the README.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onAppear { login.refresh(); trusted = AXIsProcessTrusted() }
        .onReceive(timer) { _ in
            trusted = AXIsProcessTrusted()
            login.refresh()
        }
    }
}

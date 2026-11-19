import AppKit
import SwiftUI

/// Drives checks (scheduled and manual), the alerts, and the install. UI only; the logic lives in the pure Update* files.
final class UpdateController: NSObject {
    nonisolated(unsafe) static let shared = UpdateController()
    private var busy = false
    private var schedulerTask: Task<Void, Never>?
    private var progressPanel: NSPanel?

    /// First automatic check ~30 s after launch (if due), then re-evaluated at least hourly.
    @MainActor func start() {
        guard schedulerTask == nil else { return }
        schedulerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(UpdateSchedule.initialDelay * 1e9))
            while !Task.isCancelled {
                let now = Date()
                if UserDefaults.standard.bool(forKey: Prefs.autoUpdateCheckKey), UpdateKey.isConfigured,
                   UpdateSchedule.secondsUntilDue(lastCheck: Prefs.lastUpdateCheck, now: now) == 0 {
                    await self?.check(userInitiated: false)
                }
                let delay = UpdateSchedule.nextWakeDelay(lastCheck: Prefs.lastUpdateCheck, now: Date())
                try? await Task.sleep(nanoseconds: UInt64(delay * 1e9))
            }
        }
    }

    @MainActor @objc func checkForUpdates(_ sender: Any?) { Task { await check(userInitiated: true) } }

    @MainActor func check(userInitiated: Bool) async {
        guard !busy else { return }
        guard UpdateKey.isConfigured else {
            if userInitiated { alert(UpdateError.notConfigured.localizedDescription, info: "This build has no update signing key, so it never installs updates.") }
            return
        }
        busy = true
        defer { busy = false }
        do {
            let release = try await UpdateChecker().fetchLatest()
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Prefs.lastUpdateCheckKey)
            guard let latest = release.version, !release.draft, !release.prerelease else {
                if userInitiated { alert("You're up to date (\(HephaestusVersionText.current))") }
                return
            }
            let skipped = UserDefaults.standard.string(forKey: Prefs.skippedUpdateVersionKey)
            switch UpdateDecision.evaluate(current: .current, latest: latest, skipped: skipped, userInitiated: userInitiated) {
            case .upToDate:
                if userInitiated { alert("You're up to date (\(HephaestusVersionText.current))") }
            case .skipped:
                break
            case .available(let v):
                await offer(release: release, version: v)
            }
        } catch {
            if !userInitiated { NSLog("Hephaestus update check failed: \(error.localizedDescription)") }
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Prefs.lastUpdateCheckKey)
            if userInitiated { alert(error.localizedDescription) }
        }
    }

    @MainActor private func offer(release: GitHubRelease, version: AppVersion) async {
        let a = NSAlert()
        a.messageText = "Hephaestus \(version.text) is available (you have \(HephaestusVersionText.current))."
        a.informativeText = ReleaseNotes.excerpt(release.body)
        a.addButton(withTitle: "Install & Restart")
        a.addButton(withTitle: "Later")
        a.addButton(withTitle: "Skip This Version")
        NSApp.activate(ignoringOtherApps: true)
        switch a.runModal() {
        case .alertFirstButtonReturn: await install(release: release, version: version)
        case .alertThirdButtonReturn: UserDefaults.standard.set(version.text, forKey: Prefs.skippedUpdateVersionKey)
        default: break
        }
    }

    @MainActor private func install(release: GitHubRelease, version: AppVersion) async {
        let plan = InstallPlan.make(bundleURL: Bundle.main.bundleURL) { FileManager.default.isWritableFile(atPath: $0.path) }
        let destination: URL
        switch plan {
        case .refuse(let reason):
            alert("Can't install the update", info: reason)
            return
        case .openReleasePage(let reason):
            offerReleasePage(release, message: "Can't install automatically", info: reason)
            return
        case .swap(let d): destination = d
        }
        guard let assets = UpdateAssets.select(release, version: version) else {
            offerReleasePage(release, message: UpdateError.noSignedAssets(version.text).localizedDescription, info: nil)
            return
        }
        showProgress("Downloading and verifying Hephaestus \(version.text)…")
        do {
            let prepared = try await UpdateInstaller.prepare(assets: assets, version: version)
            hideProgress()
            do {
                try UpdateInstaller.launchSwap(prepared, destination: destination)
            } catch {
                try? FileManager.default.removeItem(at: prepared.workDir)
                throw UpdateError.notInstallable("Couldn't start the installer: \(error.localizedDescription)")
            }
            NSApp.terminate(nil)
        } catch {
            hideProgress()
            offerReleasePage(release, message: error.localizedDescription, info: nil)
        }
    }

    @MainActor private func offerReleasePage(_ release: GitHubRelease, message: String, info: String?) {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = message
        if let info { a.informativeText = info }
        a.addButton(withTitle: "Open Release Page")
        a.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn, let url = URL(string: release.htmlURL), UpdateHostPolicy.isAllowed(url) {
            NSWorkspace.shared.open(url)
        }
    }

    @MainActor private func alert(_ message: String, info: String? = nil) {
        let a = NSAlert()
        a.messageText = message
        if let info { a.informativeText = info }
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }

    @MainActor private func showProgress(_ text: String) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 90), styleMask: [.titled, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "Hephaestus Update"
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: text)
        label.frame = NSRect(x: 20, y: 48, width: 300, height: 20)
        let bar = NSProgressIndicator(frame: NSRect(x: 20, y: 22, width: 300, height: 14))
        bar.style = .bar
        bar.isIndeterminate = true
        bar.startAnimation(nil)
        panel.contentView?.addSubview(label)
        panel.contentView?.addSubview(bar)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        progressPanel = panel
    }

    @MainActor private func hideProgress() {
        progressPanel?.close()
        progressPanel = nil
    }
}

enum HephaestusVersionText {
    static var current: String { AppVersion.current.text }
}

/// The single menu insertion point.
enum UpdateMenu {
    static func addItem(to menu: NSMenu) {
        let item = NSMenuItem(title: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
        item.target = UpdateController.shared
        if !UpdateKey.isConfigured {
            item.title = "Check for Updates… (not configured in this build)"
            item.isEnabled = false
        }
        menu.addItem(item)
    }
}

/// Settings > General > Updates.
struct UpdateSettingsSection: View {
    @AppStorage(Prefs.autoUpdateCheckKey) private var auto = true
    @AppStorage(Prefs.lastUpdateCheckKey) private var last = 0.0

    var body: some View {
        Section {
            Text("Updates").font(.headline)
            Text("Version \(HephaestusVersionText.current)")
            if UpdateKey.isConfigured {
                Toggle("Check for updates automatically", isOn: $auto)
                Text("Last checked: \(lastText)").settingsHint()
                Button("Check Now") { UpdateController.shared.checkForUpdates(nil) }
                Text("Updates are downloaded from GitHub Releases, verified against a built-in signature key, and only installed when you click Install & Restart.")
                    .settingsHint()
            } else {
                Text("Updates aren't configured in this build.").settingsHint(.orange)
            }
        }
    }

    private var lastText: String {
        guard last > 0 else { return "Never" }
        return RelativeDateTimeFormatter().localizedString(for: Date(timeIntervalSince1970: last), relativeTo: Date())
    }
}

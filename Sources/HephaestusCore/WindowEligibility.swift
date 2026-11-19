import AppKit
import ApplicationServices
import SwiftUI

extension Prefs {
    static let allowDialogsKey = "eligibilityAllowDialogs"
    static let allowFloatingKey = "eligibilityAllowFloating"
    static let allowChildWindowsKey = "eligibilityAllowChildWindows"
    static let excludedAppsKey = "eligibilityExcludedApps"

    static func registerEligibilityDefaults() {
        UserDefaults.standard.register(defaults: [
            allowDialogsKey: false, allowFloatingKey: false, allowChildWindowsKey: false, excludedAppsKey: "",
        ])
    }

    static var eligibilityPolicy: EligibilityPolicy {
        let d = UserDefaults.standard
        return EligibilityPolicy(allowDialogs: d.bool(forKey: allowDialogsKey),
                                 allowFloating: d.bool(forKey: allowFloatingKey),
                                 allowChildWindows: d.bool(forKey: allowChildWindowsKey))
    }
    static var excludedApps: String { UserDefaults.standard.string(forKey: excludedAppsKey) ?? "" }
}

/// What the AX adapter read about a window. Everything the pure classifier needs.
struct WindowTraits: Equatable {
    var role: String?
    var subrole: String?
    var isModal = false
    /// The window is owned by another window (AXParent is a window).
    var hasParentWindow = false
    var isMinimized = false
    var isFullScreen = false
}

struct EligibilityPolicy: Equatable {
    var allowDialogs = false
    var allowFloating = false
    var allowChildWindows = false
}

enum WindowEligibility {
    /// Single entry point for drag, hotkeys and (future) auto-placement.
    /// Reads AX attributes, checks the app exclusion list, then classifies.
    static func canSnap(window: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        if let app = NSRunningApplication(processIdentifier: pid),
           AppExclusion.matches(bundleID: app.bundleIdentifier, name: app.localizedName, list: Prefs.excludedApps) {
            return false
        }
        return isSnappable(readTraits(window), policy: Prefs.eligibilityPolicy)
    }

    /// Pure classification.
    static func isSnappable(_ t: WindowTraits, policy: EligibilityPolicy) -> Bool {
        if t.isFullScreen || t.isMinimized { return false }
        guard t.role == kAXWindowRole as String else { return false }   // sheets, popovers, drawers etc. are other roles
        if t.hasParentWindow && !policy.allowChildWindows { return false }
        if t.isModal && !policy.allowDialogs { return false }
        switch t.subrole {
        case kAXStandardWindowSubrole: return true
        case kAXDialogSubrole, kAXSystemDialogSubrole: return policy.allowDialogs
        case kAXFloatingWindowSubrole, kAXSystemFloatingWindowSubrole: return policy.allowFloating
        default: return false   // sheets, unknown, nil
        }
    }

    // MARK: AX adapter

    static func readTraits(_ w: AXUIElement) -> WindowTraits {
        var t = WindowTraits()
        t.role = string(w, kAXRoleAttribute)
        t.subrole = string(w, kAXSubroleAttribute)
        t.isModal = bool(w, kAXModalAttribute)
        t.isMinimized = bool(w, kAXMinimizedAttribute)
        t.isFullScreen = bool(w, "AXFullScreen")
        var parent: CFTypeRef?
        if AXUIElementCopyAttributeValue(w, kAXParentAttribute as CFString, &parent) == .success, let p = parent,
           CFGetTypeID(p) == AXUIElementGetTypeID() {
            t.hasParentWindow = string(p as! AXUIElement, kAXRoleAttribute) == kAXWindowRole as String
        }
        return t
    }

    private static func string(_ e: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success else { return nil }
        return ref as? String
    }

    private static func bool(_ e: AXUIElement, _ attr: String) -> Bool {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, attr as CFString, &ref) == .success else { return false }
        return (ref as? Bool) ?? false
    }
}

enum AppExclusion {
    /// `list` has one entry per line. An entry matches when it is a case-insensitive substring of the
    /// app's bundle id or name (so exact names and partial names both work). Blank lines are ignored.
    static func matches(bundleID: String?, name: String?, list: String) -> Bool {
        for line in list.split(whereSeparator: \.isNewline) {
            let entry = line.trimmingCharacters(in: .whitespaces)
            guard !entry.isEmpty else { continue }
            if let bundleID, bundleID.range(of: entry, options: .caseInsensitive) != nil { return true }
            if let name, name.range(of: entry, options: .caseInsensitive) != nil { return true }
        }
        return false
    }
}

/// Settings section: which windows may snap, overlap resolution, excluded apps.
struct EligibilitySettingsView: View {
    @AppStorage(Prefs.allowDialogsKey) private var allowDialogs = false
    @AppStorage(Prefs.allowFloatingKey) private var allowFloating = false
    @AppStorage(Prefs.allowChildWindowsKey) private var allowChildWindows = false
    @AppStorage(Prefs.overlapResolutionKey) private var overlap = OverlapResolution.smallest.rawValue
    @AppStorage(Prefs.excludedAppsKey) private var excluded = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Window eligibility").font(.headline)
            Toggle("Snap dialog windows", isOn: $allowDialogs)
            Toggle("Snap floating / utility windows", isOn: $allowFloating)
            Toggle("Snap child windows", isOn: $allowChildWindows)
            Text("Only standard windows snap by default. Sheets, popups and fullscreen windows never do.")
                .settingsHint()
            Picker("Overlapping zones", selection: $overlap) {
                ForEach(OverlapResolution.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }
            Text("Excluded apps (one per line; bundle id or name, partial match, case-insensitive)")
            TextEditor(text: $excluded)
                .font(.system(.body, design: .monospaced))
                .frame(height: 70)
                .border(Color.secondary.opacity(0.4))
        }
    }
}

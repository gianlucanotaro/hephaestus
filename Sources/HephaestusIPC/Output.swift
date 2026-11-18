import Foundation

/// Turns responses into the text the CLI prints. Pure.
public enum CLIOutput {
    public static func render(_ request: Request, _ response: Response) -> String {
        switch request.command {
        case .getMonitors:
            return (response.monitors ?? []).map { m in
                "\(m.index): \(m.name)\(m.isMain ? " (main)" : "")  \(m.width)x\(m.height)  layout: \(m.layoutName)"
            }.joined(separator: "\n")
        case .getActiveLayout:
            return (response.monitors ?? []).map { "Monitor \($0.index) (\($0.name)): \($0.layoutName) [\($0.layoutID)]" }
                .joined(separator: "\n")
        case .getLayouts:
            return (response.layouts ?? []).map { l in
                var head = "\(l.name)  [\(l.id)]  \(l.kind)\(l.builtIn ? ", built-in" : "")"
                if let h = l.hotkey { head += "  hotkey \(h)" }
                let art = AsciiPreview.render(l.zones).split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "    " + $0 }.joined(separator: "\n")
                return head + "\n" + art
            }.joined(separator: "\n\n")
        case .getHotkeys:
            let mods = response.hotkeyModifiers.map { $0.isEmpty ? "" : "Modifiers: \($0)\n" } ?? ""
            let rows = (response.hotkeys ?? []).map { "\($0.number): \($0.layoutName) [\($0.layoutID)]" }
            return rows.isEmpty ? mods + "No hotkeys assigned." : mods + rows.joined(separator: "\n")
        case .openEditor, .openSettings, .setLayout, .setHotkey, .removeHotkey:
            return response.message ?? "OK"
        }
    }
}

import Foundation
import HephaestusIPC

/// "x.y" / "x.y.z" (optional leading "v"). Missing components count as 0, so 1.0 == 1.0.0.
struct AppVersion: Comparable, Hashable, CustomStringConvertible {
    let parts: [Int]
    /// The text without the "v" prefix, as used in asset names.
    let text: String

    init?(_ raw: String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let pieces = s.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(pieces.count) else { return nil }
        var nums: [Int] = []
        for p in pieces {
            guard !p.isEmpty, p.count <= 6, p.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(p) else { return nil }
            nums.append(n)
        }
        parts = nums
        text = s
    }

    static var current: AppVersion { AppVersion(HephaestusVersion.current)! }

    private func padded(_ n: Int) -> [Int] { parts + Array(repeating: 0, count: max(0, n - parts.count)) }
    static func == (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        return a.padded(n) == b.padded(n)
    }
    func hash(into h: inout Hasher) {
        var p = parts
        while p.count > 1, p.last == 0 { p.removeLast() }
        h.combine(p)
    }
    static func < (a: AppVersion, b: AppVersion) -> Bool {
        let n = max(a.parts.count, b.parts.count)
        return a.padded(n).lexicographicallyPrecedes(b.padded(n))
    }
    var description: String { text }
}

struct GitHubAsset: Codable, Equatable {
    var name: String
    var browserDownloadURL: String
    var size: Int?
    enum CodingKeys: String, CodingKey { case name, size; case browserDownloadURL = "browser_download_url" }
}

struct GitHubRelease: Codable, Equatable {
    var tagName: String
    var name: String?
    var body: String?
    var htmlURL: String
    var draft: Bool
    var prerelease: Bool
    var assets: [GitHubAsset]
    enum CodingKeys: String, CodingKey {
        case name, body, draft, prerelease, assets
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try c.decode(String.self, forKey: .tagName)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        body = try c.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try c.decode(String.self, forKey: .htmlURL)
        draft = try c.decodeIfPresent(Bool.self, forKey: .draft) ?? false
        prerelease = try c.decodeIfPresent(Bool.self, forKey: .prerelease) ?? false
        assets = try c.decodeIfPresent([GitHubAsset].self, forKey: .assets) ?? []
    }

    init(tagName: String, name: String? = nil, body: String? = nil, htmlURL: String, draft: Bool = false,
         prerelease: Bool = false, assets: [GitHubAsset] = []) {
        self.tagName = tagName; self.name = name; self.body = body; self.htmlURL = htmlURL
        self.draft = draft; self.prerelease = prerelease; self.assets = assets
    }

    var version: AppVersion? { AppVersion(tagName) }
}

struct UpdateAssets: Equatable {
    var zip: GitHubAsset
    var signature: GitHubAsset

    static func zipName(_ v: AppVersion) -> String { "Hephaestus-\(v.text).zip" }

    /// Both `Hephaestus-<version>.zip` and its `.sig`; nil for drafts, prereleases, or when either is missing.
    static func select(_ release: GitHubRelease, version: AppVersion) -> UpdateAssets? {
        guard !release.draft, !release.prerelease else { return nil }
        let zipName = zipName(version)
        guard let zip = release.assets.first(where: { $0.name == zipName }),
              let sig = release.assets.first(where: { $0.name == zipName + ".sig" }) else { return nil }
        return UpdateAssets(zip: zip, signature: sig)
    }
}

enum UpdateDecision: Equatable {
    case upToDate
    case available(AppVersion)
    case skipped(AppVersion)

    /// A skipped version only silences automatic checks; a user-initiated check always offers it.
    static func evaluate(current: AppVersion, latest: AppVersion, skipped: String?, userInitiated: Bool) -> UpdateDecision {
        guard latest > current else { return .upToDate }
        if !userInitiated, let skipped, let s = AppVersion(skipped), s == latest { return .skipped(latest) }
        return .available(latest)
    }
}

enum UpdateSchedule {
    static let initialDelay: TimeInterval = 30
    static let interval: TimeInterval = 24 * 3600

    /// Seconds until an automatic check is due (0 = now). A missing or future timestamp counts as due.
    static func secondsUntilDue(lastCheck: Date?, now: Date) -> TimeInterval {
        guard let lastCheck, lastCheck <= now else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastCheck))
    }

    /// How long the scheduler sleeps before looking again: never more than an hour (wake from sleep, clock changes).
    static func nextWakeDelay(lastCheck: Date?, now: Date) -> TimeInterval {
        min(3600, max(60, secondsUntilDue(lastCheck: lastCheck, now: now)))
    }
}

enum ReleaseNotes {
    /// Plain-text excerpt for the alert: markdown markers dropped, cut at `limit` characters.
    static func excerpt(_ body: String?, limit: Int = 600) -> String {
        guard let body else { return "" }
        let cleaned = body.replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var l = String(line).trimmingCharacters(in: .whitespaces)
                while l.hasPrefix("#") { l.removeFirst() }
                return l.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
                    .trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.count > limit else { return cleaned }
        return String(cleaned.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

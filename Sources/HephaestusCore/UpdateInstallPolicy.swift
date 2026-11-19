import Foundation

/// Pure policy pieces of the updater: which URLs may be fetched, how the downloaded bundle is validated, where it
/// is installed, and the helper script that swaps the bundle. Everything here is unit-tested.

enum UpdateError: LocalizedError, Equatable {
    case notConfigured
    case unreachable
    case badResponse
    case noSignedAssets(String)
    case disallowedURL(String)
    case tooLarge
    case downloadFailed(String)
    case signatureInvalid
    case unzipFailed
    case badBundle(String)
    case codeSignature(String)
    case notInstallable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Updates aren't configured in this build."
        case .unreachable: return "Couldn't check for updates (repository not reachable)."
        case .badResponse: return "Couldn't check for updates (unexpected response from GitHub)."
        case .noSignedAssets(let v): return "Release \(v) has no signed download (expected Hephaestus-\(v).zip and its .sig)."
        case .disallowedURL(let u): return "Refused to download from an untrusted address (\(u))."
        case .tooLarge: return "The update is larger than the allowed size."
        case .downloadFailed(let m): return "The download failed (\(m))."
        case .signatureInvalid: return "The update's signature is invalid. It was not installed."
        case .unzipFailed: return "The update could not be unpacked."
        case .badBundle(let m): return "The update is not a valid Hephaestus app (\(m)). It was not installed."
        case .codeSignature(let m): return "The update's code signature doesn't match this app (\(m)). It was not installed."
        case .notInstallable(let m): return m
        }
    }
}

enum UpdateHostPolicy {
    static let allowedHosts: Set<String> = ["github.com", "api.github.com", "objects.githubusercontent.com",
                                            "release-assets.githubusercontent.com"]

    /// https only, allowlisted host, default port, no embedded credentials. Applied to asset URLs and every redirect hop.
    static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), allowedHosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return false }
        return true
    }
}

/// Refuses redirects that leave the allowlist (or downgrade to http). Used by the checker and the downloader.
final class UpdateRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(UpdateHostPolicy.isAllowed) == true ? request : nil)
    }
}

enum UpdateLimits {
    static let maxZipBytes: Int64 = 300 * 1024 * 1024
    static let maxSignatureBytes: Int64 = 4 * 1024
}

enum UpdateBundleCheck {
    static let appName = "Hephaestus.app"

    /// The unzipped directory must hold exactly one top-level item, `Hephaestus.app`.
    static func validateTopLevel(_ names: [String]) -> UpdateError? {
        names == [appName] ? nil : .badBundle("expected exactly \(appName) at the top level")
    }

    /// The new bundle's Info.plist must be the same app, exactly the version the release advertised, and newer than ours.
    static func validateInfo(_ info: [String: Any], expectedBundleID: String?, expectedVersion: AppVersion,
                             current: AppVersion) -> UpdateError? {
        guard let id = info["CFBundleIdentifier"] as? String, let expectedBundleID, id == expectedBundleID else {
            return .badBundle("wrong bundle identifier")
        }
        guard let short = info["CFBundleShortVersionString"] as? String, let v = AppVersion(short), v == expectedVersion else {
            return .badBundle("version doesn't match the release")
        }
        guard v > current else { return .badBundle("not newer than the running version") }
        return nil
    }

    /// Dev builds are ad-hoc signed, so their designated requirement is a hash of that one build and can never match a
    /// release. For those (and only those) the code-signature requirement is skipped; the Ed25519 signature still applies.
    static func requiresDesignatedRequirement(runningIsAdHoc: Bool) -> Bool { !runningIsAdHoc }
}

enum InstallPlan: Equatable {
    case swap(destination: URL)
    case openReleasePage(reason: String)
    case refuse(reason: String)

    /// `isWritable` is injected for tests (FileManager.isWritableFile in production).
    static func make(bundleURL: URL, isWritable: (URL) -> Bool) -> InstallPlan {
        guard bundleURL.pathExtension == "app" else {
            return .refuse(reason: "Hephaestus isn't running from an app bundle, so it can't update itself.")
        }
        let parent = bundleURL.deletingLastPathComponent()
        guard isWritable(bundleURL), isWritable(parent) else {
            return .openReleasePage(reason: "Hephaestus can't replace itself in \(parent.path) (no write permission). Download the update from the release page instead.")
        }
        return .swap(destination: bundleURL)
    }
}

/// The detached swap helper. The script text is a constant: paths and the pid are passed as arguments ($1...$5) and
/// never interpolated into it, so odd characters in a path cannot change what runs.
enum UpdateInstallScript {
    static let text = """
    #!/bin/sh
    # Hephaestus update helper. Arguments: $1 pid of the running app, $2 new app, $3 destination app,
    # $4 backup path, $5 work directory (removed at the end).
    PID="$1"; NEW="$2"; DEST="$3"; BACKUP="$4"; WORK="$5"
    case "$PID" in ''|*[!0-9]*) exit 2 ;; esac
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      i=$((i + 1))
      if [ "$i" -gt 300 ]; then exit 1; fi   # the app did not quit within 30 s: leave everything untouched
      sleep 0.1
    done
    if ! /bin/mv "$DEST" "$BACKUP"; then
      /usr/bin/open "$DEST"
      exit 1
    fi
    if /usr/bin/ditto "$NEW" "$DEST"; then
      /usr/bin/xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
      /usr/bin/open "$DEST"
      /bin/rm -rf "$WORK"
    else
      /bin/rm -rf "$DEST"
      /bin/mv "$BACKUP" "$DEST"
      /usr/bin/open "$DEST"
      /bin/rm -rf "$WORK"
      exit 1
    fi

    """

    /// Argument order is part of the contract with `text`.
    static func arguments(script: URL, pid: Int32, newApp: URL, destination: URL, backup: URL, workDir: URL) -> [String] {
        [script.path, String(pid), newApp.path, destination.path, backup.path, workDir.path]
    }
}

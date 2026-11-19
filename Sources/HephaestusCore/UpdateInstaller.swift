import AppKit
import Foundation
import Security

/// Streams one file to disk, aborting past `maxBytes`, refusing redirects off the allowlist.
final class UpdateDownloader: NSObject, URLSessionDownloadDelegate {
    private let maxBytes: Int64
    private let destination: URL
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: UpdateError?
    private var moved = false

    init(maxBytes: Int64, destination: URL) {
        self.maxBytes = maxBytes
        self.destination = destination
    }

    func download(_ url: URL) async throws {
        guard UpdateHostPolicy.isAllowed(url) else { throw UpdateError.disallowedURL(url.host ?? url.absoluteString) }
        let config = UpdateChecker.configuration()
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            continuation = c
            session.downloadTask(with: request).resume()
        }
    }

    private func finish(_ error: Error?) {
        guard let c = continuation else { return }
        continuation = nil
        if let failure { c.resume(throwing: failure) } else if let error { c.resume(throwing: UpdateError.downloadFailed(error.localizedDescription)) } else { c.resume() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if let u = request.url, UpdateHostPolicy.isAllowed(u) { completionHandler(request) } else {
            failure = .disallowedURL(request.url?.host ?? "?")
            completionHandler(nil)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes || totalBytesExpectedToWrite > maxBytes {
            failure = .tooLarge
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let http = downloadTask.response as? HTTPURLResponse, http.statusCode == 200 else {
            failure = .downloadFailed("HTTP \((downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0)")
            return
        }
        let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? nil
        guard let size, size <= maxBytes else { failure = .tooLarge; return }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            moved = true
        } catch { failure = .downloadFailed(error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if error == nil, !moved, failure == nil { failure = .downloadFailed("no data") }
        finish(error)
    }
}

/// A downloaded, verified update waiting for the user's restart.
struct PreparedUpdate {
    var workDir: URL
    var newApp: URL
    var version: AppVersion
}

enum UpdateInstaller {
    static func makeWorkDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hephaestus-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return dir
    }

    /// Download -> verify the Ed25519 signature -> only then unzip -> validate the bundle. Throws before anything is installed.
    static func prepare(assets: UpdateAssets, version: AppVersion, publicKeyBase64: String = UpdateKey.publicKeyBase64) async throws -> PreparedUpdate {
        guard UpdateKey.publicKey(from: publicKeyBase64) != nil else { throw UpdateError.notConfigured }
        guard let zipURL = URL(string: assets.zip.browserDownloadURL), let sigURL = URL(string: assets.signature.browserDownloadURL) else {
            throw UpdateError.disallowedURL("invalid URL")
        }
        let work = try makeWorkDir()
        do {
            let zip = work.appendingPathComponent("update.zip"), sig = work.appendingPathComponent("update.zip.sig")
            try await UpdateDownloader(maxBytes: UpdateLimits.maxSignatureBytes, destination: sig).download(sigURL)
            try await UpdateDownloader(maxBytes: UpdateLimits.maxZipBytes, destination: zip).download(zipURL)

            let sigText = String(decoding: try Data(contentsOf: sig), as: UTF8.self)
            let zipData = try Data(contentsOf: zip, options: .mappedIfSafe)
            guard UpdateSignature.verify(data: zipData, signatureBase64: sigText, publicKeyBase64: publicKeyBase64) else {
                throw UpdateError.signatureInvalid
            }

            // Signature is good; only now is the archive opened.
            let extracted = work.appendingPathComponent("extracted", isDirectory: true)
            try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            guard run("/usr/bin/ditto", ["-x", "-k", zip.path, extracted.path]) == 0 else { throw UpdateError.unzipFailed }
            let names = try FileManager.default.contentsOfDirectory(atPath: extracted.path)
            if let e = UpdateBundleCheck.validateTopLevel(names) { throw e }
            let app = extracted.appendingPathComponent(UpdateBundleCheck.appName, isDirectory: true)

            let plistURL = app.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: plistURL),
                  let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
                throw UpdateError.badBundle("missing Info.plist")
            }
            if let e = UpdateBundleCheck.validateInfo(info, expectedBundleID: Bundle.main.bundleIdentifier,
                                                      expectedVersion: version, current: .current) { throw e }
            try checkCodeSignature(of: app)
            return PreparedUpdate(workDir: work, newApp: app, version: version)
        } catch {
            try? FileManager.default.removeItem(at: work)
            throw error
        }
    }

    /// Requires the new app to satisfy the RUNNING app's designated requirement (same signing identity), strict and deep.
    /// Skipped only when the running app is ad-hoc signed (dev builds), where the requirement is a per-build hash.
    static func checkCodeSignature(of app: URL) throws {
        var selfCode: SecCode?
        var selfStatic: SecStaticCode?
        guard SecCodeCopySelf([], &selfCode) == errSecSuccess, let selfCode,
              SecCodeCopyStaticCode(selfCode, [], &selfStatic) == errSecSuccess, let selfStatic else {
            throw UpdateError.codeSignature("can't inspect the running app")
        }
        var infoRef: CFDictionary?
        let adHoc: Bool
        if SecCodeCopySigningInformation(selfStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &infoRef) == errSecSuccess,
           let info = infoRef as? [String: Any], let flags = info[kSecCodeInfoFlags as String] as? UInt32 {
            adHoc = flags & SecCodeSignatureFlags.adhoc.rawValue != 0
        } else {
            adHoc = true   // unsigned or unreadable: no identity to compare against
        }
        guard UpdateBundleCheck.requiresDesignatedRequirement(runningIsAdHoc: adHoc) else { return }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(selfStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.codeSignature("the running app has no designated requirement")
        }
        var newCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &newCode) == errSecSuccess, let newCode else {
            throw UpdateError.codeSignature("can't read the new app")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var cfError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(newCode, flags, requirement, &cfError)
        guard status == errSecSuccess else {
            throw UpdateError.codeSignature("OSStatus \(status)")
        }
    }

    /// Writes the helper script, starts it detached, and returns. The caller then terminates the app.
    static func launchSwap(_ update: PreparedUpdate, destination: URL) throws {
        let script = update.workDir.appendingPathComponent("swap.sh")
        try UpdateInstallScript.text.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let backup = update.workDir.appendingPathComponent("Hephaestus.app.backup", isDirectory: true)
        let args = UpdateInstallScript.arguments(script: script, pid: ProcessInfo.processInfo.processIdentifier,
                                                 newApp: update.newApp, destination: destination, backup: backup, workDir: update.workDir)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
        p.arguments = ["/bin/sh"] + args
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()   // not waited on: it outlives this process and waits for our pid to exit
    }

    @discardableResult
    private static func run(_ path: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }
}

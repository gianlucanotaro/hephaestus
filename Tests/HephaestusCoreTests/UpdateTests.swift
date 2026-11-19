import CryptoKit
import Foundation
import Testing
@testable import HephaestusCore

private func v(_ s: String) -> AppVersion { AppVersion(s)! }

@Suite struct UpdateVersionTests {
    @Test func ordering() {
        #expect(v("0.1") < v("0.2"))
        #expect(v("0.9") < v("0.10"))
        #expect(v("1.0") == v("1.0.0"))
        #expect(v("1.0.1") > v("1.0"))
        #expect(v("v1.2") == v("1.2.0"))
        #expect(v("2.0") > v("1.99.99"))
    }
    @Test func garbageIsRejected() {
        for s in ["", "v", "abc", "1..2", "1.a", "1.2.3.4.5", "-1.0", "1.0-beta", "١.٢"] { #expect(AppVersion(s) == nil, "\(s)") }
    }
    @Test func textDropsPrefix() { #expect(v("v0.2").text == "0.2") }
    @Test func currentParses() { #expect(AppVersion(HephaestusVersionText.current) != nil) }
}

@Suite struct UpdateReleaseTests {
    private func json(tag: String = "v0.2", draft: Bool = false, pre: Bool = false, assets: String) -> Data {
        Data("""
        {"tag_name":"\(tag)","name":"Hephaestus","body":"## Notes\\n**Bold** `code`","html_url":"https://github.com/x/y/releases/tag/\(tag)",
         "draft":\(draft),"prerelease":\(pre),"assets":[\(assets)]}
        """.utf8)
    }
    private func asset(_ n: String) -> String { #"{"name":"\#(n)","browser_download_url":"https://github.com/x/\#(n)","size":10}"# }

    @Test func decodesAndSelects() throws {
        let r = try JSONDecoder().decode(GitHubRelease.self, from: json(assets: [asset("Hephaestus-0.2.zip"), asset("Hephaestus-0.2.zip.sig")].joined(separator: ",")))
        #expect(r.version == v("0.2"))
        let sel = UpdateAssets.select(r, version: v("0.2"))
        #expect(sel?.zip.name == "Hephaestus-0.2.zip")
        #expect(sel?.signature.name == "Hephaestus-0.2.zip.sig")
    }
    @Test func missingSigOrZipRejected() throws {
        let onlyZip = try JSONDecoder().decode(GitHubRelease.self, from: json(assets: asset("Hephaestus-0.2.zip")))
        #expect(UpdateAssets.select(onlyZip, version: v("0.2")) == nil)
        let onlySig = try JSONDecoder().decode(GitHubRelease.self, from: json(assets: asset("Hephaestus-0.2.zip.sig")))
        #expect(UpdateAssets.select(onlySig, version: v("0.2")) == nil)
        let wrong = try JSONDecoder().decode(GitHubRelease.self, from: json(assets: [asset("Hephaestus-0.3.zip"), asset("Hephaestus-0.3.zip.sig")].joined(separator: ",")))
        #expect(UpdateAssets.select(wrong, version: v("0.2")) == nil)
    }
    @Test func draftsAndPrereleasesIgnored() throws {
        let a = [asset("Hephaestus-0.2.zip"), asset("Hephaestus-0.2.zip.sig")].joined(separator: ",")
        #expect(UpdateAssets.select(try JSONDecoder().decode(GitHubRelease.self, from: json(draft: true, assets: a)), version: v("0.2")) == nil)
        #expect(UpdateAssets.select(try JSONDecoder().decode(GitHubRelease.self, from: json(pre: true, assets: a)), version: v("0.2")) == nil)
    }
    @Test func missingOptionalFieldsDecode() throws {
        let r = try JSONDecoder().decode(GitHubRelease.self, from: Data(#"{"tag_name":"v1","html_url":"https://github.com/x"}"#.utf8))
        #expect(r.assets.isEmpty && !r.draft && r.body == nil)
    }
    @Test func notesExcerpt() {
        #expect(ReleaseNotes.excerpt("## Notes\n**Bold** `code`") == "Notes\nBold code")
        #expect(ReleaseNotes.excerpt(String(repeating: "a", count: 700)).count == 601)
        #expect(ReleaseNotes.excerpt(nil) == "")
    }
}

@Suite struct UpdateDecisionTests {
    @Test func decisions() {
        #expect(UpdateDecision.evaluate(current: v("0.1"), latest: v("0.1"), skipped: nil, userInitiated: true) == .upToDate)
        #expect(UpdateDecision.evaluate(current: v("0.2"), latest: v("0.1"), skipped: nil, userInitiated: false) == .upToDate)
        #expect(UpdateDecision.evaluate(current: v("0.1"), latest: v("0.2"), skipped: nil, userInitiated: false) == .available(v("0.2")))
        #expect(UpdateDecision.evaluate(current: v("0.1"), latest: v("0.2"), skipped: "0.2", userInitiated: false) == .skipped(v("0.2")))
        #expect(UpdateDecision.evaluate(current: v("0.1"), latest: v("0.2"), skipped: "v0.2.0", userInitiated: false) == .skipped(v("0.2")))
        #expect(UpdateDecision.evaluate(current: v("0.1"), latest: v("0.2"), skipped: "0.2", userInitiated: true) == .available(v("0.2")))
        #expect(UpdateDecision.evaluate(current: v("0.1"), latest: v("0.3"), skipped: "0.2", userInitiated: false) == .available(v("0.3")))
        #expect(UpdateDecision.evaluate(current: v("0.1"), latest: v("0.2"), skipped: "junk", userInitiated: false) == .available(v("0.2")))
    }
}

@Suite struct UpdateScheduleTests {
    private let now = Date(timeIntervalSince1970: 1_000_000)
    @Test func dueWhenNeverOrOld() {
        #expect(UpdateSchedule.secondsUntilDue(lastCheck: nil, now: now) == 0)
        #expect(UpdateSchedule.secondsUntilDue(lastCheck: now.addingTimeInterval(-86_400), now: now) == 0)
        #expect(UpdateSchedule.secondsUntilDue(lastCheck: now.addingTimeInterval(86_400), now: now) == 0)   // clock went backwards
    }
    @Test func notDueWithin24h() {
        #expect(UpdateSchedule.secondsUntilDue(lastCheck: now.addingTimeInterval(-3_600), now: now) == 82_800)
    }
    @Test func wakeDelayIsClamped() {
        #expect(UpdateSchedule.nextWakeDelay(lastCheck: now.addingTimeInterval(-3_600), now: now) == 3_600)
        #expect(UpdateSchedule.nextWakeDelay(lastCheck: nil, now: now) == 60)
        #expect(UpdateSchedule.nextWakeDelay(lastCheck: now.addingTimeInterval(-86_400 + 100), now: now) == 100)
    }
    @Test func initialDelay() { #expect(UpdateSchedule.initialDelay == 30) }
}

@Suite struct UpdateHostPolicyTests {
    private func ok(_ s: String) -> Bool { UpdateHostPolicy.isAllowed(URL(string: s)!) }
    @Test func allowlist() {
        #expect(ok("https://github.com/gianlucanotaro/hephaestus/releases/download/v0.2/Hephaestus-0.2.zip"))
        #expect(ok("https://objects.githubusercontent.com/x"))
        #expect(ok("https://release-assets.githubusercontent.com/x"))
        #expect(ok("https://api.github.com/x"))
        #expect(ok("https://GitHub.com/x"))
    }
    @Test func rejections() {
        #expect(!ok("http://github.com/x"))
        #expect(!ok("https://evil.example/x"))
        #expect(!ok("https://github.com.evil.example/x"))
        #expect(!ok("https://evilgithub.com/x"))
        #expect(!ok("https://user:pw@github.com/x"))
        #expect(!ok("https://github.com:8443/x"))
        #expect(!ok("file:///etc/passwd"))
        #expect(!ok("https://sub.github.com/x"))
    }
    @Test func redirectGuard() {
        let g = UpdateRedirectGuard()
        func follow(_ s: String) -> Bool {
            var followed = false
            let url = URL(string: "https://github.com/a")!
            let resp = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)!
            g.urlSession(URLSession.shared, task: URLSession.shared.dataTask(with: url), willPerformHTTPRedirection: resp,
                         newRequest: URLRequest(url: URL(string: s)!)) { followed = $0 != nil }
            return followed
        }
        #expect(follow("https://objects.githubusercontent.com/z"))
        #expect(!follow("https://evil.example/z"))
        #expect(!follow("http://objects.githubusercontent.com/z"))
    }
}

@Suite struct UpdateSignatureTests {
    private func pair() -> (priv: Curve25519.Signing.PrivateKey, pub: String) {
        let k = Curve25519.Signing.PrivateKey()
        return (k, k.publicKey.rawRepresentation.base64EncodedString())
    }
    private func sign(_ k: Curve25519.Signing.PrivateKey, _ d: Data) -> String { try! k.signature(for: d).base64EncodedString() + "\n" }

    @Test func roundTrip() {
        let (k, pub) = pair(), data = Data("zip bytes".utf8)
        #expect(UpdateSignature.verify(data: data, signatureBase64: sign(k, data), publicKeyBase64: pub))
    }
    @Test func tamperedFileFails() {
        let (k, pub) = pair()
        let sig = sign(k, Data("zip bytes".utf8))
        #expect(!UpdateSignature.verify(data: Data("zip bytez".utf8), signatureBase64: sig, publicKeyBase64: pub))
    }
    @Test func wrongKeyFails() {
        let (k, _) = pair(), other = pair().pub, data = Data("x".utf8)
        #expect(!UpdateSignature.verify(data: data, signatureBase64: sign(k, data), publicKeyBase64: other))
    }
    @Test func emptyOrMalformedKeyDisables() {
        let (k, _) = pair(), data = Data("x".utf8), sig = sign(k, data)
        #expect(!UpdateSignature.verify(data: data, signatureBase64: sig, publicKeyBase64: ""))
        #expect(!UpdateSignature.verify(data: data, signatureBase64: sig, publicKeyBase64: "AAAA"))
        #expect(UpdateKey.publicKey(from: "") == nil)
    }
    @Test func malformedSignatureFails() {
        let (_, pub) = pair()
        #expect(!UpdateSignature.verify(data: Data(), signatureBase64: "", publicKeyBase64: pub))
        #expect(!UpdateSignature.verify(data: Data(), signatureBase64: "not base64!!", publicKeyBase64: pub))
        #expect(!UpdateSignature.verify(data: Data(), signatureBase64: "AAAA", publicKeyBase64: pub))
    }
    @Test func shippedKeyIsEmptyOrValid() {
        let k = UpdateKey.publicKeyBase64
        if !k.isEmpty { #expect(Data(base64Encoded: k)?.count == 32) }
        #expect(UpdateKey.isConfigured == !k.isEmpty)
    }
}

@Suite struct UpdateSignToolInteropTests {
    /// Produced by `hephaestus-sign sign` with a throwaway key; pins that the app verifies the tool's output format.
    @Test func appVerifiesToolSignature() {
        let pub = "330MuaveMIhY03ZJVSgILXRs6prm8Tz26ncuaTvjHJg="
        let sig = "S82CNuNP4rFaM/+9HHmk+1brnUyBwQJ1iHvQmSaQg+LOLmrPyS/20HipTTbKESKn8QsmHjP2TGy/H9K09oGHAA==\n"
        #expect(UpdateSignature.verify(data: Data("interop\n".utf8), signatureBase64: sig, publicKeyBase64: pub))
        #expect(!UpdateSignature.verify(data: Data("interop".utf8), signatureBase64: sig, publicKeyBase64: pub))
    }
}

@Suite struct UpdateBundleCheckTests {
    private let id = "dev.rsdf.hephaestus"
    private func info(id: String? = "dev.rsdf.hephaestus", ver: String? = "0.2") -> [String: Any] {
        var d: [String: Any] = [:]
        if let id { d["CFBundleIdentifier"] = id }
        if let ver { d["CFBundleShortVersionString"] = ver }
        return d
    }
    @Test func topLevel() {
        #expect(UpdateBundleCheck.validateTopLevel(["Hephaestus.app"]) == nil)
        #expect(UpdateBundleCheck.validateTopLevel([]) != nil)
        #expect(UpdateBundleCheck.validateTopLevel(["Hephaestus.app", "__MACOSX"]) != nil)
        #expect(UpdateBundleCheck.validateTopLevel(["Other.app"]) != nil)
    }
    @Test func infoChecks() {
        func check(_ i: [String: Any], expected: String = "0.2", current: String = "0.1", bundle: String? = "dev.rsdf.hephaestus") -> UpdateError? {
            UpdateBundleCheck.validateInfo(i, expectedBundleID: bundle, expectedVersion: v(expected), current: v(current))
        }
        #expect(check(info()) == nil)
        #expect(check(info(id: "evil.app")) != nil)
        #expect(check(info(id: nil)) != nil)
        #expect(check(info(), bundle: nil) != nil)
        #expect(check(info(ver: "0.3")) != nil)
        #expect(check(info(ver: nil)) != nil)
        #expect(check(info(), current: "0.2") != nil)     // not newer
        #expect(check(info(ver: "0.2"), expected: "0.2", current: "0.5") != nil)
    }
    @Test func adHocSkipsRequirement() {
        #expect(UpdateBundleCheck.requiresDesignatedRequirement(runningIsAdHoc: true) == false)
        #expect(UpdateBundleCheck.requiresDesignatedRequirement(runningIsAdHoc: false))
    }
}

@Suite struct UpdateInstallPlanTests {
    private let app = URL(fileURLWithPath: "/Applications/Hephaestus.app")
    @Test func writableSwaps() {
        #expect(InstallPlan.make(bundleURL: app) { _ in true } == .swap(destination: app))
    }
    @Test func notWritableOpensReleasePage() {
        guard case .openReleasePage = InstallPlan.make(bundleURL: app, isWritable: { _ in false }) else { Issue.record("expected release page"); return }
        guard case .openReleasePage = InstallPlan.make(bundleURL: app, isWritable: { $0 == app }) else { Issue.record("parent not writable"); return }
        guard case .openReleasePage = InstallPlan.make(bundleURL: app, isWritable: { $0 != app }) else { Issue.record("bundle not writable"); return }
    }
    @Test func nonBundleRefused() {
        guard case .refuse = InstallPlan.make(bundleURL: URL(fileURLWithPath: "/tmp/.build/debug"), isWritable: { _ in true }) else { Issue.record("expected refusal"); return }
    }
}

@Suite struct UpdateScriptTests {
    @Test func argumentOrderAndNoInterpolation() {
        let work = URL(fileURLWithPath: "/tmp/w x'; rm -rf ~; '")
        let args = UpdateInstallScript.arguments(script: work.appendingPathComponent("swap.sh"), pid: 123,
                                                 newApp: work.appendingPathComponent("new/Hephaestus.app"),
                                                 destination: URL(fileURLWithPath: "/Applications/Hephaestus.app"),
                                                 backup: work.appendingPathComponent("b.app"), workDir: work)
        #expect(args.count == 6)
        #expect(args[1] == "123")
        #expect(args[2].hasSuffix("new/Hephaestus.app"))
        #expect(args[3] == "/Applications/Hephaestus.app")
        #expect(args[5] == work.path)
        // The script is a constant that only reads its arguments.
        #expect(!UpdateInstallScript.text.contains("/tmp"))
        #expect(!UpdateInstallScript.text.contains("rm -rf ~"))
        #expect(UpdateInstallScript.text.contains(#"PID="$1"; NEW="$2"; DEST="$3"; BACKUP="$4"; WORK="$5""#))
        #expect(UpdateInstallScript.text.hasPrefix("#!/bin/sh"))
    }
    @Test func everyUseIsQuoted() {
        for name in ["DEST", "NEW", "BACKUP", "WORK", "PID"] {
            for line in UpdateInstallScript.text.split(separator: "\n") where line.contains("$\(name)") {
                #expect(line.contains("\"$\(name)\""), "\(line)")
            }
        }
    }
    @Test func scriptSyntaxIsValid() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("hephaestus-script-\(UUID().uuidString).sh")
        try UpdateInstallScript.text.write(to: f, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: f) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-n", f.path]
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
    }
}

/// Stubs URLSession traffic; no network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (code, data) = Self.handler?(request) ?? (500, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) struct UpdateCheckerTests {
    private func checker() -> UpdateChecker {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [StubURLProtocol.self]
        return UpdateChecker(session: URLSession(configuration: c))
    }
    @Test func requestShape() {
        let r = UpdateChecker.request(version: "0.1")
        #expect(r.url?.absoluteString == "https://api.github.com/repos/gianlucanotaro/hephaestus/releases/latest")
        #expect(r.value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(r.value(forHTTPHeaderField: "User-Agent") == "Hephaestus/0.1")
        #expect(r.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(r.timeoutInterval == 15)
    }
    @Test func okDecodes() async throws {
        StubURLProtocol.handler = { _ in (200, Data(#"{"tag_name":"v0.2","html_url":"https://github.com/x","assets":[]}"#.utf8)) }
        let r = try await checker().fetchLatest()
        #expect(r.tagName == "v0.2")
    }
    @Test func errorStatusesAreUnreachable() async {
        for code in [404, 403, 429, 500] {
            StubURLProtocol.handler = { _ in (code, Data()) }
            await #expect(throws: UpdateError.unreachable) { try await checker().fetchLatest() }
        }
    }
    @Test func garbageIsBadResponse() async {
        StubURLProtocol.handler = { _ in (200, Data("nope".utf8)) }
        await #expect(throws: UpdateError.badResponse) { try await checker().fetchLatest() }
    }
}

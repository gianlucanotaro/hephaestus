import Foundation
import HephaestusIPC

/// Fetches the latest release from GitHub. No token, no cookies; the URLSession is injectable for tests.
struct UpdateChecker {
    static let latestURL = URL(string: "https://api.github.com/repos/gianlucanotaro/hephaestus/releases/latest")!
    var session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? URLSession(configuration: Self.configuration(), delegate: UpdateRedirectGuard(), delegateQueue: nil)
    }

    static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        c.httpCookieStorage = nil
        c.urlCache = nil
        return c
    }

    static func request(version: String = HephaestusVersion.current) -> URLRequest {
        var r = URLRequest(url: latestURL, timeoutInterval: 15)
        r.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        r.setValue("Hephaestus/\(version)", forHTTPHeaderField: "User-Agent")
        return r
    }

    /// 404 (no release / private repo), 403/429 (rate limit) and transport errors all surface as `.unreachable`.
    func fetchLatest() async throws -> GitHubRelease {
        let data: Data, response: URLResponse
        do { (data, response) = try await session.data(for: Self.request()) } catch { throw UpdateError.unreachable }
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        guard http.statusCode == 200 else { throw UpdateError.unreachable }
        guard data.count < 2_000_000, let release = try? JSONDecoder().decode(GitHubRelease.self, from: data) else {
            throw UpdateError.badResponse
        }
        return release
    }
}

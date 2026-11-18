import AppKit
import HephaestusIPC

/// Unix-domain socket server for `hephaestus-cli` (issue #17). Public APIs only.
///
/// Security: the support directory is 0700 and the socket 0600; every connection's peer uid is checked with
/// `getpeereid`; requests are capped at `IPC.maxMessageBytes`; the payload is only ever decoded as a `Request`
/// (a closed set of commands), never executed or used as a path/command.
final class CLIServer {
    private let path: String
    private let handler: (Request) -> Response
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "hephaestus.cli.connections", attributes: .concurrent)

    /// `handler` runs on the main thread.
    init(path: String = IPC.socketPath, handler: @escaping (Request) -> Response) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    @discardableResult
    func start() -> Bool {
        guard listenFD < 0, var addr = makeSockAddr(path) else { return false }
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        unlink(path)  // stale socket from a previous run
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        let oldMask = umask(0o177)  // socket is created owner-only from the start
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(oldMask)
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { close(fd); unlink(path); return false }
        listenFD = fd
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "hephaestus.cli.accept"
        thread.start()
        return true
    }

    func stop() {
        guard listenFD >= 0 else { return }
        let fd = listenFD
        listenFD = -1
        shutdown(fd, SHUT_RDWR)
        close(fd)
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return  // listener closed
            }
            queue.async { [weak self] in
                self?.serve(client)
                close(client)
            }
        }
    }

    private func serve(_ fd: Int32) {
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == geteuid() else { return }  // different user: drop silently

        let response: Response
        if let line = readLine(fd: fd), !line.isEmpty, let request = try? Codec.decode(Request.self, from: line) {
            let handler = handler
            response = DispatchQueue.main.sync { handler(request) }
        } else {
            response = .failure("Malformed or oversized request.")
        }
        if let data = try? Codec.encode(response) { _ = writeAll(fd: fd, data) }
    }
}

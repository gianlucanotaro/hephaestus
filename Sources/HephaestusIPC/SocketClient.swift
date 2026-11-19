import Foundation

public enum ClientError: Error, Equatable, CustomStringConvertible {
    case notRunning
    case io(String)
    public var description: String {
        switch self {
        case .notRunning: return "Hephaestus is not running. Start it with: open -a Hephaestus"
        case .io(let m): return "Communication with Hephaestus failed: \(m)"
        }
    }
}

/// Builds a `sockaddr_un` for `path`; nil when the path does not fit.
public func makeSockAddr(_ path: String) -> sockaddr_un? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count <= IPC.maxSocketPathBytes else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        for (i, b) in bytes.enumerated() { buf[i] = b }
        buf[bytes.count] = 0
    }
    return addr
}

/// Reads until a newline or EOF, capped at the protocol limit. Returns nil on error or oversize.
public func readLine(fd: Int32) -> Data? {
    var data = Data()
    var buf = [UInt8](repeating: 0, count: 4096)
    while data.count <= IPC.maxMessageBytes {
        let n = read(fd, &buf, buf.count)
        if n < 0 { if errno == EINTR { continue }; return nil }
        if n == 0 { return data }
        if let nl = buf[0..<n].firstIndex(of: 0x0A) { data.append(contentsOf: buf[0..<nl]); return data }
        data.append(contentsOf: buf[0..<n])
    }
    return nil
}

public func writeAll(fd: Int32, _ data: Data) -> Bool {
    let bytes = [UInt8](data)
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        if n < 0 { if errno == EINTR { continue }; return false }
        offset += n
    }
    return true
}

public enum SocketClient {
    /// Sends one request and waits for the response. `timeout` bounds each read/write.
    public static func send(_ request: Request, socketPath: String = IPC.socketPath, timeout: TimeInterval = 10) throws -> Response {
        guard var addr = makeSockAddr(socketPath) else { throw ClientError.io("socket path too long") }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ClientError.io(String(cString: strerror(errno))) }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var nosigpipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        if rc != 0 {
            if errno == ENOENT || errno == ECONNREFUSED { throw ClientError.notRunning }
            throw ClientError.io(String(cString: strerror(errno)))
        }
        guard writeAll(fd: fd, try Codec.encode(request)) else { throw ClientError.io("write failed") }
        guard let line = readLine(fd: fd), !line.isEmpty else { throw ClientError.io("no response") }
        do { return try Codec.decode(Response.self, from: line) } catch { throw ClientError.io("invalid response") }
    }
}

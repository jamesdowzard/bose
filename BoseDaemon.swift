/// bosed: Background daemon — TCP relay to phone's BoseService over Tailscale
/// Keeps a Unix socket server (/tmp/bosed.sock) for local clients (bose-ctl, Hammerspoon),
/// and forwards commands to the phone's BoseService over Tailscale TCP.
///
/// Architecture:
///   bose-ctl / Hammerspoon
///       -> JSON over Unix socket (/tmp/bosed.sock)
///   bosed (this daemon)
///       -> JSON over TCP (Tailscale)
///   Phone BoseService
///       -> RFCOMM
///   Bose QC Ultra headphones

import Foundation

// === Configuration ===
let PHONE_HOST = "100.97.121.67"   // Tailscale IP of phone
let PHONE_PORT: UInt16 = 8899
let SOCKET_PATH = "/tmp/bosed.sock"
let LOG_PATH = NSHomeDirectory() + "/Library/Logs/bosed.log"

// === Logging ===
class Logger {
    static let shared = Logger()
    private let handle: FileHandle?
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        FileManager.default.createFile(atPath: LOG_PATH, contents: nil)
        handle = FileHandle(forWritingAtPath: LOG_PATH)
        handle?.seekToEndOfFile()
    }

    func log(_ msg: String) {
        let ts = formatter.string(from: Date())
        let line = "[\(ts)] \(msg)\n"
        handle?.write(line.data(using: .utf8) ?? Data())
        // Also print to stdout for launchd capture
        print(line, terminator: "")
        fflush(stdout)
    }
}

let log = Logger.shared

// === TCP Client to Phone ===
class PhoneClient {
    let host: String
    let port: UInt16

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    /// Send a JSON request to the phone and return the response string.
    /// Returns nil on any failure (connection refused, timeout, etc.).
    func send(_ request: String, timeout: TimeInterval = 10) -> String? {
        // Create TCP socket
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.log("PhoneClient: socket() failed — errno=\(errno)")
            return nil
        }
        defer { close(fd) }

        // Set send/recv timeouts
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        // Resolve host
        guard let hostEntry = gethostbyname(host) else {
            log.log("PhoneClient: gethostbyname failed for \(host)")
            return nil
        }

        // Build sockaddr_in and connect
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        memcpy(&addr.sin_addr, hostEntry.pointee.h_addr_list[0]!, Int(hostEntry.pointee.h_length))

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connectResult == 0 else {
            log.log("PhoneClient: connect failed — errno=\(errno)")
            return nil
        }

        // Write request (JSON + newline delimiter)
        let payload = request.hasSuffix("\n") ? request : request + "\n"
        guard let requestData = payload.data(using: .utf8) else { return nil }
        let written = requestData.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, requestData.count)
        }
        guard written == requestData.count else {
            log.log("PhoneClient: write failed — wrote \(written)/\(requestData.count)")
            return nil
        }

        // Shutdown write side so server knows request is complete
        shutdown(fd, SHUT_WR)

        // Read response (up to 4KB)
        var buffer = [UInt8](repeating: 0, count: 4096)
        var totalRead = 0

        while totalRead < buffer.count {
            let n = read(fd, &buffer[totalRead], buffer.count - totalRead)
            if n <= 0 { break }
            totalRead += n
        }

        guard totalRead > 0 else {
            log.log("PhoneClient: no response data")
            return nil
        }

        return String(bytes: buffer[0..<totalRead], encoding: .utf8)
    }
}

// === Unix Socket Server ===
class SocketServer {
    let phoneClient: PhoneClient
    private var serverFd: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "bosed.accept")

    init(phoneClient: PhoneClient) {
        self.phoneClient = phoneClient
    }

    func start() {
        // Clean up stale socket
        unlink(SOCKET_PATH)

        serverFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverFd >= 0 else {
            log.log("ERROR: Failed to create socket: errno=\(errno)")
            exit(1)
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            SOCKET_PATH.withCString { cstr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 104) { dest in
                    _ = strcpy(dest, cstr)
                }
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            log.log("ERROR: Failed to bind socket: errno=\(errno)")
            exit(1)
        }

        chmod(SOCKET_PATH, 0o666)

        guard listen(serverFd, 5) == 0 else {
            log.log("ERROR: Failed to listen: errno=\(errno)")
            exit(1)
        }

        log.log("Unix socket listening on \(SOCKET_PATH)")

        // Accept connections on a background queue
        acceptQueue.async { [weak self] in
            while let self = self, self.serverFd >= 0 {
                let clientFd = accept(self.serverFd, nil, nil)
                guard clientFd >= 0 else {
                    if errno == EBADF { break }
                    continue
                }
                // Handle on background thread — no RunLoop dependency now
                DispatchQueue.global(qos: .userInitiated).async {
                    self.handleClient(clientFd)
                }
            }
        }
    }

    func handleClient(_ fd: Int32) {
        defer { close(fd) }

        // Read request (max 4KB)
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(fd, &buffer, buffer.count)
        guard bytesRead > 0 else { return }

        let requestStr = String(bytes: buffer[0..<bytesRead], encoding: .utf8) ?? ""
        let trimmed = requestStr.trimmingCharacters(in: .whitespacesAndNewlines)
        log.log("Request: \(trimmed)")

        let response = processRequest(trimmed)
        log.log("Response: \(response)")
        if let responseData = response.data(using: .utf8) {
            _ = responseData.withUnsafeBytes { ptr in
                write(fd, ptr.baseAddress!, responseData.count)
            }
        }
    }

    func processRequest(_ raw: String) -> String {
        // Validate it's JSON
        guard let data = raw.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "{\"ok\":false,\"error\":\"Invalid JSON request\"}"
        }

        // Forward to phone over TCP
        guard let response = phoneClient.send(raw) else {
            return "{\"ok\":false,\"error\":\"phone unreachable\"}"
        }

        return response.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func stop() {
        if serverFd >= 0 {
            close(serverFd)
            serverFd = -1
        }
        unlink(SOCKET_PATH)
    }
}

// === Main ===
log.log("bosed starting (pid \(ProcessInfo.processInfo.processIdentifier)) — TCP relay mode")
log.log("Forwarding to phone at \(PHONE_HOST):\(PHONE_PORT)")

let phoneClient = PhoneClient(host: PHONE_HOST, port: PHONE_PORT)
let socketServer = SocketServer(phoneClient: phoneClient)

// Signal handlers for clean shutdown
signal(SIGTERM) { _ in
    log.log("Received SIGTERM, shutting down")
    unlink(SOCKET_PATH)
    exit(0)
}
signal(SIGINT) { _ in
    log.log("Received SIGINT, shutting down")
    unlink(SOCKET_PATH)
    exit(0)
}

socketServer.start()

log.log("bosed ready — relay active")

// Run the main run loop forever
RunLoop.current.run()

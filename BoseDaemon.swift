/// bosed: Background daemon — TCP relay to phone's BoseService over Tailscale
/// Phone is the brain; bosed is a passive relay that also manages Mac BT on command.
///
/// Two channels:
///   1. Unix socket (/tmp/bosed.sock) for local clients → one-shot TCP to phone
///   2. Persistent subscribe connection to phone → receives push commands (bt_connect, bt_disconnect)
///
/// bosed does NOT auto-connect Mac BT. Phone tells bosed when to connect/disconnect.

import Foundation

// === Configuration ===
let PHONE_HOST = "100.97.121.67"   // Tailscale IP of phone
let PHONE_PORT: UInt16 = 8899
let SOCKET_PATH = "/tmp/bosed.sock"
let LOG_PATH = NSHomeDirectory() + "/Library/Logs/bosed.log"
let BOSE_MAC = "E4:58:BC:C0:2F:72"
let BLUEUTIL = "/opt/homebrew/bin/blueutil"

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
        print(line, terminator: "")
        fflush(stdout)
    }
}

let log = Logger.shared

// === Bluetooth Control ===
func runBlueutil(_ args: [String]) -> Bool {
    let proc = Process()
    proc.launchPath = BLUEUTIL
    proc.arguments = args
    do {
        try proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    } catch {
        log.log("blueutil error: \(error.localizedDescription)")
        return false
    }
}

func btConnect() {
    log.log("BT: connecting Mac to headphones")
    let ok = runBlueutil(["--connect", BOSE_MAC])
    log.log("BT: connect \(ok ? "ok" : "failed")")
}

func btDisconnect() {
    log.log("BT: disconnecting Mac from headphones")
    let ok = runBlueutil(["--disconnect", BOSE_MAC])
    log.log("BT: disconnect \(ok ? "ok" : "failed")")
}

// === TCP Client to Phone (one-shot for commands) ===
class PhoneClient {
    let host: String
    let port: UInt16

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func send(_ request: String, timeout: TimeInterval = 10) -> String? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.log("PhoneClient: socket() failed — errno=\(errno)")
            return nil
        }
        defer { close(fd) }

        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let hostEntry = gethostbyname(host) else {
            log.log("PhoneClient: gethostbyname failed for \(host)")
            return nil
        }

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

        let payload = request.hasSuffix("\n") ? request : request + "\n"
        guard let requestData = payload.data(using: .utf8) else { return nil }
        let written = requestData.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, requestData.count)
        }
        guard written == requestData.count else {
            log.log("PhoneClient: write failed — wrote \(written)/\(requestData.count)")
            return nil
        }

        shutdown(fd, SHUT_WR)

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

// === Subscribe Connection (persistent, receives push commands from phone) ===
class SubscribeClient {
    let host: String
    let port: UInt16
    private let queue = DispatchQueue(label: "bosed.subscribe")

    init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }

    func start() {
        queue.async { [self] in
            while true {
                log.log("Subscribe: connecting to phone...")
                self.connectAndListen()
                log.log("Subscribe: disconnected, reconnecting in 5s...")
                sleep(5)
            }
        }
    }

    private func connectAndListen() {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            log.log("Subscribe: socket() failed — errno=\(errno)")
            return
        }
        defer { close(fd) }

        // Connection timeout
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let hostEntry = gethostbyname(host) else {
            log.log("Subscribe: gethostbyname failed")
            return
        }

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
            log.log("Subscribe: connect failed — errno=\(errno)")
            return
        }

        // Send subscribe registration
        let subscribeMsg = "{\"cmd\":\"subscribe\",\"role\":\"mac\"}\n"
        guard let data = subscribeMsg.data(using: .utf8) else { return }
        let written = data.withUnsafeBytes { ptr in
            Darwin.write(fd, ptr.baseAddress!, data.count)
        }
        guard written == data.count else {
            log.log("Subscribe: write failed")
            return
        }

        // Don't shutdown write side — need to keep connection open

        // Read the subscribe ACK response first
        var buf = [UInt8](repeating: 0, count: 4096)

        // Set read timeout for initial ACK
        var ackTv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &ackTv, socklen_t(MemoryLayout<timeval>.size))

        let ackN = read(fd, &buf, buf.count)
        if ackN > 0 {
            let ackStr = String(bytes: buf[0..<ackN], encoding: .utf8) ?? ""
            log.log("Subscribe: registered — \(ackStr.trimmingCharacters(in: .whitespacesAndNewlines))")
        } else {
            log.log("Subscribe: no ACK received")
            return
        }

        // Set read timeout to detect missing heartbeats (phone sends every 30s)
        var listenTv = timeval(tv_sec: 60, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &listenTv, socklen_t(MemoryLayout<timeval>.size))

        log.log("Subscribe: listening for push commands...")

        // Read push commands in a loop (newline-delimited JSON)
        var lineBuf = Data()
        var readBuf = [UInt8](repeating: 0, count: 1024)

        while true {
            let n = read(fd, &readBuf, readBuf.count)
            if n <= 0 {
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    log.log("Subscribe: no heartbeat for 60s — connection stale, reconnecting")
                } else {
                    log.log("Subscribe: connection closed (read=\(n))")
                }
                return
            }

            lineBuf.append(contentsOf: readBuf[0..<n])

            // Process complete lines
            while let newlineIdx = lineBuf.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = lineBuf[lineBuf.startIndex..<newlineIdx]
                lineBuf = Data(lineBuf[(newlineIdx + 1)...])

                guard let lineStr = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !lineStr.isEmpty else { continue }

                handlePushCommand(lineStr)
            }
        }
    }

    private func handlePushCommand(_ json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            log.log("Push: invalid format — \(json)")
            return
        }

        // Heartbeat — silently acknowledge
        if obj["heartbeat"] != nil { return }

        guard let push = obj["push"] as? String else {
            log.log("Push: no 'push' key — \(json)")
            return
        }

        log.log("Push received: \(push)")

        switch push {
        case "bt_connect":
            DispatchQueue.global(qos: .userInitiated).async {
                btConnect()
            }
        case "bt_disconnect":
            DispatchQueue.global(qos: .userInitiated).async {
                btDisconnect()
            }
        default:
            log.log("Push: unknown command '\(push)'")
        }
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

        acceptQueue.async { [weak self] in
            while let self = self, self.serverFd >= 0 {
                let clientFd = accept(self.serverFd, nil, nil)
                guard clientFd >= 0 else {
                    if errno == EBADF { break }
                    continue
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    self.handleClient(clientFd)
                }
            }
        }
    }

    func handleClient(_ fd: Int32) {
        defer { close(fd) }

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
        guard let data = raw.data(using: .utf8),
              let _ = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return "{\"ok\":false,\"error\":\"Invalid JSON request\"}"
        }

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
log.log("bosed starting (pid \(ProcessInfo.processInfo.processIdentifier)) — smart relay mode")
log.log("Forwarding to phone at \(PHONE_HOST):\(PHONE_PORT)")
log.log("Mac BT managed by phone — no auto-connect")

let phoneClient = PhoneClient(host: PHONE_HOST, port: PHONE_PORT)
let socketServer = SocketServer(phoneClient: phoneClient)
let subscribeClient = SubscribeClient(host: PHONE_HOST, port: PHONE_PORT)

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
subscribeClient.start()

log.log("bosed ready — relay active, subscribe channel starting")

RunLoop.current.run()

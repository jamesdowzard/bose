/// bosed: Background daemon for Bose QC Ultra RFCOMM communication
/// Holds an RFCOMM channel open so bose-ctl can communicate instantly via Unix socket.
/// Protocol: JSON over Unix socket at /tmp/bosed.sock

import Foundation
import IOBluetooth

// === Configuration ===
let BOSE_MAC = "E4:58:BC:C0:2F:72"
let RFCOMM_CHANNELS: [UInt8] = [2, 14, 22, 25]
let SOCKET_PATH = "/tmp/bosed.sock"
let RECONNECT_INTERVAL: TimeInterval = 5
let CHANNEL_OPEN_TIMEOUT: TimeInterval = 3
let MAX_LEAKED_THREADS = 8
let LOG_PATH = NSHomeDirectory() + "/Library/Logs/bosed.log"

let knownDevices: [String: [UInt8]] = [
    "mac":    [0xBC, 0xD0, 0x74, 0x11, 0xDB, 0x27],
    "phone":  [0xA8, 0x76, 0x50, 0xD3, 0xB1, 0x1B],
    "ipad":   [0xF4, 0x81, 0xC4, 0xB5, 0xFA, 0xAB],
    "iphone": [0xF8, 0x4D, 0x89, 0xC4, 0xB6, 0xED],
    "tv":     [0x14, 0xC1, 0x4E, 0xB7, 0xCB, 0x68],
]

func nameFor(_ mac: [UInt8]) -> String {
    for (name, addr) in knownDevices where addr == mac { return name }
    return mac.map { String(format: "%02X", $0) }.joined(separator: ":")
}

func macStr(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
}

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

// === RFCOMM Connection Manager ===
class RFCOMMManager: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var channel: IOBluetoothRFCOMMChannel?
    var hasCycledBT = false
    var isConnected = false
    private var responseData: [Data] = []
    private var responseSemaphore = DispatchSemaphore(value: 0)
    private var reconnectTimer: DispatchSourceTimer?
    private let lock = NSLock()
    private var blockedThreads = 0
    private let threadLock = NSLock()

    override init() {
        super.init()
        registerForNotifications()
    }

    // MARK: - Bluetooth Notifications
    func registerForNotifications() {
        IOBluetoothDevice.register(forConnectNotifications: self,
                                    selector: #selector(deviceConnected(_:device:)))
        log.log("Registered for Bluetooth connection notifications")
    }

    @objc func deviceConnected(_ notification: IOBluetoothUserNotification!, device: IOBluetoothDevice!) {
        guard let device = device else { return }
        let addr = device.addressString?.uppercased().replacingOccurrences(of: "-", with: ":") ?? ""
        guard addr == BOSE_MAC else { return }
        log.log("Bose QC Ultra connected — attempting RFCOMM channel acquisition")
        // Delay to let the system finish the BT connection handshake
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            self?.connectRFCOMM()
        }
    }

    // MARK: - Channel Open with Timeout
    /// Wraps openRFCOMMChannelSync in a background thread with a semaphore timeout.
    /// If audioaccessoryd is holding channels, the background thread blocks but the caller
    /// returns after CHANNEL_OPEN_TIMEOUT seconds. The leaked thread self-resolves when
    /// BT state changes and is capped at MAX_LEAKED_THREADS.
    private func tryOpenChannel(device: IOBluetoothDevice, channelID: UInt8) -> (IOReturn, IOBluetoothRFCOMMChannel?) {
        threadLock.lock()
        if blockedThreads >= MAX_LEAKED_THREADS {
            let count = blockedThreads
            threadLock.unlock()
            log.log("Channel \(channelID): skipped — \(count) blocked threads at cap")
            return (kIOReturnBusy, nil)
        }
        blockedThreads += 1
        threadLock.unlock()

        let sem = DispatchSemaphore(value: 0)
        var openResult: IOReturn = kIOReturnTimeout
        var openChannel: IOBluetoothRFCOMMChannel? = nil
        var callerTimedOut = false

        DispatchQueue.global(qos: .userInitiated).async { [self] in
            var ch: IOBluetoothRFCOMMChannel? = nil
            let r = device.openRFCOMMChannelSync(&ch, withChannelID: channelID, delegate: self)

            threadLock.lock()
            blockedThreads -= 1
            let wasTimedOut = callerTimedOut
            threadLock.unlock()

            if wasTimedOut {
                // Caller already moved on — close any channel we accidentally opened
                log.log("Channel \(channelID): leaked thread returned (result=\(r))")
                ch?.close()
            } else {
                openResult = r
                openChannel = ch
            }
            sem.signal()
        }

        if sem.wait(timeout: .now() + CHANNEL_OPEN_TIMEOUT) == .timedOut {
            threadLock.lock()
            callerTimedOut = true
            let count = blockedThreads
            threadLock.unlock()
            log.log("Channel \(channelID): timed out — blocked by audioaccessoryd (blocked=\(count))")
            return (kIOReturnTimeout, nil)
        }

        return (openResult, openChannel)
    }

    // MARK: - Bluetooth Power Cycle
    /// Cycles BT power off/on and reconnects, using asyncAfter to keep the main RunLoop responsive.
    private func powerCycleBluetooth(completion: @escaping () -> Void) {
        log.log("All channels locked — power cycling Bluetooth")

        runBlueutil(["--power", "0"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in
            runBlueutil(["--power", "1"])
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in
                runBlueutil(["--connect", BOSE_MAC])
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                    completion()
                }
            }
        }
    }

    private func runBlueutil(_ args: [String]) {
        let p = Process()
        p.launchPath = "/opt/homebrew/bin/blueutil"
        p.arguments = args
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - RFCOMM Connection
    func connectRFCOMM() {
        guard !isConnected else {
            log.log("Already connected, skipping")
            return
        }

        guard let device = IOBluetoothDevice(addressString: BOSE_MAC) else {
            log.log("ERROR: Bose device not found")
            scheduleReconnect()
            return
        }

        guard device.isConnected() else {
            scheduleReconnect()
            return
        }

        var anyTimedOut = false

        for chId in RFCOMM_CHANNELS {
            let (result, chRef) = tryOpenChannel(device: device, channelID: chId)

            if result == kIOReturnTimeout {
                anyTimedOut = true
                continue
            }

            if result == kIOReturnBusy {
                continue
            }

            if result == 0, let ch = chRef, ch.isOpen() {
                channel = ch
                _ = responseSemaphore.wait(timeout: .now() + 2)
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))

                if let r = sendCommand([0x00, 0x05, 0x01, 0x00], timeout: 2),
                   r.count >= 4, r[0] == 0x00, r[1] == 0x05 {
                    isConnected = true
                    hasCycledBT = false
                    log.log("Channel \(chId): acquired and verified")
                    cancelReconnect()
                    return
                }
                log.log("Channel \(chId): opened but verification failed")
                ch.close()
                channel = nil
            } else {
                log.log("Channel \(chId): failed (result=\(result))")
                chRef?.close()
            }
        }

        // If channels timed out and we haven't power cycled yet, do it now
        if anyTimedOut && !hasCycledBT {
            hasCycledBT = true
            powerCycleBluetooth { [weak self] in
                self?.connectRFCOMM()
            }
            return
        }

        if hasCycledBT {
            log.log("All RFCOMM channels failed after power cycle, retrying in \(Int(RECONNECT_INTERVAL))s")
        }
        scheduleReconnect()
    }

    // MARK: - Reconnection
    func scheduleReconnect() {
        cancelReconnect()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + RECONNECT_INTERVAL)
        timer.setEventHandler { [weak self] in
            self?.connectRFCOMM()
        }
        timer.resume()
        reconnectTimer = timer
    }

    func cancelReconnect() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
    }

    // MARK: - RFCOMM Delegate
    func rfcommChannelOpenComplete(_ ch: IOBluetoothRFCOMMChannel!, status: IOReturn) {
        if status == 0 {
            log.log("RFCOMM channel open complete (channel \(ch.getID()))")
        } else {
            log.log("RFCOMM channel open failed: \(status)")
        }
        responseSemaphore.signal()
    }

    func rfcommChannelData(_ ch: IOBluetoothRFCOMMChannel!, data ptr: UnsafeMutableRawPointer!, length len: Int) {
        lock.lock()
        responseData.append(Data(bytes: ptr, count: len))
        lock.unlock()
        responseSemaphore.signal()
    }

    func rfcommChannelClosed(_ ch: IOBluetoothRFCOMMChannel!) {
        log.log("RFCOMM channel closed unexpectedly")
        isConnected = false
        channel = nil
        scheduleReconnect()
    }

    // MARK: - Send Commands
    func sendCommand(_ bytes: [UInt8], timeout: TimeInterval = 3) -> Data? {
        guard let ch = channel, isConnected else { return nil }

        lock.lock()
        responseData.removeAll()
        lock.unlock()

        var data = Data(bytes)
        let wr = data.withUnsafeMutableBytes { ptr -> IOReturn in
            ch.writeSync(ptr.baseAddress!, length: UInt16(bytes.count))
        }
        if wr != 0 {
            log.log("Write failed: \(wr)")
            return nil
        }

        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
            lock.lock()
            let hasData = !responseData.isEmpty
            lock.unlock()
            if hasData {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.3))
                break
            }
        }
        lock.lock()
        let result = responseData.first
        lock.unlock()
        return result
    }

    func disconnect() {
        cancelReconnect()
        channel?.close()
        channel = nil
        isConnected = false
    }
}

// === Protocol Helpers ===
func parsePaired(_ data: Data) -> [[UInt8]] {
    guard data.count >= 8, data[2] == 0x03 else { return [] }
    let plen = Int(data[3])
    guard plen >= 7, data.count >= 4 + plen else { return [] }
    var devices: [[UInt8]] = []
    for i in stride(from: 5, to: 4 + plen, by: 6) {
        if i + 6 <= data.count { devices.append(Array(data[i..<i+6])) }
    }
    return devices
}

// === Unix Socket Server ===
class SocketServer {
    let rfcomm: RFCOMMManager
    private var serverFd: Int32 = -1
    private let acceptQueue = DispatchQueue(label: "bosed.accept")

    init(rfcomm: RFCOMMManager) {
        self.rfcomm = rfcomm
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
                // Handle on main thread so RFCOMM RunLoop processing works
                DispatchQueue.main.async {
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
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = json["cmd"] as? String else {
            return jsonEncode(["ok": false, "error": "Invalid JSON request"])
        }

        // Ping works even when RFCOMM is down
        if cmd == "ping" {
            return jsonEncode(["ok": true, "data": ["pong": true, "connected": rfcomm.isConnected]])
        }

        guard rfcomm.isConnected else {
            return jsonEncode(["ok": false, "error": "not connected"])
        }

        switch cmd {
        case "status":
            return handleStatus()
        case "swap":
            guard let device = json["device"] as? String else {
                return jsonEncode(["ok": false, "error": "missing 'device' parameter"])
            }
            return handleSwap(device)
        case "connect":
            guard let device = json["device"] as? String else {
                return jsonEncode(["ok": false, "error": "missing 'device' parameter"])
            }
            return handleConnect(device)
        case "disconnect":
            guard let device = json["device"] as? String else {
                return jsonEncode(["ok": false, "error": "missing 'device' parameter"])
            }
            return handleDisconnect(device)
        case "raw":
            guard let bytesStr = json["bytes"] as? String else {
                return jsonEncode(["ok": false, "error": "missing 'bytes' parameter"])
            }
            return handleRaw(bytesStr)
        default:
            return jsonEncode(["ok": false, "error": "unknown command: \(cmd)"])
        }
    }

    // MARK: - Command Handlers
    func handleStatus() -> String {
        var result: [String: Any] = [:]

        if let r = rfcomm.sendCommand([0x04, 0x09, 0x01, 0x00]), r.count >= 10, r[2] == 0x03 {
            let activeMac = Array(r[4..<10])
            result["active"] = nameFor(activeMac)
            result["active_mac"] = macStr(activeMac)
        }

        if let r = rfcomm.sendCommand([0x05, 0x01, 0x01, 0x00]), r.count >= 7 {
            result["slots"] = Int(r[6])
        }

        if let r = rfcomm.sendCommand([0x04, 0x04, 0x01, 0x00]) {
            let devs = parsePaired(r)
            result["paired"] = devs.map { nameFor($0) }
            result["paired_macs"] = devs.map { macStr($0) }
        }

        if let r = rfcomm.sendCommand([0x00, 0x05, 0x01, 0x00]), r.count >= 5, r[2] == 0x03 {
            result["firmware"] = String(data: r[4..<4+Int(r[3])], encoding: .utf8) ?? "?"
        }

        return jsonEncode(["ok": true, "data": result])
    }

    func handleConnect(_ name: String) -> String {
        guard let mac = knownDevices[name.lowercased()] else {
            return jsonEncode(["ok": false, "error": "Unknown device '\(name)'. Known: \(knownDevices.keys.sorted().joined(separator: ", "))"])
        }
        if let r = rfcomm.sendCommand([0x04, 0x02, 0x05, 0x06] + mac, timeout: 10) {
            if r.count >= 4, r[2] == 0x07 {
                return jsonEncode(["ok": true, "data": ["connected": name]])
            } else if r.count > 4, r[2] == 0x04, r[4] == 0x0b {
                return jsonEncode(["ok": false, "error": "\(name) not paired"])
            } else if r.count >= 4, r[2] == 0x04 {
                return jsonEncode(["ok": false, "error": "connect error 0x\(String(format: "%02x", r.count > 4 ? r[4] : 0))"])
            }
        }
        return jsonEncode(["ok": false, "error": "no response"])
    }

    func handleDisconnect(_ name: String) -> String {
        guard let mac = knownDevices[name.lowercased()] else {
            return jsonEncode(["ok": false, "error": "Unknown device '\(name)'. Known: \(knownDevices.keys.sorted().joined(separator: ", "))"])
        }
        if name.lowercased() == "mac" {
            return jsonEncode(["ok": false, "error": "Cannot disconnect Mac — would close RFCOMM channel. Use: blueutil --disconnect \(BOSE_MAC)"])
        }
        if let r = rfcomm.sendCommand([0x04, 0x03, 0x05, 0x06] + mac, timeout: 5) {
            if r.count >= 4, r[2] == 0x07 {
                return jsonEncode(["ok": true, "data": ["disconnected": name]])
            }
        }
        return jsonEncode(["ok": true, "data": ["disconnected": name, "note": "device may not have been connected"]])
    }

    func handleSwap(_ name: String) -> String {
        guard let targetMac = knownDevices[name.lowercased()] else {
            return jsonEncode(["ok": false, "error": "Unknown device '\(name)'. Known: \(knownDevices.keys.sorted().joined(separator: ", "))"])
        }
        let macMac = knownDevices["mac"]!

        guard let r = rfcomm.sendCommand([0x04, 0x04, 0x01, 0x00]) else {
            return jsonEncode(["ok": false, "error": "Could not query devices"])
        }
        let paired = parsePaired(r)

        // Disconnect non-Mac, non-target devices
        for mac in paired where mac != macMac && mac != targetMac {
            log.log("Swap: disconnecting \(nameFor(mac))")
            _ = rfcomm.sendCommand([0x04, 0x03, 0x05, 0x06] + mac, timeout: 5)
            Thread.sleep(forTimeInterval: 1)
        }

        // Connect target
        if let r2 = rfcomm.sendCommand([0x04, 0x02, 0x05, 0x06] + targetMac, timeout: 10) {
            if r2.count >= 4, r2[2] == 0x07 {
                return jsonEncode(["ok": true, "data": ["swapped": name]])
            } else if r2.count > 4, r2[2] == 0x04, r2[4] == 0x0b {
                return jsonEncode(["ok": false, "error": "\(name) not paired"])
            } else if r2.count >= 4, r2[2] == 0x04 {
                return jsonEncode(["ok": false, "error": "swap error 0x\(String(format: "%02x", r2.count > 4 ? r2[4] : 0))"])
            }
        }
        return jsonEncode(["ok": false, "error": "no response from swap"])
    }

    func handleRaw(_ bytesStr: String) -> String {
        let hexBytes = bytesStr.split(separator: ",").compactMap { UInt8($0.trimmingCharacters(in: .whitespaces), radix: 16) }
        guard !hexBytes.isEmpty else {
            return jsonEncode(["ok": false, "error": "invalid hex bytes"])
        }
        if let r = rfcomm.sendCommand(hexBytes, timeout: 5) {
            let hex = r.map { String(format: "%02x", $0) }.joined(separator: " ")
            return jsonEncode(["ok": true, "data": ["bytes": hex, "length": r.count]])
        }
        return jsonEncode(["ok": false, "error": "no response"])
    }

    // MARK: - JSON Helper
    func jsonEncode(_ dict: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
              let str = String(data: data, encoding: .utf8) else {
            return "{\"ok\":false,\"error\":\"json encoding failed\"}"
        }
        return str
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
log.log("bosed starting (pid \(ProcessInfo.processInfo.processIdentifier))")

let rfcommManager = RFCOMMManager()
let socketServer = SocketServer(rfcomm: rfcommManager)

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

log.log("bosed ready — waiting for events")

// Schedule initial connection attempt after RunLoop starts (1s delay)
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    rfcommManager.connectRFCOMM()
}

// Run the main run loop forever (required for IOBluetooth callbacks)
RunLoop.current.run()

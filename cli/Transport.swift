/// Transport: IOBluetooth RFCOMM transport for the Bose QC Ultra 2.
///
/// Ported from v1 `BoseRFCOMM.swift` — the same proven mechanics:
///   - per-command channel: open RFCOMM (SDP-resolved channel), drain 300ms, send,
///     read response, close. NEVER hold the channel open.
///   - cold-start warm-up: wait for CoreBluetooth poweredOn + SDP query (avoids the
///     first-open error 913 on a cold process).
///   - a single serial `DispatchQueue` wraps ALL channel access so an always-on app
///     can't race a shared mutable delegate.
///
/// This layer is intentionally dumb about BMAP semantics: it ships `[UInt8]` and
/// returns `[UInt8]?`. Command frames come from the generated `BMAP` builders
/// (BMAP.generated.swift); composite read-modify-write / list-parse logic lives in
/// `Composites.swift`. The headphone MAC comes from `Devices.generated.swift`
/// (`Headphone.dashMac`) — no MAC literal is duplicated here.

import Foundation
import IOBluetooth
import CoreBluetooth

let RFCOMM_CHANNEL: BluetoothRFCOMMChannelID = 2  // SPP (BMAP) — resolved via SDP

/// Run blueutil CLI for A2DP connect/disconnect (IOBluetooth doesn't expose this).
/// Ported from v1. Used only on the explicit "switch to mac" path.
@discardableResult
func runBlueutil(_ args: [String], path: String = "/opt/homebrew/bin/blueutil") -> (Int32, String) {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: path)
    proc.arguments = args
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError = pipe
    do {
        try proc.run()
        proc.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let out = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (proc.terminationStatus, out)
    } catch {
        return (1, "")
    }
}

enum TransportError: Error, CustomStringConvertible {
    case deviceNotFound
    case connectionFailed(IOReturn)

    var description: String {
        switch self {
        case .deviceNotFound: return "Bluetooth device not found: \(Headphone.dashMac)"
        case .connectionFailed(let s): return "RFCOMM connection failed: \(s)"
        }
    }
}

// MARK: - RFCOMM delegate

/// Receives RFCOMM data callbacks. One instance per Transport, only ever touched
/// on the transport's serial queue.
private final class RFCOMMDelegate: NSObject, IOBluetoothRFCOMMChannelDelegate {
    var responseData = Data()
    var gotResponse = false

    func reset() {
        responseData = Data()
        gotResponse = false
    }

    func rfcommChannelData(_ rfcommChannel: IOBluetoothRFCOMMChannel!,
                           data dataPointer: UnsafeMutableRawPointer!, length: Int) {
        responseData.append(Data(bytes: dataPointer, count: length))
        gotResponse = true
    }

    func rfcommChannelClosed(_ rfcommChannel: IOBluetoothRFCOMMChannel!) {}
}

// MARK: - CoreBluetooth ready waiter

/// Waits for the CoreBluetooth central to reach poweredOn — required before
/// IOBluetooth RFCOMM will succeed in a freshly-launched process.
private final class BTReadyWaiter: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private(set) var ready = false

    func waitForReady(timeout: TimeInterval = 5.0) {
        central = CBCentralManager(delegate: self, queue: nil)
        let deadline = Date().addingTimeInterval(timeout)
        while !ready && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { ready = true }
    }
}

// MARK: - SDP query completion waiter

/// Receives the IOBluetooth SDP-query completion callback so warm-up can proceed
/// the instant SDP resolves, instead of always waiting a flat timeout. Only ever
/// touched on the warm-up run loop (the transport's serial queue).
private final class SDPQueryWaiter: NSObject {
    private(set) var done = false
    @objc func sdpQueryComplete(_ device: IOBluetoothDevice!, status: IOReturn) {
        done = true
    }
}

// MARK: - Transport

/// On-demand RFCOMM transport. All public methods hop onto `queue` so callers can
/// invoke from any thread; the channel is opened/drained/closed per command.
/// `@unchecked Sendable`: every mutable touch (the `delegate`, `warmedUp`) happens
/// inside `queue.sync` / a `withRFCOMM` body, so cross-thread sharing is safe even
/// though the compiler can't prove it.
final class Transport: @unchecked Sendable {

    /// Serial queue guarding ALL RFCOMM access. Public so the manager can run its
    /// own multi-command sessions (composites) on the same serialised lane.
    let queue = DispatchQueue(label: "com.jamesdowzard.bose-control.rfcomm")

    private let delegate = RFCOMMDelegate()
    private var warmedUp = false

    /// Cold-start warm-up. Run once, lazily, on the serial queue before the first
    /// channel open. Cheap to call repeatedly (guarded by `warmedUp`).
    private func warmUpIfNeeded() {
        guard !warmedUp else { return }
        BTReadyWaiter().waitForReady()
        if let device = IOBluetoothDevice(addressString: Headphone.dashMac) {
            // Event-driven SDP: proceed the instant the query completes rather than
            // always burning a flat 1.0s. The 1.0s cap preserves the old worst-case
            // (and is the fallback if the callback never fires), so warm-up is never
            // slower than before — just faster when SDP resolves quickly, the common
            // case once an ACL link exists. The query still primes channel-ID
            // resolution to avoid the cold-open error 913.
            let sdp = SDPQueryWaiter()
            device.performSDPQuery(sdp)
            let deadline = Date().addingTimeInterval(1.0)
            while !sdp.done && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.03))
            }
        }
        warmedUp = true
    }

    /// True if the headphones currently have an ACL connection to this Mac.
    /// Cheap, non-RFCOMM — does NOT open a channel (so it never nudges the link).
    func isHeadphoneConnected() -> Bool {
        guard let device = IOBluetoothDevice(addressString: Headphone.dashMac) else { return false }
        return device.isConnected()
    }

    /// Open RFCOMM, drain the firmware's unsolicited initial bytes (300ms), run
    /// `body`, then close. MUST be called on `queue` (see `session`).
    @discardableResult
    private func withRFCOMM<T>(_ body: (IOBluetoothRFCOMMChannel) throws -> T) throws -> T {
        warmUpIfNeeded()
        guard let device = IOBluetoothDevice(addressString: Headphone.dashMac) else {
            throw TransportError.deviceNotFound
        }
        var channel: IOBluetoothRFCOMMChannel?
        let status = device.openRFCOMMChannelSync(&channel, withChannelID: RFCOMM_CHANNEL, delegate: delegate)
        guard status == kIOReturnSuccess, let ch = channel else {
            throw TransportError.connectionFailed(status)
        }
        defer { ch.close() }

        // Bose firmware quirk: drain unsolicited bytes for 300ms after connect.
        delegate.reset()
        Thread.sleep(forTimeInterval: 0.3)
        delegate.reset()

        return try body(ch)
    }

    /// Write BMAP bytes on an open channel and wait for the response frame.
    /// MUST be called inside a `withRFCOMM` body (on `queue`).
    func send(_ channel: IOBluetoothRFCOMMChannel, _ bytes: [UInt8], timeout: TimeInterval = 3.0) -> [UInt8]? {
        delegate.reset()
        var mutableBytes = bytes
        let writeStatus = mutableBytes.withUnsafeMutableBytes { raw -> IOReturn in
            channel.writeSync(raw.baseAddress, length: UInt16(raw.count))
        }
        guard writeStatus == kIOReturnSuccess else { return nil }

        // Poll at 20ms (was 50ms): the read returns on the first data callback, so a
        // finer interval just trims the slop between arrival and return. Across ~20
        // reads in a bulk session that adds up; per read it's a few ms, harmless.
        let deadline = Date().addingTimeInterval(timeout)
        while !delegate.gotResponse && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return delegate.gotResponse ? Array(delegate.responseData) : nil
    }

    /// Run a single-channel session of one or more `send`s, synchronously, on the
    /// serial queue. Returns nil if the channel couldn't be opened.
    func session<T>(_ body: (IOBluetoothRFCOMMChannel, Transport) -> T) -> T? {
        queue.sync {
            do {
                return try withRFCOMM { ch in body(ch, self) }
            } catch {
                return nil
            }
        }
    }

    /// Convenience: open a channel, send one frame, return the raw response.
    func oneShot(_ bytes: [UInt8], timeout: TimeInterval = 3.0) -> [UInt8]? {
        session { ch, t in t.send(ch, bytes, timeout: timeout) } ?? nil
    }
}

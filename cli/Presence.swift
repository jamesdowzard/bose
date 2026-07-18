/// Presence: PASSIVE BLE advert scan for the headphones — RECEIVE-ONLY.
///
/// The QC Ultra 2 advertises over BLE constantly while powered on (verified live
/// 2026-07-18: local name "verBosita", Bose company ID 0x009E, ~4 adverts/sec,
/// mfr payload 9e00002c06dfff8ab42110 — battery MAY be in there; correlate before
/// trusting, see docs/reverse-engineering.md). Scanning is listening only: zero
/// packets are sent to the headphones, no ACL, no RFCOMM, no audio-glitch risk —
/// it does NOT violate the "don't probe from a non-sink" transport rule.
///
/// This powers `bose presence` and the app's staleness-banner enrichment: when the
/// Mac holds no slot (cached-first read), presence distinguishes "headphones are on
/// and nearby" from "off/away" without ever touching them.
///
/// The pure advert-match predicate (`isBoseAdvert`) lives in Parsers.swift so the
/// headless test binary covers it; this file owns only the CoreBluetooth session.

import Foundation
import CoreBluetooth

final class PresenceScanner: NSObject, CBCentralManagerDelegate {
    private var central: CBCentralManager!
    private(set) var found: (rssi: Int, name: String, mfr: [UInt8])? = nil

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        if c.state == .poweredOn {
            c.scanForPeripherals(withServices: nil, options: nil)
        }
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData ad: [String: Any], rssi RSSI: NSNumber) {
        let name = (ad[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        let mfr = (ad[CBAdvertisementDataManufacturerDataKey] as? Data).map { [UInt8]($0) } ?? []
        guard isBoseAdvert(name: name, mfr: mfr) else { return }
        // The headphones interleave advert frames: some carry only the local name,
        // others the manufacturer payload (the correlation-log input). A name-only
        // frame proves presence, so hold it as provisional — but keep listening
        // briefly for a payload-carrying frame rather than stopping on the first hit
        // (stopping early returned mfr:"" and starved the correlation log).
        if !mfr.isEmpty {
            found = (RSSI.intValue, name, mfr)
            c.stopScan()
        } else if found == nil {
            provisional = (RSSI.intValue, name, mfr)
        }
    }

    private var provisional: (rssi: Int, name: String, mfr: [UInt8])? = nil

    /// Scan until an mfr-payload advert is heard, or `timeout` elapses — falling
    /// back to a name-only (provisional) hit for the presence verdict. With the
    /// ~4/sec advert cadence a payload frame lands in well under a second when on.
    func scan(timeout: TimeInterval) -> (rssi: Int, name: String, mfr: [UInt8])? {
        central = CBCentralManager(delegate: self, queue: nil)
        let deadline = Date().addingTimeInterval(timeout)
        while found == nil && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        central.stopScan()
        return found ?? provisional
    }
}

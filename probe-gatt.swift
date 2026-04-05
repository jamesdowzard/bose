/// BLE GATT probe: find which characteristic accepts BMAP EQ SET commands.
/// Connects via CoreBluetooth, subscribes to all writable characteristics,
/// writes BMAP EQ SET bytes to each one, checks for ACK response.

import CoreBluetooth
import Foundation

// BMAP EQ SET: bass=+2, mid=0, treble=0 (a small change to detect)
let EQ_SET_BYTES: [UInt8] = [0x01, 0x07, 0x06, 0x0C,
    0xF6, 0x0A, 0x02, 0x00,  // bass +2
    0xF6, 0x0A, 0x00, 0x01,  // mid 0
    0xF6, 0x0A, 0x00, 0x02]  // treble 0

// Reset: bass=0, mid=0, treble=0
let EQ_RESET_BYTES: [UInt8] = [0x01, 0x07, 0x06, 0x0C,
    0xF6, 0x0A, 0x00, 0x00,
    0xF6, 0x0A, 0x00, 0x01,
    0xF6, 0x0A, 0x00, 0x02]

class GATTProbe: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var writableChars: [CBCharacteristic] = []
    var currentProbeIndex = 0
    var probing = false
    var foundChar: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("Scanning for Bose headphones...")
            central.scanForPeripherals(withServices: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        let name = peripheral.name ?? ""
        if name.lowercased().contains("bose") || name.lowercased().contains("verbosita") {
            print("Found: \(name) (\(peripheral.identifier))")
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected. Discovering services...")
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("FAILED to connect: \(error?.localizedDescription ?? "unknown")")
        exit(1)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else {
            print("No services found")
            exit(1)
        }
        print("Found \(services.count) services")
        for svc in services {
            print("  Service: \(svc.uuid)")
            peripheral.discoverCharacteristics(nil, for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let chars = service.characteristics else { return }
        for ch in chars {
            let props = ch.properties
            var propStr = ""
            if props.contains(.read) { propStr += "R" }
            if props.contains(.write) { propStr += "W" }
            if props.contains(.writeWithoutResponse) { propStr += "w" }
            if props.contains(.notify) { propStr += "N" }
            if props.contains(.indicate) { propStr += "I" }
            print("  Char: \(ch.uuid) [\(propStr)]")

            // Collect writable characteristics
            if props.contains(.write) || props.contains(.writeWithoutResponse) {
                writableChars.append(ch)
                // Subscribe to notifications/indications
                if props.contains(.notify) || props.contains(.indicate) {
                    peripheral.setNotifyValue(true, for: ch)
                }
            }
        }
    }

    // Called after all services/chars discovered — start probing
    func startProbe() {
        guard !writableChars.isEmpty else {
            print("\nNo writable characteristics found!")
            exit(1)
        }
        print("\n=== Starting probe: \(writableChars.count) writable characteristics ===\n")
        probing = true
        probeNext()
    }

    func probeNext() {
        guard currentProbeIndex < writableChars.count else {
            print("\n=== Probe complete ===")
            if let found = foundChar {
                print("SUCCESS: Characteristic \(found.uuid) accepts BMAP EQ SET!")
                print("Service: \(found.service?.uuid ?? CBUUID())")
                // Reset EQ back to 0/0/0
                peripheral?.writeValue(Data(EQ_RESET_BYTES), for: found,
                    type: found.properties.contains(.write) ? .withResponse : .withoutResponse)
                print("EQ reset to 0/0/0")
            } else {
                print("FAILED: No characteristic accepted BMAP EQ SET bytes")
            }
            // Give time for reset to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { exit(0) }
            return
        }

        let ch = writableChars[currentProbeIndex]
        let type: CBCharacteristicWriteType = ch.properties.contains(.write) ? .withResponse : .withoutResponse
        print("[\(currentProbeIndex + 1)/\(writableChars.count)] Writing EQ SET to \(ch.uuid) [\(type == .withResponse ? "withResponse" : "withoutResponse")]...")

        peripheral?.writeValue(Data(EQ_SET_BYTES), for: ch, type: type)

        // Wait 2 seconds for response, then move to next
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self = self, self.foundChar == nil else { return }
            print("  No response from \(ch.uuid)")
            self.currentProbeIndex += 1
            self.probeNext()
        }
    }

    // Write response
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            print("  Write error on \(characteristic.uuid): \(error.localizedDescription)")
            // Move to next immediately on error
            if foundChar == nil {
                currentProbeIndex += 1
                probeNext()
            }
        } else {
            print("  Write ACK from \(characteristic.uuid)")
        }
    }

    // Notification/indication response
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let hex = data.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("  Response from \(characteristic.uuid): \(hex) (\(data.count) bytes)")

        // Check if this is a BMAP response (not error)
        if probing && data.count >= 4 {
            let operator_ = data[2]
            if operator_ == 0x03 || operator_ == 0x07 || operator_ == 0x06 {
                // RESP, ACK, or RESULT — success!
                print("  >>> BMAP ACK/RESP detected! This is the EQ characteristic!")
                foundChar = characteristic
                // Skip remaining probes
                currentProbeIndex = writableChars.count
                probeNext()
                return
            } else if operator_ == 0x04 {
                print("  >>> BMAP ERROR response (same as RFCOMM)")
            }
        }
    }
}

let probe = GATTProbe()

// Wait for service discovery to complete, then start probing
DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
    probe.startProbe()
}

RunLoop.current.run(until: Date().addingTimeInterval(60))
print("Timeout.")

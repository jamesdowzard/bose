// DO NOT EDIT — generated from bmap.toml
// Source of truth: protocol/spec/bmap.toml — regenerate with `make gen`.
// Composite commands (cnc_level, connected_devices) are hand-written.

import Foundation

enum BMAPOperator: UInt8 {
    case get = 0x01
    case setGet = 0x02
    case resp = 0x03
    case error = 0x04
    case start = 0x05
    case set = 0x06
    case ack = 0x07
}

enum AncMode: UInt8 {
    case quiet = 0
    case aware = 1
    case custom1 = 2
    case custom2 = 3
}

enum EqBand: UInt8 {
    case bass = 0
    case mid = 1
    case treble = 2
}

enum MediaAction: UInt8 {
    case play = 1
    case pause = 2
    case next = 3
    case prev = 4
}

enum BMAP {
    static func setAncMode(mode: UInt8) -> [UInt8] {
        return [0x1F, 0x03, 0x05, 0x02, mode, 0x01]
    }

    static func getAncMode() -> [UInt8] {
        return [0x1F, 0x03, 0x01, 0x00]
    }

    static func setDeviceName() -> [UInt8] {
        return [0x01, 0x02, 0x06, 0x00]
    }

    static func setEqBand(value: Int8, band: UInt8) -> [UInt8] {
        return [0x01, 0x07, 0x02, 0x02, UInt8(bitPattern: value), band]
    }

    static func getEqBand() -> [UInt8] {
        return [0x01, 0x07, 0x01, 0x00]
    }

    static func setMultipoint(state: UInt8) -> [UInt8] {
        return [0x01, 0x0A, 0x02, 0x01, state]
    }

    static func getMultipoint() -> [UInt8] {
        return [0x01, 0x0A, 0x01, 0x00]
    }

    static func connectDevice(mac: [UInt8]) -> [UInt8] {
        return [0x04, 0x01, 0x05, 0x07, 0x00] + mac
    }

    static func disconnectDevice(mac: [UInt8]) -> [UInt8] {
        return [0x04, 0x02, 0x05, 0x06] + mac
    }

    static func getDeviceInfo(mac: [UInt8]) -> [UInt8] {
        return [0x04, 0x05, 0x01, 0x06] + mac
    }

    static func mediaControl(action: UInt8) -> [UInt8] {
        return [0x05, 0x03, 0x05, 0x01, action]
    }

    static func getAudioCodec() -> [UInt8] {
        return [0x05, 0x04, 0x01, 0x00]
    }

    static func setVolume(level: UInt8) -> [UInt8] {
        return [0x05, 0x05, 0x02, 0x01, level]
    }

    static func getVolume() -> [UInt8] {
        return [0x05, 0x05, 0x01, 0x00]
    }

    static func getFirmware() -> [UInt8] {
        return [0x00, 0x05, 0x01, 0x00]
    }

    static func getBattery() -> [UInt8] {
        return [0x02, 0x02, 0x01, 0x00]
    }
}

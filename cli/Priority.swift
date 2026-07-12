/// Runtime multipoint priority order — a user-chosen ordering of device NAMES that
/// overrides the compiled `devices.toml` priorities for eviction victim selection, and
/// names the intended multipoint PAIR (index 0 = primary/active, index 1 = secondary/held).
///
/// Written by the Mac app's drag-to-reorder (via `bose priority --set …`) and by the
/// `bose priority` verb; read by `evictLowestPriorityIfFull`. Foundation-only, so the
/// pure ranking logic unit-tests without hardware. Storage mirrors the profiles/state
/// dir: `$BOSE_STATE_DIR` override (tests) → `~/.config/bose/priority.json`. A missing or
/// unreadable file means "no override" → the compiled devices.toml hierarchy stands.
///
/// The firmware has NO device-priority hierarchy (`ConnectionPriority 0x10` = FuncNotSupp),
/// so this order is enforced entirely host-side by the CLI's `connect`/`swap`/`pair`
/// eviction — never pushed to the headphones.

import Foundation

struct PriorityOrder: Codable, Equatable {
    var order: [String]   // device names, best (primary) first; lowercased

    static func defaultPath() -> String { boseStateDir() + "/priority.json" }

    /// Load, returning an empty order (= no override) for any missing/unreadable/invalid file.
    static func load(_ path: String = defaultPath()) -> PriorityOrder {
        guard let data = FileManager.default.contents(atPath: path),
              let po = try? JSONDecoder().decode(PriorityOrder.self, from: data) else {
            return PriorityOrder(order: [])
        }
        return po
    }

    func save(_ path: String = defaultPath()) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]   // deterministic, like ProfileStore
        var data = try enc.encode(self)
        data.append(0x0A)  // trailing newline
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path))
    }

    static func clear(_ path: String = defaultPath()) {
        try? FileManager.default.removeItem(atPath: path)
    }
}

/// Effective eviction rank for a device: LOWER = keep longer, HIGHER = evict first (same
/// polarity as the compiled `priority`). A device listed in `order` ranks by its index
/// (0 = primary, kept longest). An UNLISTED device sorts after every listed one
/// (`order.count` base) and then keeps the compiled devices.toml hierarchy among the
/// unlisted, so a partial or empty order degrades gracefully to the static priorities.
/// Pure — unit-tested.
func effectiveRank(_ name: String, order: [String], compiledPriority: Int) -> Int {
    if let i = order.firstIndex(where: { $0.lowercased() == name.lowercased() }) {
        return i
    }
    return order.count + compiledPriority
}

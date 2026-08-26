# Bose — device map, connection priority, connectDevice behaviour

<!-- Split out of the root CLAUDE.md on 2026-08-27 (52 KB vs an 8 KB cap). Reference, not
     resident instruction — the root CLAUDE.md Rules point here. -->

Device MACs live in `protocol/spec/devices.toml`, which is the source — but see the
host-side-map warning below: it drifts from the headphones' own pairing table.

## Device Map

MACs live in `devices.toml`, which is the source — see the warning below.

| Name | Widget | Notes |
|------|--------|-------|
| phone | yes | Samsung S21 (local device) |
| mac | yes | MacBook |
| ipad | yes | |
| iphone | yes | |
| tv | macOS only | Google TV Streamer (`kirkwood`, BT name "Living Room TV"). **⚠ Verify it's in the headphones' paired list (04,04) before relying on connect** — an unpaired target only times out until it's paired to verBosita from the streamer's Bluetooth settings |
| appletv | macOS + S21 in-app | Apple TV 4K (`widget=false` → no home-screen widget). **⚠ NOT in the headphones' paired list** (04,04, verified 2026-07-20) |
| quest | yes | Meta Quest 3 |
| audikast | macOS tile only | Avantree Audikast Plus BT transmitter (TV → headphones). Lowest priority (evicted first); deliberately NOT in cycle_order (never cycle audio to a transmitter) |

A device's optional `label` (devices.toml) is the friendly display name shared by the Mac app + S21 in-app tile; absent → fall back to the key.

**`devices.toml` is a host-side map, NOT the headphones' pairing table — they drift.**
The 04,04 ListDevices read on 2026-07-20 (fw 8.2.20) returned exactly 6 MACs — `phone`,
`quest`, `audikast`, `ipad`, `mac`, `iphone` — with **`tv` and `appletv` absent**. Paging an
unpaired device ACKs (op 0x07) and then silently never connects, which used to surface as an
indistinguishable 20s timeout. `preflightPaired` now checks 04,04 BEFORE evicting or paging,
so an unpaired target fails in ~1.5s with the real reason. It's a **preflight, not a post-hoc
diagnosis**, deliberately: after a failed page the headphones stay busy and a fresh RFCOMM
session reliably returns nil (the #132/#134 cold-second-session quirk), so the check has to
run while the radio is quiet. It never blocks a connect when the list can't be read.

**A transmitter (audikast) is the INITIATOR — you generally cannot page it.** Verified
2026-07-20: the Audikast is correctly paired and its MAC is right, the headphones ACK the
04,01 page (`04 01 07 06 001d43b80301`), and it then never appears in 05,01. `bose connect
audikast` / a `pair` with it as primary therefore can't be relied on. The working shape is to
**free a slot and let the transmitter connect itself**. (If it won't self-connect either, its
side of the pairing is gone — re-pair from the transmitter.)

**Connection priority** (`priority` in devices.toml; 1 = highest):
`1 mac → 2 phone → 3 appletv → 4 ipad → 5 quest → 6 tv → 7 iphone → 8 audikast`.
The codegen (`emit_devices.py` `_device_order`) emits `knownDevices` as cycle_order first,
then any non-cycle devices (e.g. `audikast`) — so a source-only device gets a tile + eviction
priority without ever being a cycle target.
The headset holds 2 devices (multipoint) and the firmware only evicts by its own LRU
(`ConnectionPriority 0x10` is FuncNotSupp — see `docs/reverse-engineering.md`). So the
CLI's `connect`/`swap` enforce the hierarchy in software: when both slots are full and
the target isn't already connected, it **disconnects the lowest-priority of the two held
devices first**, then pages the target — and **restores the evicted device if the target
fails to connect** (`evictLowestPriorityIfFull` / `restoreEvicted` in `cli/main.swift`).
Mac app / Hammerspoon inherit this (they shell `bose`). **Runtime override:** a
user-chosen order in `~/.config/bose/priority.json` (`bose priority --set …`, or the Mac
app's **draggable device sidebar** — drag up/down to rank, index 0 = primary, 1 = secondary;
dragging only sets priority, tapping a row connects) takes
precedence over the compiled priorities for victim selection (`effectiveRank`, `cli/Priority.swift`).
`bose pair <primary> <secondary>` connects exactly that pair (evict others → secondary held →
primary active). The order is host-side only — never pushed to the headphones (no firmware
priority hierarchy). **Android now replicates
it too**: pure victim selection in `android/.../Eviction.kt` (`evictionVictim`, JVM-unit-
tested), held-state read via `Composites.getDeviceStates`, wired into `BoseService.switchDevice`
(evict-then-page, restore on failure). The **04,04 paired-list preflight** guards this too
(`Composites.unpairedHint` + `Parsers.parsePairedDevices`, the port of the CLI's `preflightPaired`):
`switchDevice` checks the headset's own pairing table BEFORE evicting, so it never sacrifices a
slot for a mapped-but-unpaired target (tv/appletv) that can only time out — a no-op when the list
is unreadable, so it never blocks a legitimate connect. **The local phone is excluded from victim selection**
(`localDeviceName`, default `"phone"`) — Android differs from the Mac here because the app runs
*on* one of the two slots it arbitrates. `phone` is priority 2 and `mac` is 1, so with the
everyday `{mac, phone}` pair held, plain victim selection chose THIS PHONE for any third target;
BMAP-disconnecting it drops the ACL its own RFCOMM socket rides on, so the switch self-destructed
mid-flight and the restore then no-op'd on a dead socket. Not a host-side-disconnect problem —
do NOT add the Mac's `dropMacHostLink` equivalent here. (Fixed 2026-07-20; `EvictionTest` had
been asserting the buggy `{mac,phone}+ipad → evict phone` behaviour, so the suite was defending
the regression.)

**The Mac is a plain device on the way IN, a special case on the way OUT (2026-07-20).**
#147 stripped ALL Mac special-casing — both the `blueutil --connect` (+1.5s settle) and the
`blueutil --disconnect` — on the theory that the headphones page the Mac and macOS brings up
A2DP on its side. **That is true for connect and false for disconnect**, and the disconnect
half was a regression (#157):

- **Connect: BMAP only.** Dropping `--connect` genuinely fixed the blueutil-timing flakiness
  that made "connect Mac" unreliable. Verified 2026-07-20 (`connect mac` = 3.8s). **Do not
  reintroduce a host-side connect.**
- **Disconnect: BMAP *plus* `blueutil --disconnect`.** A 04,02 only tells the HEADPHONES to
  drop the Mac. macOS still holds them as a connected audio device and re-pages within
  seconds, so the freed slot is reclaimed and anything that needed it (`pair`, `profile tv`,
  eviction) races and loses. Measured on fw 8.2.20:

  | after freeing the slot | result |
  |---|---|
  | `bose disconnect mac` (BMAP only) | Mac back as **ACTIVE sink within 30s** |
  | + `blueutil --disconnect` (the fix) | Mac **stays off** (40-60s observed) |

`isMacDevice` + `runBlueutil` are back, used ONLY on the disconnect/evict paths via
`dropMacHostLink()` (`cmdDisconnect`, `evictLowestPriorityIfFull`, `cmdPair`'s evict loop).
The asymmetry is deliberate — don't "tidy" it into symmetry in either direction.

**Cycle order** (bose): `mac → quest → ipad → iphone → tv → appletv → phone`


## connectDevice Behaviour (verified 2026-04-11 via raw BMAP captures)

**connectDevice pages offline devices.** It doesn't just route audio between
already-connected devices — it tells the Bose to reach out and establish ACL+A2DP
with the target. For sleeping devices (iPad, iPhone) this can take up to ~15s.

**ACK does NOT mean success.** ACK (op=0x07) arrives in ~1s and means "command
received". The actual connection happens in the background. There is no reliable
RESULT frame for paged devices — the only way to confirm success is to poll
`getConnectedDevices` (05,01) until the target MAC appears in the audio-active list.

**No auto-reconnect from either platform.** Both Mac and Android had auto-reconnect
logic that fought user switches (#61-#64). Mac's BoseManager had a 30s reconnect
timer; Android's aclReceiver called ensureA2dp on every ACL reconnect. Both removed.
Reconnection is now user-initiated only. (A Hammerspoon walk-back auto-reconnect —
event-driven, channel-free `blueutil` + a last-active-mac flag — was tried and **removed
2026-07-13 for being too aggressive**; #139. Reconnect the Mac with `bose connect mac`.)

**RFCOMM opens ACL.** Any RFCOMM connection (including state queries) establishes
ACL to the headphones. Bose firmware may interpret this as "device wants audio".
Don't probe/poll from a device that isn't supposed to be the active source.
The cached-first `info --json` (#148) is the structural guard for the READ path:
with no ACL it never opens RFCOMM at all (cache instead); only `--page`, writes,
and explicit verbs touch the radio from a non-slot Mac. Passive BLE scanning
(`bose presence`) is receive-only and always safe — it sends nothing.


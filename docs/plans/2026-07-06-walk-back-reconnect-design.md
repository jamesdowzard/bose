# Walk-Back Auto-Reconnect — Design

**Date:** 2026-07-06
**Feature:** `bose-walk-back-reconnect`
**Status:** approved (brainstorm), pending implementation

## Problem

At work, James walks away from his desk with the headphones on and comes back.
The Mac↔headphone link fully drops while he's out of range, and **macOS never
re-pages it** — nothing reconnects until he manually opens Bose.app (⌘M) or runs
`bose connect mac`. He wants this to happen automatically on return, **with
multipoint left on**.

Observed constraints (confirmed live + with James):

- Mac **stays fully awake** while he's gone → no sleep/wake or screen-unlock
  event to hook a reconnect on.
- **Nothing reconnects at all** on return → no passive baseband
  "device connected" notification fires either; the reconnect must be *actively*
  triggered by something noticing he's back.
- Headphones are a **Qualcomm QCC384** part (`OTG-QCC-384`, "wolverine"), not
  Airoha — control is BMAP-over-RFCOMM, unrelated to the Airoha RACE toolkit.

## The landmine this must not step on (#61 / #62)

The previous Mac auto-reconnect was removed because its 30s timer **probed the
headphones over RFCOMM to check state**, and *any* RFCOMM open re-establishes ACL,
which the Bose firmware interprets as "this device wants audio" — so it yanked
audio back to the Mac even when audio had been deliberately moved to the phone.

`CLAUDE.md` lesson: **never poll/probe the headphones from a device that isn't the
active source.** Any new reconnect logic must not touch the RFCOMM link to *decide*
whether to reconnect — it may only open RFCOMM at the moment it has already decided
to connect.

## Approach (chosen)

**Activity-resumption watcher in Hammerspoon**, reusing the existing resident,
event-driven Hammerspoon layer (`hammerspoon/bose.lua`, wired via `BoseCtl`). No
new resident process, no LaunchAgent, no poller, no BLE binary. Multipoint stays on.

Rejected alternatives:

- **BLE proximity watcher** — truest "in range" signal, but reintroduces an
  always-on resident LaunchAgent (the thing the architecture deliberately avoids)
  and adds RSSI-threshold fiddliness. Not worth it for a few seconds of latency.
- **Manual only** — James already has ⌘M (in-app) and `bose connect mac` (CLI);
  the whole point is to remove the manual step, so this is the fallback, not the
  solution. (Note: the Bose Hammerspoon hotkeys are disabled except Opt+B per #131,
  so there is currently *no global hotkey* for connect-Mac.)

## How it works

**Trigger.** A Hammerspoon watcher tracks user input activity and records the last
input time. When input **resumes after an idle gap of ≥ IDLE_GAP** (default ~150s
— "he left and came back"), it runs the reconnect check. Pure input events — fires
even though the Mac never slept.

**Reconnect check (safety lives here):**

1. **Is the Bose already connected to the Mac?** Use the channel-free
   `IOBluetoothDevice.isConnected` reachability check (already in
   `Transport.swift:150` — "cheap, non-RFCOMM, never nudges the link"). If already
   connected → do nothing.
2. **Was the Mac the last active source before the link dropped?** (the gate — see
   below). If not → do nothing.
3. Otherwise → fire **one** `bose connect mac`.

Because step 1 uses the non-RFCOMM check and RFCOMM is only opened once the code has
*decided* to connect, this structurally cannot reproduce #61/#62 — there is no
state-probe that could make the firmware steal audio.

**Last-active-mac gate.** A flag file at `~/.config/bose/last-active-mac`:

- **Set** it whenever a `bose connect/swap mac` routes audio here (`.active` outcome).
- **Clear** it whenever a connect/switch targets any **non-Mac** device (or an explicit
  Mac disconnect).
- Its **mtime records WHEN** it was last set (the CLI stamps it to now on every write).
- On return, auto-reconnect only if the flag is set **and still fresh** (see TTL below).

**Staleness TTL on the flag (`WALKBACK_FLAG_TTL`, default 8h).** The flag is written
ONLY by the Mac `bose` CLI, so a source switch made on the **phone** side (Android app /
QS tile / headphone button) sends BMAP directly and never clears it — leaving the flag
**stale-set**. Without a guard, a later walk-back would fire `connect mac` and *steal
audio off the phone* — exactly what this feature must never do (#139 finding #1). So the
gate also requires `flagAge < WALKBACK_FLAG_TTL`: once the flag is older than the TTL,
walk-back is suppressed.

**This narrows the hole, it does not fully close it — stated honestly:** the only
channel-free signals are `blueutil --is-connected` + this flag; confirming the *true*
active sink would need an RFCOMM read (forbidden). The TTL closes the **cross-session**
case (switched to the phone yesterday, walk back today ⇒ flag expired ⇒ no theft) but NOT
the **same-session** case (switch to the phone 10 min after a Mac connect, walk away, come
back ⇒ flag still fresh ⇒ it can still steal). The value is a tradeoff: too short suppresses
valid walk-backs after a long continuous Mac session, too long re-opens more of the
phone-switch hole. The flag's mtime is refreshed on every explicit Mac connect **and on
every successful walk-back reconnect** (not while you merely listen), so everyday
walk-away/return keeps resetting the age — the only genuine too-short failure is a >TTL
Mac session where the link never drops, and that fails safe (no auto-reconnect; manual
`connect mac` still works). 8h ≈ a workday — a same-day Mac session stays trusted, an
overnight/stale flag doesn't.

Net effect: if he walked off listening to a podcast on his **phone** (switched via the
Mac), returning won't yank it to the Mac; if the Mac was his source when he left, it comes
back; and a flag left stale by a phone-side switch can't steal audio back indefinitely.
This is the principled version of the #61 fix, with its one residual gap documented.

## Components / touch points

| File | Change |
|------|--------|
| `hammerspoon/bose.lua` | New `walkBackReconnect` watcher (input-idle → resume edge → gated `bose connect mac`). Returns a table with `.start()`/`.stop()`, wired into the existing `BoseCtl` start, consistent with the other event-driven watchers. Tunables: `IDLE_GAP`, debounce/cooldown. |
| `cli/main.swift` | In `cmdConnect`: on a confirmed **mac** connect, write the `last-active-mac` flag; on a confirmed **non-mac** connect (and in `cmdSwap`/eviction paths that change the active source away from Mac), clear it. Reuse the existing config-dir resolution used by profiles. |
| `docs/plans/2026-07-06-walk-back-reconnect-design.md` | This doc. |
| `CLAUDE.md` | Document the watcher + the flag + why it does NOT violate the "no auto-reconnect / no probe" rules (it's edge-triggered on user activity, never probes RFCOMM to decide). |

## Data flow

```
input resumes after ≥ IDLE_GAP idle
        │
        ▼
isConnected(Bose)? ──yes──► do nothing (already connected)
        │ no
        ▼
last-active-mac flag set? ──no──► do nothing (was on phone/other)
        │ yes
        ▼
flag age < WALKBACK_FLAG_TTL? ──no──► do nothing (stale flag — maybe a phone-side switch)
        │ yes
        ▼
bose connect mac  (blueutil --connect + BMAP connectDevice, poll-confirmed)
        │
        ▼
(re)set last-active-mac flag on success  (mtime = now → age resets)
```

## Error handling

- `bose connect mac` already poll-confirms via `getConnectedDevices` (ACK ≠
  success) — reuse as-is; on failure, log and do nothing (next activity-resume
  retries naturally). No retry loop (repo rule: single RFCOMM attempt per command).
- Debounce/cooldown so a burst of input after return fires the connect **once**,
  not repeatedly.
- Missing/unreadable flag file → treat as "not set" (fail safe = do nothing).

## Testing

- **Flag logic (CLI):** unit-style check that `cmdConnect mac` sets the flag and a
  non-mac connect clears it (Foundation-level, no Bluetooth needed — assert on the
  flag file).
- **Watcher logic (Hammerspoon):** factor the decision (`shouldReconnect(isConnected,
  flagSet, idleGap)`) as a pure Lua function tested in isolation; keep the IO
  (isConnected probe, shelling `bose`) at the edges.
- **Manual acceptance:** with multipoint on and Mac as active source, walk out of
  range until the link drops, return, touch the keyboard → Mac audio reconnects
  within a couple of seconds. Repeat having deliberately switched to the phone
  first → Mac does **not** steal audio back.

## Out of scope (YAGNI)

- BLE proximity detection.
- Any behaviour change when the Mac sleeps/locks (it doesn't, in James's setup).
- Auto-reconnect for devices other than the Mac.
- A global connect-Mac hotkey (intentionally disabled, #131).

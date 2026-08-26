# Bose — Android app (`au.com.jd.bose`)

<!-- Split out of the root CLAUDE.md on 2026-08-27: it was 52 KB, ~6x the 8 KB fleet cap.
     This file loads when Claude reads a file in this directory. -->

Compose app + foreground service + widget + QS tile. Shares one generated protocol
layer with the Swift CLI (`protocol/CLAUDE.md`), so the two cannot drift on wire encoding.

## Components
### Android (`android/`) — regenerated protocol on the kept architecture
- `android/` -- Jetpack Compose app (package: `au.com.jd.bose`)
- Protocol wire layer is GENERATED: `app/src/generated/java/au/com/jd/bose/BMAP.generated.kt` (from `bmap.toml`) + `Devices.generated.kt` (device map / headphone MAC from `devices.toml`). Refresh with `cd protocol && make gen` then `cd android && ./gradlew copyGeneratedProtocol` (the committed copies are the build inputs — do-not-edit banner)
- `Transport.kt` -- RFCOMM transport (per-command open/drain-300ms/close, `ReentrantLock`, cold-start). Sends the `IntArray` frames the generated builders produce. **The lock is THREAD-OWNED** (`disconnect()` only unlocks `isHeldByCurrentThread`), so `withConnection` is pinned to a dedicated single-thread dispatcher (`bose-rfcomm`) — on a pool like `Dispatchers.IO` a coroutine that resumed on a different thread would silently fail to release and strand the channel forever. **Never gate channel acquisition on socket state**: `ensureConnected()` used to short-circuit on an `isConnected` accessor, which answers "a socket is open" and NOT "this thread owns it" — so a system-triggered widget refresh could interleave frames onto the app's open session and then close it mid-read. It now always goes through `connect()` and lets the lock arbitrate; the `isConnected` accessor was deleted so the shortcut can't be reintroduced (2026-07-20).
- `Composites.kt` -- live-channel composites (connectDevice poll-confirm, cnc_level RMW, connected_devices list, getAllState) — same escape-hatch split as macOS
- `Parsers.kt` -- pure, hardware-free response parsers (JVM-unit-tested in `app/src/test/`, against the same captured bytes as macOS `Parsers.swift`). `parseMultipointEnabled` is the ONE masked decode (`& 0x01`) shared by `parseAllState` and `BoseProtocol.getMultipoint` — both previously used `!= 0` independently and both misread the 0x06 off-with-slot-bits value (#83, fixed 2026-07-20). `resp()` also requires the response's block/func to match the command it was issued for, so a late frame in the ~18-GET bulk session can't be decoded as the wrong field.
- `BoseProtocol.kt` -- thin command facade: builds non-composite frames via generated `BMAP.*`, decodes responses. NO hand-written frame builders **and no hand-written protocol enums** — `AncMode`/`MediaAction` bind to the generated ones (the shadowing hand-written `AncMode` had no OFF case and mapped 255 → QUIET, so a disabled-ANC headset read as "Quiet" on the phone; deleted 2026-07-20). `ancModeFromInt` returns null on an unknown slot rather than defaulting, and `ancModeLabel` is an exhaustive `when` so adding a mode to `bmap.toml` breaks the build instead of shipping an unlabelled button.
- `A2dpReflection.kt` -- the ONE isolated home for the hidden-API `BluetoothA2dp.connect()` reflection (phone-only insurance; don't expand)
- `SlotGate.kt` -- does THIS phone hold a multipoint slot? Public-API A2DP-proxy connected-list check (zero radio) — the Android sibling of the Mac's `isHeadphoneConnected()`. null = unknown → allow live (never worse than pre-gate).
- `StateCache.kt` -- timestamped last-good snapshot (SharedPrefs) — Android sibling of the Mac state cache (#148). Saved on every successful live refresh (service AND ViewModel); served when the phone holds no slot. `ageText` pure + JVM-tested (`StateCacheTest`).
- `BoseService` -- foreground service (RFCOMM commands; phone-only A2DP nudge; notification media controls play/pause/next/prev). `refreshStatus()` is **cached-first**: no slot → cached broadcast (`EXTRA_REACHABLE`/`EXTRA_AGE_SECONDS`) + widget repaint with a "· Xm" battery-age suffix, NO RFCOMM; `EXTRA_FORCE_LIVE` overrides. The widget's `onUpdate` refresh therefore never pages the headphones.
- `BoseWidgetProvider` -- home screen widget (button set derives from `BoseDeviceMap.widgetDevices` — tv is macOS-only, never a widget button). The battery's "· Xm" staleness suffix is `batteryText()`, formatting via the shared `StateCache.ageText` so widget / in-app banner / Mac all speak one vocabulary. It also persists `snapshot_stale` + `snapshot_at` (stamped as *when the data was true*) and re-ages via `snapshotAge()` in `onUpdate` — a system-triggered repaint reads SharedPrefs with no caller to tell it the provenance, so without that the suffix only appeared on the service-driven paint and a cached snapshot still rendered as a bare `%`.
- `BoseTileService` -- Quick Settings tile (shows active source)
- `DevicePickerActivity` -- dialog launched from QS tile
- `BootReceiver` -- auto-start service on boot
- Companion device registered for background FGS privileges



## Architecture internals

Companion-device registration (required for background FGS starts), the widget's state
colours and click path, and `BoseService`'s device-switch sequence are in
**`docs/android-internals.md`**.

### Key Lessons (Don't Repeat These Mistakes)

**HFP blocks A2DP:** Never proactively connect HFP (BluetoothHeadset profile).
SCO occupies the BT bandwidth and A2DP streaming fails with `sco_occupied:true`.
HFP connects automatically when a phone call arrives — let Android handle it.

**Media nudge is required:** After BT output changes, existing media playback
keeps streaming to the old sink. Must pause/play to force re-routing. Only
triggers if `AudioManager.isMusicActive` is true.

**Widget → BroadcastReceiver → startForegroundService crashes on Android 12+:**
`ForegroundServiceStartNotAllowedException`. Widget clicks must go directly to
the service via `PendingIntent.getForegroundService()`, not through a broadcast
receiver that tries to start the service.

**Companion device association API differs by Android version:**
- API 33+: `cdm.associate(request, executor, callback)` with
  `onAssociationCreated` / `onAssociationPending` / `onFailure`
- API 31-32: `cdm.associate(request, callback, handler)` with
  `onDeviceFound(IntentSender)` / `onFailure`
- Check existing: API 33+ uses `cdm.myAssociations`, older uses `cdm.associations`
- Requires `<uses-feature android:name="android.software.companion_device_setup" />`

**getActiveDevice (04,09) is unreliable:** Always returns the querying device's
own MAC. Use `getConnectedDevices` (05,01) for audio-active devices and
`getDeviceInfo` (04,05) per device for ACL connection state.


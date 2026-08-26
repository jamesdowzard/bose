# Bose Android — companion device, widget, service internals

<!-- Reference detail moved out of the sibling CLAUDE.md on 2026-08-27 to keep it under the
     8 KB fleet cap. The CLAUDE.md keeps the rules and traps; this holds the tables. -->

### Companion Device (Critical)

The app registers as a **companion device** for the Bose headphones via
`CompanionDeviceManager`. This is essential — without it, Android 12+ blocks
starting foreground services from the background, which breaks the widget.

**What it grants:**
- Background FGS starts (widget taps can start BoseService)
- Battery optimization exemption (service stays alive)
- Wake on BT connect/disconnect

**Setup:** Automatic on first app launch. User sees a one-time "Allow Bose to
access verBosita?" prompt. Association persists across app reinstalls.

**Manifest requirements:**
- `<uses-feature android:name="android.software.companion_device_setup" />`
- `REQUEST_COMPANION_RUN_IN_BACKGROUND`
- `REQUEST_COMPANION_USE_DATA_IN_BACKGROUND`
- `REQUEST_COMPANION_START_FOREGROUND_SERVICES_FROM_BACKGROUND`
- `FOREGROUND_SERVICE_CONNECTED_DEVICE` (required for `connectedDevice` service type)

### Widget (5 buttons: phone, mac, ipad, iphone, quest)

Buttons use `PendingIntent.getForegroundService()` to send `ACTION_CONNECT_DEVICE`
directly to `BoseService`. No broadcast receiver in the click path.

**State colors** (warm-paper card, shared with the #98 app retheme):
- Burnt-orange chip (#AF3A03) = active (audio routed here)
- Blue chip (#1B4A82) = connected but not active
- Muted paper chip (#E6DCC6 fill / #6E6A5E text) = offline/not connected

The widget is a paper **card** (`@drawable/widget_card_bg`: #FCFAF4 fill, #E6DCC6
hairline border, rounded) sitting on the home-screen wallpaper. Active/connected
are solid filled chips so they read on any wallpaper. Constants live in
`BoseWidgetProvider.kt` (independent of the app's Compose palette in `MainActivity.kt`).

Battery percentage shown as overlay text — own on-paper thresholds: warm-red
(#A82E2E) ≤15, burnt-orange (#AF3A03) ≤30, secondary grey (#6E6A5E) otherwise.

### BoseService (Foreground Service)

Single-threaded executor runs all RFCOMM operations off the main thread.
Key actions: `ACTION_CONNECT_DEVICE`, `ACTION_REFRESH`.

**On device switch to "phone":**
1. BMAP connectDevice(phone_mac) -- tells headphones to route audio to phone
2. ensureA2dp(boseDevice) -- phone-side A2DP connect (Samsung needs this)
3. 500ms wait for BT to settle
4. nudgeMediaPlayback() -- pause/play to force audio stream handover

**Skip-if-active:** Tapping an already-active device is a no-op (checks SharedPrefs).

**Cached-first reads (#148 parity):** `refreshStatus()` and the Compose app's
`refreshAll()` both gate on `SlotGate` — phone holds neither slot → paint
`StateCache` (widget battery gains a "· Xm" age suffix; the app shows the same
staleness banner as the Mac with a **Read live** button = `forceLive`). Only
`forceLive`, writes, and device switches touch the radio from a non-slot phone.


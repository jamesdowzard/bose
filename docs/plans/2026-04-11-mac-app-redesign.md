# Mac App Redesign — Landscape Frosted Dark

## Summary

Replace the current 380x600 portrait dark-green UI with a 640x360 landscape frosted-dark two-panel layout. Focus on device switching with all controls visible on one screen.

## Window

- 640x360, fixed size (not resizable)
- `NSVisualEffectView` with `.hudWindow` or `.dark` material for translucent background
- No title bar chrome — use `.titlebarAppearsTransparent` + `.fullSizeContentView`

## Theme

- **Background**: frosted dark translucency (macOS vibrancy), no solid black
- **Active accent**: white / light grey (replaces neon green)
- **Secondary**: muted warm grey
- **Text**: white on translucent
- **Device states**:
  - Active = white text + subtle white glow
  - Connected = dimmed white
  - Offline = 40% opacity grey
- No neon green anywhere

## Layout

### Left Panel (~220px) — Status sidebar

- Headphone name ("verBosita") + battery % (large, prominent)
- ANC mode — 4 segmented buttons: Quiet / Aware / C1 / C2
- Volume slider (compact)
- Firmware version (small, bottom)

### Right Panel (~420px) — Controls

- **Device grid** (top, primary): 3x2 grid of device buttons (phone, mac, ipad, iphone, quest, tv). Bigger than current. State colours per theme above. Tapping switches audio (uses polling verification from #67).
- **"Connect Mac" button**: prominent at top of device grid or as a dedicated shortcut for quick Mac reclaim.
- **EQ** (bottom, compact): preset row (Flat/Bass+/Treble+/Vocal) + 3 inline sliders (bass/mid/treble)

## Removed

- Expandable settings section (multipoint, device rename, ANC depth, auto-off, immersion, wear detection) — too rare to warrant screen space. Move to a menu bar dropdown or remove entirely.
- Expandable info section (serial, platform, codename, codec, MAC, EQ readout) — firmware stays in sidebar, rest dropped.
- Scrolling — everything fits on one screen.
- Refresh button — state updates via existing 10s poll.

## Keyboard Shortcut

- Cmd+M or Option+B to connect Mac (quick reclaim)

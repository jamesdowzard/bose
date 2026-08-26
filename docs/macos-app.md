# Bose.app (macOS) — the windowed control surface

<!-- Reference detail moved out of the sibling CLAUDE.md on 2026-08-27 to keep it under the
     8 KB fleet cap. The CLAUDE.md keeps the rules and traps; this holds the tables. -->

## Bose.app
- `macos/BoseControl/` -- **Bose.app**: a windowed SwiftUI app (warm-paper light
  **three-panel**: left = settings (battery/ANC mode/Immersive Audio (spatial Off/Still/Motion)/volume/multipoint + auto-pause/auto-answer toggles
  (01,18 / 01,1B) + a favourites display (1F,08, read-only)); middle = a **draggable device sidebar** (a vertical
  list of device rows — **drag up/down to rank priority**, index 0 = primary/① and 1 = secondary/② for the
  multipoint pair; **tap a row to connect** that device as the active sink; a rank badge + a state dot
  ● active / ● held / ○ offline per row (hollow ring + dimmed row when painting a cached snapshot — last-known, not live);
  drag persists `priority.json` via `bose priority --set` **on each hover-swap, not on drop** (a release over the
  EQ panel or outside the window cancels the drop, which used to leave the badges showing an order that was never
  saved — no drop delegate can catch that), and does NOT touch the radio — connecting is only ever
  an explicit tap; right-click → Disconnect); right = EQ. The light
  theme (burnt-orange `#AF3A03` accent on warm paper, from the Midterm `paper-hc` palette)
  is shared with the Android app; macOS colours live in `ContentView.swift`, Android in
  `MainActivity.kt` (`BoseAccent`/`BoseConnected`/…). Six ANC
  mode buttons (Quiet/Aware/Immersion/Cinema/C1/C2 = slots 0-5; the C1/C2 buttons show
  the custom slots' stored on-device names when set, e.g. "Spatial", and can be **renamed
  in place via right-click → Rename…** — `mode-name --slot`, active mode untouched) + a **noise-level
  slider** driven by `anc-level` (1F,06) — NOT a raw depth (1F,0A disables ANC, #83).
  The slider is enabled only on the adjustable custom slots (4/5, firmware `cncMutable`)
  and greys out with a "level is fixed" hint on Quiet/Aware/Immersion/Cinema.
  It is a **thin front-end that shells `bose`** — NO RFCOMM, NO IOBluetooth, NO
  protocol code — reading via `bose info --json` and writing via the verbs. It is
  **user-launched and event-driven**: reads on window-open, on app-focus, after each
  write, and on the banner's Read-live button — never on a timer. Open/focus reads are **cached-first** (#148):
  `info --json` checks ACL presence (free, zero radio) and with no link serves the
  timestamped last-good snapshot (`~/.cache/bose/state-<MAC>.json`) stamped
  `reachable:false` + `ageSeconds` instead of PAGING the headphones — so opening the
  app while audio plays on another sink is instant and can't glitch it. The app shows
  It also **surfaces CLI stderr in a transient error banner** (tap to dismiss, auto-clears
  after 6s): every write path reports through it, so a precise CLI diagnosis like
  "appletv is not in verBosita's paired list" reaches the user instead of a spinner that
  silently reverts. `run()` drains stdout and stderr concurrently, which also closes a
  latent deadlock (a child writing >64KB to stderr would have wedged the serial queue).
  Reads stay silent by design — they already degrade to the cached view. The app shows
  a staleness banner ("Not connected to this Mac — last known state (Xm ago)") over
  the full last-known dashboard with a **Read live** button (a forced `--page` read), and every
  post-write/connect confirm read is `--page` too (a settle loop must never confirm
  against the cache). **Enforced, not aspirational** — `write()` alone was still
  confirming against the cache (fixed 2026-07-20), and that was not a race but a
  guarantee: after a write that drops the link (`disconnect mac`) there is no ACL, so the
  cache is the ONLY thing that can be served and the app repainted pre-write state every
  time. **The ONE carve-out (2026-07-21): a local-Mac `disconnect` must NOT force `--page`.**
  That write intentionally drops this Mac's ACL, and a forced `--page` confirm reopens
  RFCOMM and re-pages the very device just disconnected — an audible disconnect-then-
  reconnect. So `write()` forces `--page` for everything EXCEPT `disconnect mac`, which
  confirms cached-first (serves the last-known snapshot behind the staleness banner —
  the correct "disconnected" view — without re-paging). Every other write keeps the link,
  so cached-first there still reads live; only the self-disconnect must skip the page.
  **Corollary, and the thing a future change is most likely to get wrong again: any
  guard that reads `deviceStates` must also check `reachable`** — the painted state is
  last-known, not live. Both HIGH findings here were that mistake: the skip-if-active
  guard made the Mac row un-tappable exactly when you needed it (cached state said
  "active" while the link was down, and `disconnectedView`'s Connect button was
  unreachable because `isConnected` was true), and `assertedActiveDevice` was never
  cleared on disconnect, so the row you just disconnected repainted as the active sink. `reachable` = this Mac's link now; `connected` = we have real
  headphone state to paint (the app no longer wipes to "Not Connected" on a mere
  unreachable read — only when there's nothing known at all). Build `bash macos/build.sh [--install]`
  (Developer-ID signed → `/Applications`; no LaunchAgent). In-window keys: ⌘1-6
  ANC modes (slots 0-5), ⌘↑/⌘↓ volume (⌘R/⌘M removed 2026-07-18 — unused; live read = the banner button, connect Mac = its device row). Global hotkeys stay in
  Hammerspoon. The `--json` read seam lives in `cli/main.swift` (`cmdInfoJSON`, pure
  formatting over `getAllStateWithDevices` — bulk state + the device grid's active sink
  AND idle ACL probes in ONE warm session, so neither is lost to the cold-second-session
  quirk a separate `getDeviceStates` call hit, #132). It surfaces — but does not fix —
  the #83 flight/ancDepth behaviour; that fix lands in the CLI and the app inherits it.


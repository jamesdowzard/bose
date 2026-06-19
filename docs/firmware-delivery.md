# Firmware Delivery Chain & `.dfu` Format

Durable record of a read-only investigation (2026-06-20) into **how Bose firmware is
distributed**, whether the QC Ultra 2 (`wolverine`) image can be pulled and analysed,
and what a Bose firmware blob actually looks like inside. Companion to
[`reverse-engineering.md`](./reverse-engineering.md) (which covers BMAP). Everything
here was pure HTTP GETs + local analysis — **no device writes, zero brick risk.**

## TL;DR

- **Our device** = USB **PID `0x4082`** = codename **`wolverine`** = QC Ultra 2, platform **QCC384** (Qualcomm). PID matches what macOS reports for "verBosita".
- **`wolverine` firmware is cloud-gated** (`USE_CLOUD="4"`, no static `<IMAGE>`), so it is **not** downloadable from the legacy `downloads.bose.com` `.dfu` index. Pulling it would mean reversing Bose's authenticated cloud-updater API — and the image is signed/encrypted anyway.
- Older devices (e.g. `baywolf` / QC35 II) **are** on the static index. Their `.dfu` is a **`CSR-dfu2`** packed BlueCore container (AES present, ~no readable app symbols) — i.e. **opaque, not casually disassemblable** even for the easy case. Newer devices add `_signed.xuv` images on top.
- **Reading/analysing is brick-safe; only *flashing* risks the device.** Confirmed.

## The delivery chain

The official updater is the web app at **`https://btu.bose.com/`**, which pulls firmware
from **`https://downloads.bose.com/`**. The third-party **`bose-dfu`** (github.com/tchebb/bose-dfu)
documents the format; **`bosefirmware/ced`** archives older images (but **not** the QC Ultra).

1. **Master index — `https://downloads.bose.com/lookup.xml`** maps every USB PID → a per-codename `index.xml`:
   ```xml
   <PRODUCT PID="0x4082" URL="https://downloads.bose.com/ced/wolverine/index.xml" DEVICE_CLASS="BMAP"/>
   ```
   (Other BMAP examples seen: `0x4024 goodyear`, `0x402D revel`, `0x402F lando`, `0x4039 duran`, `0x403A gwen`, `0x4060 olivia`.)

2. **Per-device `index.xml`** — for a *static* device lists `<RELEASE>` → `<IMAGE>` rows:
   ```xml
   <!-- baywolf (QC35 II, PID 0x4020) -->
   <RELEASE REVISION="3.1.8.1835" URLPATH="/ced/PRE_RRA/baywolf/">
     <IMAGE FILENAME="BayWolf_3.1.8_stack_plus_app.dfu"      LENGTH="1899496"  SUBID="0" />
     <IMAGE FILENAME="BayWolf_3.1.8_ext_signed.xuv"          LENGTH="22618624" SUBID="1" TARGET="1" />
     <IMAGE FILENAME="BayWolf_3.1.8_acorn_coeffs_signed.xuv" LENGTH="32944"    SUBID="2" TARGET="3" />
   ```
   Image at `https://downloads.bose.com<URLPATH><FILENAME>`.

3. **`wolverine` (our QC Ultra 2) returns essentially empty** — cloud-gated:
   ```xml
   <INDEX REVISION="01.00.00">
     <DEVICE ID="0x4082" PRODUCTNAME="wolverine" USE_CLOUD="4"> </DEVICE>
   </INDEX>
   ```
   No `<IMAGE>`. `USE_CLOUD="4"` ⇒ firmware comes from Bose's cloud API, not the static CDN.

## `.dfu` format (from the `baywolf` image — the analysable old case)

```
header magic : "CSR-dfu2"   (also CSRbcfw1 / "CSR - bc7" strings)
binwalk      : AES S-Box @ 0xCB880
strings      : ~1305 in 1.9 MB, no readable app/ARM symbols
file(1)      : data  (no recognised container)
```

- **`CSR-dfu2`** = Cambridge Silicon Radio (now Qualcomm) **BlueCore** DFU container — the QC35 II's chip family. Packed/opaque, with AES in the image. Not an ELF, not plaintext code; disassembly would need CSR-specific unpacking, not just objdump.
- The `_signed.xuv` siblings confirm **code-signing** on the larger images.
- Implication for `wolverine`: a newer **QCC384** part, **cloud-delivered + signed** — strictly harder than this already-opaque old case. Reprogramming would need Bose's signing key or a secure-boot bypass for the QCC384, plus unpacking — months of specialist RE with bricking risk. Not worth it to restore a battery chime.

## Why this matters for the app (the productive surface)

Firmware is a dead end; **BMAP is where the leverage is** (see `reverse-engineering.md`).
Relevant to the v8.2.20 lost-battery-announcement grievance:

- The removed power-on battery announcement was firmware *behaviour* (spoken clip → chime). The Settings block (`0x01`) exposes `0x03 VoicePrompts` (**language** config) and `0x08 Alerts`, but **no toggle restores the percentage announcement** — the clip-selection logic is gone from firmware.
- However **battery level is readable** over BMAP (Status `02,02`; the app already shows it). So the realistic rebuild is **host-side**: have the Mac app speak "Bose, NN percent" on connect, or show a live menu-bar readout — claws back the *information* the update removed, without touching firmware.

## Reproduce (all read-only)

```bash
curl -s https://downloads.bose.com/lookup.xml | grep -i 0x4082          # find wolverine
curl -s https://downloads.bose.com/ced/wolverine/index.xml              # cloud-gated, empty
# analysable old example:
curl -s https://downloads.bose.com/ced/PRE_RRA/baywolf/index.xml
curl -s -o baywolf.dfu https://downloads.bose.com/ced/PRE_RRA/baywolf/BayWolf_3.1.8_stack_plus_app.dfu
file baywolf.dfu; xxd baywolf.dfu | head; binwalk baywolf.dfu; strings -n6 baywolf.dfu | head
```

## Cross-reference

Wider engineering context (Bluetooth profiles, the QC Ultra call-mic limitation, the
v8.2.20 feature-removal saga, firmware-vs-VHDL) lives in the **`bluetooth-audio`** dossier
(`~/code/personal/dossiers/bluetooth-audio/`).

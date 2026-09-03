# Pioneer DDJ-SZ Linux Audio Support — Project Writeup

**Target:** Raspberry Pi 5, Raspberry Pi OS (Debian 13 "trixie"), kernel `6.18.34+rpt-rpi-2712`
**Result:** Full-duplex USB audio (10-channel playback + 10-channel capture, S24_3LE @ 44.1kHz) working via a ~90-line patch to the existing in-tree `snd-usb-audio` kernel module. No new driver, no DKMS, no out-of-tree module framework.
**Status:** Playback and capture both verified working with real signal. MIDI/control-surface mapping untouched (separate class-compliant interface, was already working, out of scope).

> **Read this first (updated 2026-09-03).** This document is a running research log, and several conclusions in the later sections were later proved wrong — notably that the arm sequence broke master output, that playback channels 0/1 were "Master L/R", and that channel bleed pointed to a hardware fault. Each is marked inline where it appears. The corrected, current picture lives in the [README](../README.md) channel map and in [CUE-INVESTIGATION.md](CUE-INVESTIGATION.md); where they disagree with this log, they win.

---

## 1. Why this is a "quirk," not a driver

This is the part most likely to be misunderstood by anyone new to Linux USB audio, so it's worth being explicit.

Linux already ships a generic USB Audio Class (UAC) driver: `snd-usb-audio` (`sound/usb/`). Any USB audio device that implements the standard USB Audio Class 1.0 or 2.0 descriptors works with this driver automatically, with zero device-specific code — the driver reads the device's own descriptors at enumeration time and configures itself. This is why, e.g., a generic USB headset or a class-compliant audio interface "just works" on Linux with no drivers to install.

The DDJ-SZ (and most higher-end Pioneer DJ mixers/controllers) does **not** implement UAC on its audio interface. Instead, its audio interface identifies as USB class `0xFF` ("vendor-specific"), meaning the OS cannot infer anything about it from standard descriptors — channel count, sample format, activation sequence, all of it is undocumented and vendor-proprietary. On Windows/Mac, Pioneer ships a real vendor driver that hard-codes this knowledge.

On Linux, `snd-usb-audio` has a **quirks system** (`sound/usb/quirks.c` + `sound/usb/quirks-table.h`) specifically for this situation: a table, keyed by USB vendor:product ID, that manually supplies the information the driver would normally read from standard descriptors — endpoint numbers, channel count, sample format, sample rate, and (if the device needs one) a device-specific "activation" callback to run before streaming will work. This is not a new driver; it's a data-table entry plus, at most, a small function, inside the driver that already exists and already handles everything else (URB submission, PCM buffer management, ALSA device registration, etc.). Many devices from the same class of "prosumer proprietary USB audio" hardware are already supported this way — the DDJ-SZ patch here uses the exact same mechanism already used for the Pioneer DJM-750, DJM-850, DJM-900NXS2, DJM-450, DJM-V10, DDJ-SX3, DDJ-RB, and others (`sound/usb/quirks-table.h`, `sound/usb/quirks.c`).

Concretely, this project added:
- One ~49-line entry to `quirks-table.h`: a static struct describing "USB ID 08e4:0191 has 10-channel S24_3LE 44.1kHz-fixed audio on interface 0 altsetting 1, playback on endpoint 0x01, capture on endpoint 0x82."
- One new `case` in an existing `switch` statement in `quirks.c`, wiring the DDJ-SZ's USB ID to a device-specific activation function (itself only ~38 new lines, described in §5).

No new kernel module, no new subsystem, no new files. `snd-usb-audio.ko` is rebuilt with these ~87 extra lines and replaces the stock one.

---

## 2. Reverse-engineering the protocol: USB capture with Wireshark/USBPcap

Since the DDJ-SZ's audio interface is vendor-specific, there is no public spec for how to talk to it. The only way to learn the protocol was to capture and decode what the *official Windows driver* actually sends the device, on the theory that whatever bytes make the real driver work will make any driver work.

**Method:**
1. On a Windows machine, [USBPcap](https://desowin.org/usbpcap/) was installed — this is a Windows kernel-mode USB bus filter driver that captures raw USB traffic (control transfers, isochronous packets, everything) at the same level Wireshark captures network traffic. Wireshark was used as the capture UI/frontend.
2. A capture was started, then the DDJ-SZ was: enumerated (plugged in fresh), used for **audio playback** through Serato (Pioneer's usual DJ software pairing) so real music payload bytes would appear in the capture, and used for **mic recording** so real capture-direction payload bytes would appear too.
3. The resulting file (`ddjdz.pcapng`, ~91MB, ~118,000 USB frames) was analyzed on the Linux side using `tshark` (Wireshark's CLI), e.g.:
   ```bash
   tshark -r ddjdz.pcapng -Y "usb.idVendor == 0x08e4" -T fields -e frame.number -e usb.device_address -e usb.idVendor -e usb.idProduct
   ```
   This immediately gave the device's USB address within the capture (device address 8), which all further filters keyed off with `usb.device_address == 8`.

**What the capture format looks like:** USBPcap wraps every USB transaction in a 28-byte pseudo-header (IRP ID, status, URB function code, bus/device/endpoint, transfer type, direction, data length) followed by the actual transferred bytes. Wireshark's USB dissector parses this automatically and exposes fields like `usb.setup.bRequest`, `usb.setup.wValue`, `usb.setup.wIndex`, and — for completed transfers — `CONTROL response data` in the verbose (`-V`) output. Isochronous audio payload frames appear as separate frames tagged with the relevant endpoint (`0x01` OUT or `0x82` IN) and transfer type `URB_ISOCH`.

### 2a. Establishing the descriptor-level facts

Filtering on `usb.device_address == 8` and looking at the `GET_DESCRIPTOR` (`bRequest == 6`) responses during initial enumeration gave the device, configuration, and interface descriptors — confirming:
- USB ID `08e4:0191` (Pioneer Corp vendor ID, DDJ-SZ product ID)
- Interface 0 is class `0xFF` (vendor-specific), with alt setting 0 = idle (0 endpoints) and alt setting 1 = active (2 isochronous endpoints)
- Endpoint `0x01` OUT, max packet 1024 bytes, interval 3; endpoint `0x82` IN, max packet 1024 bytes, interval 3

### 2b. Confirming the audio format from actual payload bytes, not just bitrate math

The endpoint max-packet-size alone is ambiguous about sample format: 1024 bytes/packet at a given rate is consistent with more than one channel-count/bit-depth combination (a **15-channel/16-bit hypothesis** was initially plausible on paper). This was resolved empirically, not by guessing: isochronous data frames on endpoint `0x01` (playback, capturing Serato outputting known music) were extracted and decoded under both hypotheses (10ch/24-bit-packed vs. 15ch/16-bit), and the interpretation was checked for internal coherence — i.e., does de-interleaving under this channel count produce two channels (L/R) whose waveforms are correlated the way a real stereo mix should be, with plausible dynamic range and no garbage/noise artifacts from mis-alignment. The 10-channel, `S24_3LE` (24-bit samples packed into 3 bytes, little-endian) interpretation at a fixed 44.1kHz produced coherent, correlated stereo audio on de-interleaved channels 0/1; the 15-channel/16-bit hypothesis did not. This ruled out the ambiguity and confirmed: **10 channels, S24_3LE, fixed 44.1kHz, both directions.**

Channel mapping was established the same empirical way: channels 0/1 (playback) correlated with the Master output content being played in Serato → **Master L/R**. Channels 8/9 (capture) correlated with spoken audio during a mic-recording test in the capture → **Mic**. Channels 2–7 (both directions) were **not** mapped to specific physical ins/outs — no per-channel isolation test was done for those in the original Windows capture, so they remain unknown/unconfirmed. This is a documented open item, not a blocker for basic bring-up.

> **Superseded 2026-09-03.** The "Master L/R" conclusion above was wrong, and the unknowns are now resolved for playback. Playback channels 0/1 do not carry a master mix — they feed the unit's *physical channel strip 1*, which then applies its own analog trim/EQ/fader/crossfader. It only looked like "Master" because a single deck was playing at the time, so strip 1's output was the whole mix. The full playback map, established by feeding a tone into each pair and watching which strip responded, is: 0/1 → strip 1, 2/3 → strip 2, 4/5 → strip 3, 6/7 → strip 4, 8/9 → booth output. Master is produced in analog by the onboard mixer and never crosses USB at all. Capture 8/9 = mic still holds; capture 0-7 remain unidentified. See the README's channel map and [CUE-INVESTIGATION.md](CUE-INVESTIGATION.md).

### 2c. Finding the activation control transfers

Filtering for control transfers (`usb.transfer_type == 0x02`) on the device address, in time order, showed a control transfer immediately preceding the point where isochronous streaming actually starts flowing:
```
bmRequestType=0x22, bRequest=0x01 (SET_CUR), wValue=0x0100 (Sampling Freq Control),
wIndex=0x0082, wLength=3, data = 44 ac 00 (little-endian 44100)
```
`0x22` = UAC-style `SET_CUR` class request, endpoint recipient — this is a standard-shaped Audio Class request even though the interface itself is vendor-specific (Pioneer reuses the UAC request shape for this one control). This exact request shape (`SET_INTERFACE` to alt-setting 1, then this `SET_CUR`) turned out to be **structurally identical** to an existing function already in mainline Linux, `pioneer_djm_set_format_quirk()` in `sound/usb/quirks.c`, used for the DJM-750/850/900NXS2/450/V10. Those devices just call it with a different `wIndex` (their own captured endpoint number) — for the DDJ-SZ, the literal captured `wIndex` is `0x0082`, which is **not a guess or a copy from the DJM example** (which uses `0x0086` or `0x0082` depending on model) — it is read directly off this device's own capture.

This single finding is what made the "no new driver needed" approach viable at all: the DDJ-SZ's activation handshake reuses infrastructure that already exists, it just needed to be wired up for this device's own ID and endpoint index.

---

## 3. Kernel build environment setup

The Pi runs Raspberry Pi OS "trixie" (Debian 13), which — notably, and differently from older Raspberry Pi OS releases the original handoff doc assumed — ships kernel headers as proper Debian-style packages (`linux-headers-6.18.34+rpt-rpi-2712`, etc.) that are pre-matched to the running kernel, including a working `Module.symvers` for that exact build, and a `/lib/modules/$(uname -r)/build` symlink already pointing at them. This meant several steps assumed necessary in the original handoff (installing `raspberrypi-kernel-headers`, manually verifying which legacy branch matched) were unnecessary or worked differently than expected — see §6 for where this caused a real problem.

However, those header packages only ship enough to build **external** (out-of-tree) modules — they do **not** include the actual source of in-tree drivers like `sound/usb/*.c`. To edit and rebuild `sound/usb`, the actual kernel source tree was needed, matched to the exact running version.

Steps taken:
1. `uname -r` → `6.18.34+rpt-rpi-2712`
2. Identified the matching upstream source branch by listing branches on the `raspberrypi/linux` GitHub repo (`git ls-remote --heads`) and finding `rpi-6.18.y` (branch names follow `rpi-<major>.<minor>.y`, not the full point release).
3. `git clone --depth=1 --branch rpi-6.18.y https://github.com/raspberrypi/linux.git` — shallow clone for speed (only need the tip initially).
4. Installed missing build dependencies: `bc bison flex libssl-dev libncurses-dev` (the running system had none of these pre-installed).
5. Extracted the **running kernel's actual config**: `sudo modprobe configs && zcat /proc/config.gz > .config` (the `configs` kernel module has to be loaded first — `/proc/config.gz` doesn't exist until then).
6. `make olddefconfig` to reconcile that config against this source tree's current `Kconfig` options.

---

## 4. Applying and building the quirk

The two edits were applied exactly as designed:

**`sound/usb/quirks-table.h`** — new entry inserted immediately after the existing DJM-750 entry (found via `grep -n "0x08e4, 0x017f"` as the anchor), following the same `QUIRK_DRIVER_INFO` / `QUIRK_DATA_COMPOSITE` / `QUIRK_DATA_AUDIOFORMAT` structure used by every other entry in the table — two `QUIRK_DATA_AUDIOFORMAT` blocks (one for the OUT endpoint, one for the IN endpoint), each declaring 10 channels, `SNDRV_PCM_FMTBIT_S24_3LE`, interface 0, altsetting 1, fixed 44100 rate.

**`sound/usb/quirks.c`** — a new `case USB_ID(0x08e4, 0x0191):` added to the existing `switch` inside `snd_usb_set_format_quirk()`, next to the DJM-750/850 cases, calling `pioneer_djm_set_format_quirk(subs, 0x0082)` (later extended — see §5).

Build (module-only, not a full kernel rebuild):
```bash
ARCH=arm64 LOCALVERSION= make -j$(nproc) modules_prepare
ARCH=arm64 LOCALVERSION= make -j$(nproc) M=sound/usb
```
Output: `sound/usb/snd-usb-audio.ko`, confirmed via `modinfo` to carry the new `usb:v08E4p0191...` device-ID alias.

---

## 5. Debugging round 1: version-string mismatch (module wouldn't have loaded)

The first successful build had a subtle but fatal problem: `modinfo` showed `vermagic: 6.18.45-v8-16k+ SMP preempt mod_unload modversions aarch64` — but the running kernel is `6.18.34+rpt-rpi-2712`. The Linux module loader refuses to load a module whose vermagic string doesn't exactly match `uname -r`, so this module would have been rejected at `insmod` time.

Two separate problems, diagnosed and fixed independently:

1. **Wrong source commit.** The shallow clone's branch tip (`rpi-6.18.y` HEAD) had already moved on to `6.18.45` — a newer point release than what's actually installed. This was fixed by deepening the shallow clone (`git fetch --deepen=N`, done incrementally: 100, then another 150 commits, until the range of `SUBLEVEL` values in `Makefile` across history spanned past 34) and then scripting a search across all fetched commits for the one where `Makefile` read `VERSION = 6 / PATCHLEVEL = 18 / SUBLEVEL = 34`, taking the most recent (first, since `git log` is newest-first) such commit — i.e. the last commit before the branch moved on to `.35`. The working-tree edits were `git stash`ed, the tree was checked out to that exact commit, and the stash was popped back on top (auto-merged cleanly).

2. **Missing/incorrect local version suffix.** Even at the right base version, the built release string was `6.18.34-v8-16k+`, not `6.18.34+rpt-rpi-2712`. The `-v8-16k` piece came from `CONFIG_LOCALVERSION` baked into the config pulled from `/proc/config.gz` — apparently the raw upstream RPi Kconfig default, with the final `+rpt-rpi-2712` packaging suffix applied separately by Raspberry Pi Foundation's build/package scripts rather than stored in-tree. This was fixed by directly editing `.config` (`CONFIG_LOCALVERSION="+rpt-rpi-2712"`) to match. That still left a trailing `+` (kernel's `scripts/setlocalversion` appends `+` whenever the git tree has uncommitted changes and `LOCALVERSION` isn't explicitly set on the command line, which it wasn't in the reconciled build — and this tree *did* have uncommitted changes, namely our own two quirk edits). Fixed by passing `LOCALVERSION=` (empty, but explicitly set) on the `make` command line for every subsequent build, which per `scripts/setlocalversion`'s own logic suppresses the dirty-tree `+` suffix entirely.

Final, correct vermagic after both fixes: `6.18.34+rpt-rpi-2712 SMP preempt mod_unload modversions aarch64` — exact match.

---

## 6. Installation

- Stock module was `sound/usb/snd-usb-audio.ko.xz` (Debian ships kernel modules `xz`-compressed) at `/lib/modules/6.18.34+rpt-rpi-2712/kernel/sound/usb/`.
- Verified before touching anything that `snd_usb_audio` was **not currently loaded** (`lsmod`) and no USB audio device was in use (`lsusb` showed no Pioneer device connected yet, and the only active `/dev/snd/*` users were HDMI-related pipewire/wireplumber) — so replacing it carried no risk of disrupting an active audio session.
- Backed up the original compressed module to `/root/ddj-sz-backup/snd-usb-audio.ko.xz` for rollback.
- Removed the stock `.ko.xz`, copied in the freshly built uncompressed `.ko`, ran `depmod -a` to refresh the module dependency database, then `modprobe snd_usb_audio` to load it.
- Confirmed clean load: `dmesg` showed only the expected "loading out-of-tree module taints kernel" notice (expected/harmless — any module built outside the distro's official build pipeline sets this taint flag) and `usbcore: registered new interface driver snd-usb-audio`, no probe errors.

This installation is **persistent across reboots** as-is, since the file was replaced in place under `/lib/modules/` and `depmod` was refreshed — it will be picked up automatically on every boot. It will only revert to stock if a future `raspberrypi-kernel`/`linux-image` package update reinstalls the kernel/modules package, at which point the build in `~/projects/ddj-sz-kernel` can simply be rebuilt and reinstalled the same way (assuming the new kernel version is close enough that the same source still applies — a large kernel version jump might need re-cloning the matching branch).

---

## 7. Testing round 1: playback confirmed, capture silently broken

With the DDJ-SZ plugged in:
- `lsusb` showed `08e4:0191 Pioneer Corp. DDJ-SZ` enumerated.
- `dmesg` showed clean enumeration, no probe errors.
- `aplay -l` / `arecord -l` both listed a new card: `card 2: DDJSZ [DDJ-SZ], device 0: USB Audio [USB Audio]`.
- `/proc/asound/card2/stream0` confirmed the driver's own view of the format matched exactly what was designed: 10 channels, `S24_3LE`, 44100Hz, correct endpoints, both directions listed with `Status: Stop` (idle, correctly not yet streaming).

**Playback test:**
```bash
speaker-test -D hw:2,0 -c 10 -r 44100 -F S24_3LE -l 1
```
(Note: `speaker-test`'s default `-t wav` mode is hardcoded to 48kHz/S16_LE regardless of `-F`/`-r` flags and fails `hwparams` against this fixed-format device — had to drop `-t wav` and use the default sine/pink-noise generator instead, which does respect the requested format.) This opened the stream successfully (`Rate set to 44100Hz`, `Stream parameters are 44100Hz, S24_3LE, 10 channels`), ran a full pink-noise sweep across all 10 channels with no xruns or errors in `dmesg`, and **was independently confirmed audible** — real sound heard out of the DDJ-SZ Master output during the test.

**Capture test — first attempt, misleading initial run:**
```bash
arecord -D hw:2,0 -c 10 -f S24_3LE -r 44100 test.wav
```
This ran without any ALSA/USB error and produced a correctly-sized WAV file. But analysis of the actual sample data (a small Python script computing per-channel RMS and peak from the raw 24-bit packed samples, since no `sox` was installed) showed **every single sample on every one of the 10 channels was exactly zero** — not just quiet, a hard zero, for the entire recording. This is more diagnostic than it might look: normal analog noise floor almost never reads as an exact zero for an entire capture; a true unbroken zero strongly suggests the ADC/capture data path isn't actually delivering real samples at all, as opposed to "there's just nothing to hear."

The first run didn't definitively rule out user/procedural error (nobody was confirmed to actually be talking into the mic during that exact window, and the mic's physical gain/on-off state on the hardware wasn't verified). This was explicitly re-tested a second time, this time coordinating the exact recording window with a live person talking into the mic and confirming the hardware mic gain was up — and the result was still a hard, uniform zero across all channels. This ruled out user error and confirmed a real capture-path defect.

Notably, `/proc/asound/card2/stream0` also showed, only for the playback stream, `Implicit Feedback Mode: Yes`, with endpoint `0x82` (the capture endpoint) listed as the sync source — **even though the quirk table entry deliberately did not set the `USB_ENDPOINT_USAGE_IMPLICIT_FB` flag** (per the reasoning documented in the original handoff: the SZ has genuinely separate, independently-addressed IN/OUT endpoints and likely doesn't need one endpoint borrowing the other for clock sync, unlike some devices that only have one isoc pair doing double duty). ALSA's generic USB-audio code auto-detects and enables implicit feedback for an async OUT endpoint lacking an explicit sync endpoint, by matching a nearby IN endpoint on the same interface/altsetting — this happened automatically without the flag being set. This was not the cause of the zeroed capture data (capture was tested standalone, with no playback stream open concurrently, so no implicit-feedback URB contention was in play at the time) but is worth knowing about if playback and capture are ever run simultaneously later and something misbehaves.

---

## 8. Root-causing the silent capture failure via the pcap

The original handoff document had already flagged, as its documented contingency plan, that a block of **vendor status-query control transfers** was observed preceding the `SET_CUR` in the original Windows capture — repeated `bmRequestType=0x40/bRequest=3` writes and `bmRequestType=0xc0/bRequest=0` reads, described only in paraphrase (`returning 00 04 04 04 04 04`) without exact `wValue`/`wIndex` values, with an open question of whether they were actually required for streaming or just incidental status polling by the Windows driver.

With capture confirmed broken and playback confirmed working — both driven by the *same* `pioneer_djm_set_format_quirk()` activation call — the working hypothesis was that this omitted block specifically arms the ADC/mic path, while the DAC/playback path apparently doesn't need it. Re-examining the original `ddjdz.pcapng` resolved this precisely:

```bash
tshark -r ddjdz.pcapng -Y "usb.device_address == 8 && usb.setup.bRequest == 3 && usb.bmRequestType == 0x40" \
  -T fields -e frame.number -e frame.time_relative -e usb.setup.wValue -e usb.setup.wIndex
```
This returned exactly **6 matches**, all clustered at `t ≈ 3.65–3.69s` — i.e. once, immediately after initial enumeration/`GET_DESCRIPTOR` traffic, and **never repeated anywhere else** in the ~118,000-frame, multi-minute capture (confirmed by checking the full result set, not just a sample). This timing pattern (once, at device bring-up, never again) is the signature of a one-time device-arming/initialization sequence, as opposed to something that would need to run before every stream open.

Each write's response was pulled with `tshark -Y "frame.number == N" -V` and reading the `CONTROL response data` field from the verbose dissection (the plain `-T fields` extraction didn't expose this particular field by name, so per-frame `-V` was used instead):

| # | write `wValue` | write `wIndex` | read length | read response |
|---|---|---|---|---|
| 1 | `0x0100` | `0x8002` | 6 | `00 04 04 04 04 04` |
| 2 | `0x0200` | `0x8002` | 6 | `00 04 04 04 04 04` |
| 3 | `0x0303` | `0x8002` | 6 | `00 04 04 04 04 04` |
| 4 | `0x0403` | `0x8002` | 6 | `00 04 04 04 04 04` |
| 5 | `0x050a` | `0x8002` | 6 | `00 04 04 04 04 04` |
| 6 | `0x0000` | `0x8003` | 2 | `00 00` |

Every write shares `bmRequestType=0x40, bRequest=3, wLength=0` (the payload is entirely encoded in `wValue`/`wIndex`, no data stage); every read shares `bmRequestType=0xc0, bRequest=0, wValue=0x0000`, using the same `wIndex` as the write it follows. The fact that the read response is identical regardless of what was written suggests these reads are just status polling (not carrying meaningful returned data), but since it was genuinely unclear whether the *read itself* was needed to make the device process the preceding write, the full write+read pattern was replicated exactly rather than guessing which half was load-bearing.

---

## 9. The fix, and confirmation

Added a new function, `ddj_sz_arm_quirk()`, in `sound/usb/quirks.c`, right before `pioneer_djm_set_format_quirk()`:

```c
static void ddj_sz_arm_quirk(struct usb_device *dev)
{
	static const struct {
		u16 value;
		u16 index;
		u8 read_len;
	} cmds[] = {
		{ 0x0100, 0x8002, 6 },
		{ 0x0200, 0x8002, 6 },
		{ 0x0303, 0x8002, 6 },
		{ 0x0403, 0x8002, 6 },
		{ 0x050a, 0x8002, 6 },
		{ 0x0000, 0x8003, 2 },
	};
	u8 buf[6];
	unsigned int i;

	for (i = 0; i < ARRAY_SIZE(cmds); i++) {
		snd_usb_ctl_msg(dev, usb_sndctrlpipe(dev, 0),
			3, 0x40, cmds[i].value, cmds[i].index, NULL, 0);
		snd_usb_ctl_msg(dev, usb_rcvctrlpipe(dev, 0),
			0, 0xc0, 0x0000, cmds[i].index, buf, cmds[i].read_len);
	}
}
```

And updated the DDJ-SZ's `case` in `snd_usb_set_format_quirk()`:
```c
case USB_ID(0x08e4, 0x0191): /* Pioneer DDJ-SZ */
	ddj_sz_arm_quirk(subs->dev);
	pioneer_djm_set_format_quirk(subs, 0x0082);
	break;
```

Design note: unlike the Windows driver (which ran this once, at enumeration), this calls the arm sequence every time `snd_usb_set_format_quirk()` runs — i.e. potentially on every stream open, not just once per device plug-in. This was a deliberate simplification rather than building one-time-at-probe hook infrastructure: the six commands are cheap, synchronous control transfers, and (based on the identical response regardless of prior state) idempotent, so re-running them on every stream open is harmless even though it's more often than strictly necessary.

Module rebuilt (`M=sound/usb`, same `LOCALVERSION=` invocation), reinstalled, `depmod -a`, `modprobe -r snd_usb_audio && modprobe snd_usb_audio`. Card re-enumerated identically as `card 2: DDJSZ`.

**Capture retest**, same procedure as before but this time explicitly coordinated with a live person talking continuously into the mic for the full window:
```bash
arecord -D hw:2,0 -c 10 -f S24_3LE -r 44100 test3.wav
```
Per-channel RMS/peak analysis of the result:

| channel | RMS | peak |
|---|---|---|
| 0–3 | ~46 | ~220–250 |
| 4–7 | ~185 | ~800–880 |
| **8** | **1608.5** | **7543** |
| **9** | **1608.5** | **7543** |

Channels 8/9 — the documented Mic channels — show RMS roughly **8.7× higher** and peak roughly **8.6–9.4× higher** than the low-numbered channels, and clearly distinct from the mid-range channels 4–7 too. This is exactly the expected signature of a live voice signal landing precisely where the original Windows-driver capture said it should, and it appeared only after the arm sequence was added — it was a hard, uniform zero on an otherwise-identical test beforehand. `dmesg` showed no errors throughout.

**Result: both playback and capture are confirmed working end-to-end with real signal**, using nothing but ~125 total lines of quirk-table data and activation-sequence code layered on the existing in-tree `snd-usb-audio` driver.

---

## 10. Open items / not yet done

- **Channels 2–7 routing** (both directions) remain unmapped to specific physical ins/outs (phono/line returns, USB monitor sends). Not required for basic Master + Mic use in Mixxx; would need a dedicated capture with a distinct known signal fed into each physical input one at a time, re-analyzed the same way channels 0/1 and 8/9 were established here.
- **Mixxx integration**: package is installed (`mixxx 2.5.0`), but pointing its Sound Hardware preferences at the new ALSA device and confirming the existing MIDI mapping still operates normally through Mixxx (as opposed to just at the raw ALSA level, which is what's been tested here) requires GUI interaction and physically operating the hardware controls — left as a manual follow-up.
- **Simultaneous playback+capture** hasn't been tested (only one direction was exercised at a time). Given the implicit-feedback auto-detection noted in §7, this is the first thing to sanity-check if running both together ever produces drift, stutter, or xruns — the fix, per the original quirk-table author's own note, would be adding `USB_ENDPOINT_USAGE_IMPLICIT_FB` explicitly to the capture endpoint's `ep_attr` in `quirks-table.h`.
- **Upstreaming**: this follows the same pattern as the already-merged DJM-750/850/DDJ-SX3 quirks closely enough that it's a reasonable candidate to submit to the `alsa-devel` mailing list, per the original handoff's suggestion — not done as part of this pass.

---

## 11. Mixxx integration session (2026-08-24)

Follow-up pass connecting the working ALSA device (§1-10) to Mixxx 2.5.0 as a daily-use 4-deck setup, using the "Pioneer DDJ-SXMOD.midi.xml" mapping (an adapted DDJ-SX mapping, `~/.mixxx/controllers/`, reusing the stock `/usr/share/mixxx/controllers/Pioneer-DDJ-SX-scripts.js` script under the `PioneerDDJSX` prefix).

### Fixed

- **Master output silent + headphone monitor silent at MASTER position**: root-caused to `ddj_sz_arm_quirk()` in `sound/usb/quirks.c` (§7's "vendor status-query" replay, added after the original handoff — see the comment there predating this fix). That function blindly replays 6 fixed vendor control-transfer pairs captured from one Windows session, on every stream open, regardless of the unit's actual current physical switch/mixer state. Disabled the call (kept the function, commented out the call site at `quirks.c:1914`) and rebuilt/reloaded just `sound/usb`. This alone fixed Master output and MASTER-side headphone monitoring. Verified: ALSA-level stream was already `RUNNING` with no XRUNs and correct 10ch/S24_3LE/44100 params *before* this fix — i.e. the USB transport was never the problem, only whatever device-internal state that command sequence was setting.
  - **RETRACTED 2026-09-03 — this diagnosis was wrong.** The arm sequence does *not* break Master output. Silent output was caused by double attenuation: Mixxx's *Deck* output type applies its own software volume/crossfader before sending, so decks were faded twice (Mixxx + the DDJ-SZ's analog mixer) and hit exact digital silence at the far crossfader position. See [CUE-INVESTIGATION.md](CUE-INVESTIGATION.md) for the wire-level captures proving it. Disabling the arm sequence merely traded one broken thing for another: it killed mic capture entirely (verified — hard zeros on all 10 channels) while the real cause went unaddressed.
  - **Current state:** the call is **re-enabled**, and with the hardware-mixer Mixxx mapping in place both directions work at once — playback confirmed, and mic capture confirmed at avg 609204 / peak 3925597 on channels 8/9 versus a ~150 noise floor elsewhere. Do not disable it again; it is load-bearing for capture.
- **Channel faders 2-4 not controlling their decks / crossfader muting instead of switching**: not a MIDI/mapping bug — verified via live `aseqdump` capture that the hardware sends correct, distinct MIDI channels (raw ch 0-3 for faders 1-4, ch 6 for crossfader) exactly matching the XML's `status`/`group` table, and the bundled `PioneerDDJSX.deckFaderLSB`/`crossFaderLSB` script logic is correct and unmodified from stock. Actual cause: physical **CROSS FADER ASSIGN** switches (labeled `A THRU B`, bottom of each channel strip, above `CH FADER START`) were set inconsistently across channels. A channel assigned to a crossfader side the physical crossfader isn't currently on gets silenced regardless of its channel fader position. Fix was purely physical: set all four channels' assign switches consistently.
- **USB (A)/(B) indicator confusion**: the mixer's `USB [A] [B]` buttons (top of channels 1&3 and 2&4 respectively) are for selecting between the DDJ-SZ's two rear USB-B ports (its 2-computer back-to-back feature — confirmed against the official Basic Edition manual), not a per-channel audio-source or crosstalk indicator. Both sides showing "A" lit (orange) and "B" dark is expected/correct with only one computer connected — not an error.

### Confirmed working, not a bug

- **Channel 2-4 level meters staying dark** while audio is demonstrably present and correctly leveled (verified via matched-loudness A/B trim test against channel 1): meter-display-only quirk, not an audio-path problem. Not pursued further.
- **Per-channel TRIM**: per the manual's own setup procedure, TRIM starts fully counterclockwise (silent) per channel and must be manually brought up per channel — channels showing "no sound" after the crossfader-assign fix just hadn't had TRIM raised yet.

### Open / not yet done

- **Mic audible live but absent from recordings**: `~/.mixxx/soundconfig.xml` currently defines only one input (`Microphone`, device channels 0-1) — but §6/§9 of this doc confirmed real mic audio actually lands on capture channels **8-9**, not 0-1. The mic you hear live is very likely the DDJ-SZ's own analog hardware blend reaching the monitor path directly, independent of Mixxx; Mixxx's software Microphone input is very likely reading the wrong channel pair (0-1, probably silence/deck loopback) and thus never captures it. Fix: in Mixxx's Sound Hardware preferences, reconfigure the Microphone input to device channels 8-9 (matches soundconfig.xml's `channel` attribute = the starting frame offset). Not yet applied/tested at end of session.
- ~~**Headphone CUE monitoring silent**~~ — **SOLVED 2026-09-03, and the fix suggested here was the wrong one.** Do *not* add a `Headphones` output: there is no headphone channel pair to point it at. All ten playback channels are accounted for (four channel strips plus booth on 9-10), and pointing Mixxx's Headphones output at 9-10 just dumps cue audio out the booth jack — which is what leaked it into the speakers. Cue monitoring is handled entirely inside the hardware. The actual cause of silent cue was double attenuation: Mixxx's *Deck* output type applies its own volume and crossfader before sending, the analog mixer applies the physical controls again, and at the far crossfader position Mixxx sends digital silence, leaving the cue circuit nothing to monitor. See [CUE-INVESTIGATION.md](CUE-INVESTIGATION.md).
- ~~**Crossfader dead zone**~~ — **SOLVED 2026-09-03; same root cause as the cue bug, not a hardware fault.** The "Magvel fader needs calibration" hypothesis was wrong; the fader hardware is fine and reports its full range cleanly. Audio cut out near the end of travel because Mixxx was attenuating the deck in software *and* the analog crossfader was attenuating it again, so the combined curve reached silence early. Fixed by stopping Mixxx applying its crossfader (pin every deck's `orientation` to center).
- ~~**Channel 1 fader affecting a second deck's audible volume**~~ — **SOLVED 2026-09-03. Not analog crosstalk, and not a hardware fault.** The conclusion above ("wiring fault inside the DDJ-SZ's mixer section") followed from a correct observation and a wrong inference. At the time, Mixxx was configured with a single `Main` output on channels 1-2 — and channels 1-2 are physically wired to *channel strip 1*. So every deck's audio, already mixed together by Mixxx, arrived through strip 1 alone. Pulling strip 1's fader therefore lowered everything, deck 4 included, exactly as observed. Nothing was leaking between channels. Fixed by giving each deck its own output pair so each one reaches its own strip.

---

## Appendix: file locations

- Patched kernel source tree: `~/projects/ddj-sz-kernel` (git-tracked, checked out at commit `3152f2d6d` on top of `raspberrypi/linux` `rpi-6.18.y`, with the two files below modified — see `git diff` in that tree, or `DDJ-SZ-WRITEUP.md`'s companion diff if exported separately)
  - `sound/usb/quirks-table.h`
  - `sound/usb/quirks.c`
- Built/installed module: `/lib/modules/6.18.34+rpt-rpi-2712/kernel/sound/usb/snd-usb-audio.ko`
- Stock module backup: `/root/ddj-sz-backup/snd-usb-audio.ko.xz`
- Original research/handoff docs: `~/Downloads/ddj-sz-handoff.md`, `~/Downloads/ddj-sz-alsa-quirk.md`
- Original Windows USB capture: `~/Downloads/ddjdz.pcapng`

#TLDR
This makes Pioneer DJ DDJ-SZ work on your linux machine with mixxx

# DDJ-SZ on Linux

Full-duplex USB audio (10-channel playback + 10-channel capture, S24_3LE @
44.1kHz) for the Pioneer DDJ-SZ DJ controller on Linux, via a small patch to
the kernel's existing `snd-usb-audio` driver — not a new driver, not DKMS.

**Why this matters now:** AlphaTheta (Pioneer DJ) formally ended support for
the DDJ-SZ in their [2026 discontinuation
notice](https://downloads.support.alphatheta.com/documents/Support/Discontinuation_of_certain_supportservices_2026_en.pdf)
— "firmware and driver updates for these products are no longer available",
and "proper operation with the latest OS is not guaranteed". The same list
covers the DDJ-SZ2, DDJ-SX/SX2, DDJ-RZ and much more. When a future Windows
or macOS release breaks the vendor driver, there will be no fix. An in-kernel
quirk doesn't depend on the vendor shipping anything ever again.

The DDJ-SZ's audio interface identifies as USB vendor-specific class
(`0xFF`), so there's no out-of-box Linux support: the same situation as
Pioneer's DJM-750, DJM-850, DJM-900NXS2, DJM-450, and DJM-V10, all of which
already have quirk-table entries in mainline Linux. This does the same thing
for the DDJ-SZ.

**Status:** playback and capture both verified working with real audio (not
just clean enumeration) on a Raspberry Pi 5, Raspberry Pi OS "trixie", kernel
`6.18.34+rpt-rpi-2712`. Other Raspberry Pi OS kernel versions should work via
the same install script. Non-Raspberry-Pi kernels are untested — see
[Manual install](#manual-install) if `install.sh` refuses to run.

Read [`docs/DDJ-SZ-WRITEUP.md`](docs/DDJ-SZ-WRITEUP.md) (or the nicer
[`docs/DDJ-SZ-WRITEUP.html`](docs/DDJ-SZ-WRITEUP.html)) for the full story —
how the protocol was reverse-engineered from a USB capture of the Windows
driver, what a "quirk" actually is, and the debugging that got capture
working.

## Quick start

```bash
git clone https://github.com/hailthekid/ddj-sz-linux-audio.git
cd ddj-sz-linux-audio
./install.sh
```

This clones the matching Raspberry Pi kernel source, applies the patch,
builds just the `sound/usb` module, and installs it. It needs `sudo` for
package installation and module installation — **read the script before
running it** if you'd rather not run something blind as root.

What it does, in order:
1. Confirms your running kernel is a Raspberry Pi OS kernel it knows how to
   match (`6.18.34+rpt-rpi-2712`-shaped release string).
2. Installs build dependencies (`bc bison flex libssl-dev libncurses-dev`).
3. Clones the matching `raspberrypi/linux` release branch and finds the
   exact commit matching your installed kernel version (the branch tip
   drifts ahead of any specific release over time, so this searches history
   rather than assuming the tip matches).
4. Applies `patches/0001-ALSA-usb-audio-add-Pioneer-DJ-DDJ-SZ-support.patch`.
5. Builds just the `sound/usb` module (not a full kernel rebuild) and
   verifies the built module's vermagic matches your running kernel exactly
   before touching anything.
6. Checks nothing currently has your audio devices open, backs up the stock
   module, installs the new one, and reloads it.

Then plug in the DDJ-SZ and check:
```bash
dmesg | tail -20                                      # clean enumeration, no probe errors
aplay -l ; arecord -l                                  # look for "DDJSZ" / "DDJ-SZ"
speaker-test -D hw:X,0 -c 10 -r 44100 -F S24_3LE -l 1   # X = card number from aplay -l
arecord -D hw:X,0 -c 10 -f S24_3LE -r 44100 test.wav    # talk into the mic; ch8/9 should show signal
```
(`speaker-test -s N` picks a single channel — see
[Confirmed channel map](#confirmed-channel-map) below for what each pair is.)

`speaker-test`'s default `-t wav` mode is hardcoded to 48kHz/S16_LE and will
fail against this device regardless of `-F`/`-r` — leave it out, as above.

This install **persists across reboots** (the module file is replaced in
place under `/lib/modules/`), but a future kernel package update will
overwrite it back to stock. Re-run `install.sh` after any kernel update.

## Manual install

If `install.sh` refuses to run (non-Raspberry-Pi kernel, or its version
matching fails), the two file edits are in
[`patches/0001-...patch`](patches/0001-ALSA-usb-audio-add-Pioneer-DJ-DDJ-SZ-support.patch)
and can be applied to your own matching kernel source with `git apply` or
`patch -p1`, then built the same way any out-of-tree `sound/usb` change is
built:
```bash
ARCH=<your arch> LOCALVERSION= make modules_prepare
ARCH=<your arch> LOCALVERSION= make M=sound/usb
```
The `LOCALVERSION=` (empty, but explicitly set) matters — see
[Troubleshooting](#troubleshooting) below.

## Confirmed channel map

Figured out empirically (feeding a test tone into each pair with
`speaker-test -c 10 -s N` and watching which deck/output lit up on the
hardware), since Pioneer's manual doesn't document USB channel numbers.
Playback and capture are separate directions, so the same channel number
means different things depending on which way the audio is going.

**Playback** (host → device). This isn't a single pre-mixed stereo device:
each pair feeds one physical channel strip on the DDJ-SZ, which then applies
its own analog trim / EQ / fader / crossfader to it.

| Channels (0-indexed) | Feeds |
|---|---|
| 0-1 | Channel strip 1 (Deck 1) |
| 2-3 | Channel strip 2 (Deck 2) |
| 4-5 | Channel strip 3 (Deck 3) |
| 6-7 | Channel strip 4 (Deck 4) |
| 8-9 | Booth output |

**Capture** (device → host):

| Channels (0-indexed) | Carries |
|---|---|
| 8-9 | Mic (confirmed — avg 609204 / peak 3925597 vs a ~150 noise floor) |
| 0-7 | not confirmed; possibly line/phono returns |

Because the hardware does the mixing, whatever you send on channels 0-7
must **not** already have fader/EQ/crossfader applied to it, or it gets
processed twice. Mixxx does apply them by default — see
[Using it with Mixxx](#using-it-with-mixxx).

Master output isn't a USB channel at all — it's computed and output purely
in analog by the onboard mixer from channels 0-7, so there's nothing to
assign it to in software. The same is true for headphone cue: with all 10
channels already accounted for (4 decks + Booth), there's no channel left
for a software-computed headphone/cue send, so genuine per-channel and
master cue monitoring appears to be handled entirely inside the hardware
too — don't assign anything to "Headphones" in your DJ software's sound
routing for this device, it has nowhere valid to go and will end up on
whatever Booth Out is physically connected to instead.

Channels 2-7 were previously unconfirmed; this table supersedes that.

## Using it with Mixxx

Getting the kernel module in place is only half the job — Mixxx also has to
be told to let the DDJ-SZ's own analog mixer do the mixing, or decks get
attenuated twice (once in software, once by the physical faders) and
headphone Cue stops working at crossfader extremes.

[`mixxx/`](mixxx/) contains a mapping adapted from the community Pioneer
DDJ-SX mapping for this. Copy both files into `~/.mixxx/controllers/`, then
pick **Pioneer DDJ-SZ (hardware mixer)** in Preferences → Controllers.
Pair it with four Deck outputs in Preferences → Sound Hardware (channels
1-2, 3-4, 5-6, 7-8) and **nothing** assigned to Master, Booth, or
Headphones.

[`docs/CUE-INVESTIGATION.md`](docs/CUE-INVESTIGATION.md) explains why, and
walks through the USB captures that tracked the problem down.

## Known limitations

- **Simultaneous playback + capture** hasn't been tested. Each direction
  works on its own. Implicit feedback is handled without any quirk flag:
  `is_pioneer_implicit_fb()` in `sound/usb/implicit.c` already covers vendor
  `0x08e4` with a vendor-spec interface and two endpoints, and the driver
  reports endpoint 0x82 as the playback sync endpoint
  (`/proc/asound/cardN/stream0` shows `Implicit Feedback Mode: Yes`).
- MIDI/control-surface mapping is a separate, already-class-compliant USB
  interface and is untouched by any of this.

## Troubleshooting

**Module won't load / `modprobe` fails silently.** Check
`modinfo -F vermagic your-built.ko` against `uname -r` — they must match
*exactly*. A common cause: the kernel source checkout doesn't match your
installed kernel's exact point release, or the build picked up a stray
`+` / wrong `CONFIG_LOCALVERSION` suffix. `install.sh` checks this
automatically and refuses to install a mismatched module; if you're doing
this by hand, `LOCALVERSION=` (empty, explicitly set) on the `make`
invocation prevents an uncommitted-changes `+` suffix from breaking the
match, and `CONFIG_LOCALVERSION` in `.config` needs to be edited to match
your distro's packaging suffix, not whatever came from `/proc/config.gz`.

**Card enumerates, playback works, capture is silent.** If `arecord`
produces a file with zero-signal on every channel (not just quiet — an
exact zero) even with a live input, this was the actual bug encountered
building this patch: the DDJ-SZ needs a one-time vendor "arm" sequence
before capture works, which the shipped quirk already includes
(`ddj_sz_arm_quirk()` in `quirks.c`). If you're seeing this on a device
this patch is supposed to cover, something's wrong with your build — check
`dmesg` for the "loading out-of-tree module" line to confirm the right
module actually loaded.

## This is headed upstream too

This patch follows the same pattern as the already-merged Pioneer DJM
quirks closely enough to be a reasonable candidate for mainline Linux. See
[`docs/UPSTREAM.md`](docs/UPSTREAM.md) for status and how to help.

## License

GPL-2.0 (see [`LICENSE`](LICENSE)) — the patch is a derivative of GPL-2.0
Linux kernel source, so this isn't a choice for that part; the rest of the
repo (docs, install script) is kept under the same license for simplicity.

# DDJ-SZ on Linux

Full-duplex USB audio (10-channel playback + 10-channel capture, S24_3LE @
44.1kHz) for the Pioneer DDJ-SZ DJ controller on Linux, via a small patch to
the kernel's existing `snd-usb-audio` driver — not a new driver, not DKMS.

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
git clone https://github.com/<you>/ddj-sz-linux-audio.git
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

## Known limitations

- **Channels 2–7** (both directions) aren't mapped to specific physical
  ins/outs — only Master L/R (playback ch0/1) and Mic (capture ch8/9) are
  confirmed. Not required for basic use; PRs welcome if you isolate them.
- **Simultaneous playback + capture** hasn't been tested. ALSA auto-detects
  implicit feedback between the OUT and IN endpoints on this device even
  though the quirk table doesn't request it — if running both together
  drifts or stutters, try adding `USB_ENDPOINT_USAGE_IMPLICIT_FB` to the
  capture endpoint's `ep_attr` in `quirks-table.h`.
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

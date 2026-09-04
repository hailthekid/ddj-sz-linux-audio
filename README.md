# TLDR
Makes the Pioneer DDJ-SZ work on Linux (audio + Mixxx). Pioneer never
supported Linux, and has now [end-of-lifed the DDJ-SZ entirely](https://downloads.support.alphatheta.com/documents/Support/Discontinuation_of_certain_supportservices_2026_en.pdf)
— no more drivers, no more firmware, no OS guarantees.

Full story, reverse-engineering details, and debugging logs:
[`docs/DDJ-SZ-WRITEUP.md`](docs/DDJ-SZ-WRITEUP.md) ·
[`docs/CUE-INVESTIGATION.md`](docs/CUE-INVESTIGATION.md)

## Install (any Linux)

1. Clone this repo, and separately get a kernel source tree matching your
   running kernel exactly (`uname -r`).
2. From inside that kernel source tree, apply the patch:
   ```bash
   git apply /path/to/ddj-sz-linux-audio/patches/0001-ALSA-usb-audio-add-Pioneer-DJ-DDJ-SZ-support.patch
   ```
3. Build and install just the module (still inside the kernel tree):
   ```bash
   ARCH=<your arch> LOCALVERSION= make modules_prepare
   ARCH=<your arch> LOCALVERSION= make M=sound/usb
   sudo cp sound/usb/snd-usb-audio.ko /lib/modules/$(uname -r)/kernel/sound/usb/
   sudo depmod -a && sudo modprobe -r snd_usb_audio && sudo modprobe snd_usb_audio
   ```
4. Verify: `modinfo -F vermagic sound/usb/snd-usb-audio.ko` must exactly
   match `uname -r`, or it won't load. See
   [Troubleshooting](#troubleshooting) if it doesn't.

Then plug in the DDJ-SZ and check:
```bash
aplay -l ; arecord -l                                   # look for DDJSZ
speaker-test -D hw:X,0 -c 10 -r 44100 -F S24_3LE -l 1    # X = card number
arecord -D hw:X,0 -c 10 -f S24_3LE -r 44100 test.wav     # talk into the mic
```

### Raspberry Pi OS (automated)

```bash
git clone https://github.com/hailthekid/ddj-sz-linux-audio.git
cd ddj-sz-linux-audio
./install.sh
```
Automates the steps above for Raspberry Pi OS kernels specifically —
finds the matching `raspberrypi/linux` source, patches, builds, installs.
**Read the script before running it.** Re-run after every kernel update.

## Channel map

| Playback (host → device) | Feeds |
|---|---|
| ch 1-2 / 3-4 / 5-6 / 7-8 | Channel strips 1-4 |
| ch 9-10 | Booth output |

| Capture (device → host) | Carries |
|---|---|
| ch 9-10 | Mic |
| ch 1-8 | not yet identified |

The DDJ-SZ mixes in analog hardware, not in software — whatever you send
on ch 1-8 must **not** already have fader/EQ/crossfader applied, or it's
applied twice. Master isn't a USB channel at all. Details:
[channel map background](docs/DDJ-SZ-WRITEUP.md).

## Using it with Mixxx

Mixxx's default output type applies its own volume/crossfader before
sending — double-processing the signal and breaking headphone Cue.
[`mixxx/`](mixxx/) has a mapping that fixes this: copy both files to
`~/.mixxx/controllers/`, select **Pioneer DDJ-SZ (hardware mixer)** in
Preferences → Controllers, and set four Deck outputs (channels 1-2, 3-4,
5-6, 7-8) with nothing on Master/Booth/Headphones.

Why, and how it was found: [`docs/CUE-INVESTIGATION.md`](docs/CUE-INVESTIGATION.md).

## Troubleshooting

**Module won't load.** `modinfo -F vermagic` must exactly match `uname -r`.
Usually a kernel-source mismatch or a stray `CONFIG_LOCALVERSION`/`+dirty`
suffix — `install.sh` checks this automatically.

**Capture is exact silence, not just quiet.** The DDJ-SZ needs a vendor
"arm" sequence before capture works (`ddj_sz_arm_quirk()` in `quirks.c`,
already in the patch). If you're still seeing zeros, check `dmesg` to
confirm the patched module actually loaded.

More: [`docs/DDJ-SZ-WRITEUP.md`](docs/DDJ-SZ-WRITEUP.md).

## Upstream

Patch is submitted to the Linux kernel's ALSA maintainers — once merged,
no install step needed for anyone, ever. Status: [`docs/UPSTREAM.md`](docs/UPSTREAM.md).

## License

GPL-2.0 — see [`LICENSE`](LICENSE).

# Headphone Cue on the DDJ-SZ under Mixxx — solved

**Symptom:** with Mixxx driving the DDJ-SZ, pressing a channel's **Cue**
button only sent that deck to the headphones while the physical crossfader
sat on that channel's assigned side. Setting the channel to THRU "fixed"
Cue but removed the channel from crossfading entirely. Under Serato on the
same hardware, Cue worked from any crossfader position.

**Root cause:** Mixxx's *Deck* sound-output type is **not** a raw
pre-fader feed. Mixxx applies its own software volume and crossfader math
before sending it. Since the DDJ-SZ's analog mixer *also* applies the
physical channel fader and crossfader, every deck was being attenuated
twice — and at the far side of the crossfader Mixxx sent **exact digital
silence**, so the hardware's cue circuit had nothing left to route to the
headphones. The cue circuit was never broken; it was faithfully monitoring
silence.

**Fix:** stop Mixxx from applying volume/crossfader to deck outputs, and
let the DDJ-SZ's analog mixer own all of it. See
[Mixxx setup](#mixxx-setup-hardware-mixer-mode) below.

## The measurement that settled it

Same track, same deck, wire-level capture of the isochronous playback
endpoint (`usbmon` + tshark, decoded per channel as S24_3LE):

| Crossfader position | ch0 | ch1 | ch2-9 |
|---|---|---|---|
| Deck 1's own side | 734052 | 748589 | 0 |
| Far side ("wrong" side) | **0** | **0** | 0 |

Mixxx sends literal zeros when the crossfader is away from that deck.

## What was ruled out along the way

A ~130s USBPcap capture of Serato driving the same unit, plus local
`usbmon` captures of both the working and broken cases, ruled out:

- **The kernel quirk.** Serato negotiates the identical interface 0
  alt-setting 1, the identical six-command vendor arm sequence
  (`ddj_sz_arm_quirk()`, confirmed byte-for-byte), and the identical
  `SET_CUR` 44100 on endpoint 0x82. Local captures show Mixxx and `aplay`
  issue *exactly* the same control transfers. Same driver, same setup
  handshake, in both working and broken cases.
- **A hidden vendor command at cue time.** Only 52 control transfers exist
  in the entire Serato capture, all in the first ~30s. Nothing happens on
  the control channel when Cue is pressed.
- **A MIDI "claim the device" heartbeat.** Serato does continuously send
  `90 0c 7f / 90 0b 7f / F0 00 20 7F 50 01 F7 / 90 0c 00 / 90 0b 00` every
  ~0.5s. Replicating it exactly from a Mixxx script changed nothing. It's
  unrelated to cue.
- **Hardware fault or wear.** With no software running, `aplay` feeding the
  device directly, Cue works correctly at any crossfader position.
- **Mixxx holding the MIDI interface.** Cue works with Mixxx connected to
  MIDI while another process feeds the audio.
- **Buffer size / mmap access mode.** Reproduced Mixxx's ~5ms buffer and
  its mmap access with `aplay`; Cue still worked.
- **Capture stream / implicit feedback.** Both cases open the ISO IN
  endpoint anyway.
- **Channel assignment and Booth bleed.** `aplay` writing the same channels
  0-7 worked fine; adding a tone on channels 8-9 (which does audibly bleed
  into the main speakers here) did not break Cue either.

## Mixxx setup: hardware-mixer mode

Mixxx ships no DDJ-SZ mapping, so the community **Pioneer DDJ-SX** mapping
is the usual starting point. Out of the box it fights the hardware. A local
adapted copy lives at `~/.mixxx/controllers/`:

- `Pioneer DDJ-SZ (hardware mixer).midi.xml`
- `Pioneer-DDJ-SZ-hwmixer-scripts.js`

Changes from stock DDJ-SX:

1. **Channel faders are no-ops** (`deckFaderMSB`/`deckFaderLSB`) — the
   analog fader sets the level. (Fader-start is dropped with them, since it
   keyed off Mixxx's software volume hitting zero.)
2. **Crossfader-assign switches always set `orientation` to 1 (center)** —
   Mixxx's software crossfader never attenuates a deck; the physical
   A/THRU/B switch and analog crossfader do the real work.
3. **TRIM and HI/MID/LOW EQ knobs are no-ops too** (`gainKnobLSB`,
   `filterHighKnobLSB`, `filterMidKnobLSB`, `filterLowKnobLSB`) — the analog
   trim pot and analog EQ already do this in hardware; letting Mixxx apply
   `pregain` and its software EQ on top would gain-stage and EQ each deck
   twice, making both roughly twice as aggressive as the knob position
   suggests.
4. **`init()` pins all four decks** to `volume = 1`, `orientation = 1`,
   `pregain` flat and all three EQ bands flat (0.5) — re-asserted on a 2s
   timer.

Sound Hardware config that goes with it (`~/.mixxx/soundconfig.xml`) — four
Deck outputs, nothing else assigned:

```
Deck 1 -> channels 1-2      (ALSA ch0-1)
Deck 2 -> channels 3-4      (ALSA ch2-3)
Deck 3 -> channels 5-6      (ALSA ch4-5)
Deck 4 -> channels 7-8      (ALSA ch6-7)
```

Do **not** assign Master, Booth, or Headphones. Master is produced in
analog by the onboard mixer and isn't a USB channel; channels 9-10 (ALSA
8-9) are the **Booth** output, and anything Mixxx sends there lands on
whatever Booth Out feeds. Assigning Mixxx's "Headphones" to that pair is
what originally made cue audio leak into the speakers.

Expected consequence of this mode: Mixxx's on-screen faders, crossfader, EQ
and gain controls no longer move or do anything — the hardware owns all of
them.

## Separate minor issue: intermittent `usb_set_interface failed (-110)`

Occasionally a stream open fails with `ETIMEDOUT`
(`usb 1-2: 0:1: usb_set_interface failed (-110)`); retrying always
succeeded. Seven occurrences were logged across a long debugging session.

**Cause unknown.** Two hypotheses were tested and both disproved:

- *USB autosuspend* — ruled out. `/sys/bus/usb/devices/1-2/power/control`
  already reads `on` (autosuspend disabled for this device), so it was
  never powering down.
- *First open after an idle period* — ruled out. Six back-to-back
  open/close cycles produced no errors, and neither did a deliberate
  90-second idle followed by an open.

Not reproducible on demand as of 2026-09-03, and harmless in practice
(retry works). Left documented in case someone else hits it and finds the
trigger.

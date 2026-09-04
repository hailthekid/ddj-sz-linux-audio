# Reference links (DDJ-SZ mixer/channel routing research)

Gathered while debugging crossfader/cue behavior under Mixxx on Linux.
Fetch status noted as of 2026-09-03 — AlphaTheta has ended support for this
product, so official links may keep rotting.

## Official Pioneer / AlphaTheta

- [Discontinuation of certain support services, 2026 (PDF)](https://downloads.support.alphatheta.com/documents/Support/Discontinuation_of_certain_supportservices_2026_en.pdf) — **works**, and the single most important source here. Lists the DDJ-SZ (alongside DDJ-SZ2, DDJ-SX/SX2/SX-W, DDJ-RZ and many more) as products for which "firmware and driver updates ... are no longer available", "support for the new OS has been discontinued. Proper operation with the latest OS is not guaranteed", and bundled DJ software operation "is no longer guaranteed". This is the vendor stating on the record that these devices will not be fixed if a future OS breaks them.
- [DDJ-SZ Operating Instructions PDF](https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-sz/dri1219a.pdf) — **dead**, redirects to a generic support landing page. Doesn't document USB channel numbers even when it worked.
- [DDJ-SZ hardware diagram for Serato DJ Pro (PDF)](https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-sz/ddj-sz_hardwarediagram_serato_dj_pro_e1.pdf) — **dead**, same redirect. Would likely have shown Serato's expected switch positions.
- [Pioneer DJ Global — DDJ-SZ Documents](https://www.pioneerdj.com/en/support/documents/ddj-sz/)
- [Pioneer DJ USA — DDJ-SZ Documents (archive)](https://www.pioneerdj.com/en-us/support/documents/archive/ddj-sz/)
- [AlphaTheta Help Center — DDJ-SZ manuals](https://faq.pioneerdj.com/product.php?lang=en&p=DDJ-SZ&t=man)

## Third-party / community

- [VirtualDJ — DDJ-SZ Mixer manual page](https://virtualdj.com/manuals/hardware/pioneer/ddjsz/mixer.html) — **worked**, most useful source found. Confirms: internal hardware mixer does real analog per-channel mixing; each channel has an INPUT SELECTOR switch (LINE vs USB) choosing the audio *source* feeding that channel's analog chain; individual Cue buttons send each channel to a dedicated internal "Headphones Output channel" bus; a HEADPHONES MIXING knob blends cued channels with Master for monitoring.
- [Pioneer DJ forums — "DDJ-SZ & RekordBox DJ - Internal/External Mixer switching trouble"](https://forums.pioneerdj.com/hc/en-us/community/posts/251178723-DDJ-SZ-RekordBox-DJ-Internal-External-Mixer-switching-trouble) — **blocked (403)** from automated fetch, but the title alone suggests other owners hit similar internal/external mixer confusion. Worth reading manually in a browser.
- [Serato Support — Pioneer DJ DDJ-SZ Quickstart Guide](https://support.serato.com/hc/en-us/articles/10173712837135-Pioneer-DJ-DDJ-SZ-Quickstart-Guide) — **blocked (403)** from automated fetch. Would likely show Serato's expected switch/output configuration directly.

## The open question, resolved

The question this file was originally opened to chase — why Cue only reached
the headphones while the crossfader sat on that channel's assigned side, when
Serato had no such problem — **was answered on 2026-09-03, and none of the
links above turned out to hold the answer.**

The cause was in Mixxx, not the hardware or the vendor documentation:
Mixxx's *Deck* sound-output type applies its own software volume and
crossfader before sending, so each deck was attenuated twice (once by Mixxx,
once by the DDJ-SZ's analog mixer) and hit exact digital silence at the far
crossfader position, leaving the hardware's cue circuit nothing to monitor.
Full evidence in [CUE-INVESTIGATION.md](CUE-INVESTIGATION.md).

Two things above are worth keeping in mind for anyone reading them now:

- The VirtualDJ page's description of the internal mixer and the INPUT
  SELECTOR switches proved accurate and useful.
- The INPUT SELECTOR position (LINE vs USB) turned out to be a red herring
  for this particular problem — the switches were already on USB throughout.

## Kernel-side references

- [`sound/usb/implicit.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/sound/usb/implicit.c) — `is_pioneer_implicit_fb()` covers vendor `0x08e4` generically, which is why this device needs no `USB_ENDPOINT_USAGE_IMPLICIT_FB` flag in its quirk entry.
- [The submitted patch on lore](https://lore.kernel.org/linux-sound/20260903231641.18536-1-hhkieu@gmail.com/) — upstream submission thread.

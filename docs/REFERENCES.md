# Reference links (DDJ-SZ mixer/channel routing research)

Gathered while debugging crossfader/cue behavior under Mixxx on Linux.
Fetch status noted as of 2026-09-02 — Pioneer has archived this product, so
official links may keep rotting.

## Official Pioneer / AlphaTheta

- [DDJ-SZ Operating Instructions PDF](https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-sz/dri1219a.pdf) — **dead**, redirects to a generic support landing page. Doesn't document USB channel numbers even when it worked.
- [DDJ-SZ hardware diagram for Serato DJ Pro (PDF)](https://www.pioneerdj.com/-/media/pioneerdj/software-info/controller/ddj-sz/ddj-sz_hardwarediagram_serato_dj_pro_e1.pdf) — **dead**, same redirect. Would likely have shown Serato's expected switch positions.
- [Pioneer DJ Global — DDJ-SZ Documents](https://www.pioneerdj.com/en/support/documents/ddj-sz/)
- [Pioneer DJ USA — DDJ-SZ Documents (archive)](https://www.pioneerdj.com/en-us/support/documents/archive/ddj-sz/)
- [AlphaTheta Help Center — DDJ-SZ manuals](https://faq.pioneerdj.com/product.php?lang=en&p=DDJ-SZ&t=man)

## Third-party / community

- [VirtualDJ — DDJ-SZ Mixer manual page](https://virtualdj.com/manuals/hardware/pioneer/ddjsz/mixer.html) — **worked**, most useful source found. Confirms: internal hardware mixer does real analog per-channel mixing; each channel has an INPUT SELECTOR switch (LINE vs USB) choosing the audio *source* feeding that channel's analog chain; individual Cue buttons send each channel to a dedicated internal "Headphones Output channel" bus; a HEADPHONES MIXING knob blends cued channels with Master for monitoring.
- [Pioneer DJ forums — "DDJ-SZ & RekordBox DJ - Internal/External Mixer switching trouble"](https://forums.pioneerdj.com/hc/en-us/community/posts/251178723-DDJ-SZ-RekordBox-DJ-Internal-External-Mixer-switching-trouble) — **blocked (403)** from automated fetch, but the title alone suggests other owners hit similar internal/external mixer confusion. Worth reading manually in a browser.
- [Serato Support — Pioneer DJ DDJ-SZ Quickstart Guide](https://support.serato.com/hc/en-us/articles/10173712837135-Pioneer-DJ-DDJ-SZ-Quickstart-Guide) — **blocked (403)** from automated fetch. Would likely show Serato's expected switch/output configuration directly.

## Open question as of this writing

Channel 1's Cue only reaches headphones while the crossfader sits on that
channel's assigned side (A); setting the channel to THRU makes Cue work
from any crossfader position, but then that channel bypasses the
crossfader entirely for the main mix too. The INPUT SELECTOR switches were
confirmed already set to **USB** (not LINE), which doesn't fully explain
why Serato's Cue reportedly works independent of crossfader position on
the same physical hardware — still unresolved. See the two blocked links
above for likely answers if they can be read directly in a browser.

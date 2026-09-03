# Getting this into mainline Linux

The patch in [`patches/0001-...patch`](../patches/0001-ALSA-usb-audio-add-Pioneer-DJ-DDJ-SZ-support.patch)
follows the exact same pattern already used for the Pioneer DJM-750, DJM-850,
DJM-900NXS2, DJM-450, and DJM-V10 quirks in mainline `sound/usb/quirks.c` and
`sound/usb/quirks-table.h`. If it's merged (and backported to stable), every
future kernel simply has DDJ-SZ support built in — no install script, no
patching, for anyone, ever. That's the actual "permanent" fix.

**Status: prepared and signed off, not yet sent.** The patch carries a real
`Signed-off-by`, as the [Linux kernel's Developer Certificate of
Origin](https://www.kernel.org/doc/html/latest/process/submitting-patches.html#sign-your-work-the-developer-s-certificate-of-origin)
requires — it's a public statement that you have the right to submit this
code under the project's license, and pseudonyms are not accepted.

Both directions were re-verified on 2026-09-03 before sign-off: playback
works, and mic capture reads avg 609204 / peak 3925597 on channels 8/9
against a ~150 noise floor, with the arm sequence enabled. The commit
message's claim that capture is "verified working with real audio" is
therefore accurate as of that date.

## Sending it

1. **Find the right destination.** From a checkout of the patched tree:
   ```bash
   ./scripts/get_maintainer.pl patches/0001-ALSA-usb-audio-add-Pioneer-DJ-DDJ-SZ-support.patch
   ```
   This will list the current `sound/usb/` maintainers and the right mailing
   list(s) — almost certainly `alsa-devel@alsa-project.org`, but let the
   script confirm rather than assuming, since maintainership changes.

2. **Set up `git send-email`** (one-time):
   ```bash
   sudo apt install git-email
   git config --global sendemail.smtpserver <your mail provider's SMTP host>
   git config --global sendemail.smtpuser <you@example.com>
   ```
   GitHub's own SMTP won't work here — this has to go out from a real mail
   account, since it's a plain email to a mailing list, not a GitHub PR.

3. **Send it:**
   ```bash
   git send-email --to=alsa-devel@alsa-project.org \
     patches/0001-ALSA-usb-audio-add-Pioneer-DJ-DDJ-SZ-support.patch
   ```
   (adjust `--to` / add `--cc` per whatever `get_maintainer.pl` actually
   reported).

4. **Expect review.** Maintainers may ask questions or request changes
   before merging — that's normal for any kernel patch, not a sign
   something's wrong. Reply on-list, not by re-sending a fresh patch out of
   nowhere.

This step is intentionally left to you rather than automated — sending mail
to a public kernel mailing list under your name isn't something to do on
someone else's say-so.

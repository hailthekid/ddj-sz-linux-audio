# Getting this into mainline Linux

The patch in [`patches/0001-...patch`](../patches/0001-ALSA-usb-audio-add-Pioneer-DJ-DDJ-SZ-support.patch)
follows the exact same pattern already used for the Pioneer DJM-750, DJM-850,
DJM-900NXS2, DJM-450, and DJM-V10 quirks in mainline `sound/usb/quirks.c` and
`sound/usb/quirks-table.h`. If it's merged (and backported to stable), every
future kernel simply has DDJ-SZ support built in — no install script, no
patching, for anyone, ever. That's the actual "permanent" fix.

**Status: SENT 2026-09-03.** Submitted to the linux-sound list and both
SOUND maintainers via `git send-email` (SMTP accepted, result 250).

- Message-ID: `<20260903231641.18536-1-hhkieu@gmail.com>`
- Archive: https://lore.kernel.org/linux-sound/20260903231641.18536-1-hhkieu@gmail.com/

Awaiting review. Nothing further to do unless a maintainer replies.

Both directions were re-verified on 2026-09-03 before sign-off: playback
works, and mic capture reads avg 609204 / peak 3925597 on channels 8/9
against a ~150 noise floor, with the arm sequence enabled. The commit
message's claim that capture is "verified working with real audio" is
therefore accurate as of that date.

## If review asks for changes

Reply **on the existing thread** (keep everyone Cc'd), and send revisions
as a new version rather than a fresh submission:

```bash
# make the changes in ~/projects/alsa-sound on branch ddj-sz-support
git commit --amend
git format-patch -1 -v2 --base=HEAD~1 -o /tmp/alsa-patch/
git send-email --in-reply-to='<20260903231641.18536-1-hhkieu@gmail.com>' \
  --to=perex@perex.cz --to=tiwai@suse.com \
  --cc=linux-sound@vger.kernel.org --cc=linux-kernel@vger.kernel.org \
  /tmp/alsa-patch/v2-0001-*.patch
```

`-v2` marks it `[PATCH v2]`, and `--in-reply-to` keeps it threaded under the
original so reviewers can follow the history. Add a short note under the
`---` line summarising what changed since v1 (that text is dropped when the
patch is applied, so it won't pollute the commit message).

## Sending it

The patch in `patches/` is now a real `git format-patch` output, generated
from a commit on top of Takashi Iwai's `sound.git` `for-next` branch (the
tree ALSA patches go to), so it carries a `base-commit:` line and applies
with `git am`. It was verified against that tree, not just the Raspberry Pi
fork it was originally developed on. `checkpatch.pl` reports 0 errors and
0 warnings.

1. **Recipients**, per `scripts/get_maintainer.pl` run against the ALSA tree
   on 2026-09-03:

   | Who | Address |
   |---|---|
   | Jaroslav Kysela (maintainer) | `perex@perex.cz` |
   | Takashi Iwai (maintainer) | `tiwai@suse.com` |
   | Subsystem list | `linux-sound@vger.kernel.org` |
   | Open list | `linux-kernel@vger.kernel.org` |

   Note this is **`linux-sound@vger.kernel.org`**, not the older
   `alsa-devel@alsa-project.org` that a lot of stale documentation still
   points at. Re-run `get_maintainer.pl` before sending if much time has
   passed — maintainership and lists do change.

2. **Set up `git send-email`** (one-time):
   ```bash
   sudo apt install git-email
   git config --global sendemail.smtpserver <your mail provider's SMTP host>
   git config --global sendemail.smtpuser <you@example.com>
   ```
   This has to go out from a real mail account — it's a plain email to a
   mailing list, not a GitHub PR. The mail must be plain text, not HTML;
   `git send-email` handles that, webmail generally does not.

3. **Send it:**
   ```bash
   git send-email \
     --to=perex@perex.cz \
     --to=tiwai@suse.com \
     --cc=linux-sound@vger.kernel.org \
     --cc=linux-kernel@vger.kernel.org \
     patches/0001-ALSA-usb-audio-add-Pioneer-DJ-DDJ-SZ-support.patch
   ```

4. **Expect review.** Maintainers may ask questions or request changes
   before merging — that's normal for any kernel patch, not a sign
   something's wrong. Reply on-list, not by re-sending a fresh patch out of
   nowhere.

This step is intentionally left to you rather than automated — sending mail
to a public kernel mailing list under your name isn't something to do on
someone else's say-so.

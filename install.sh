#!/usr/bin/env bash
#
# Installs the Pioneer DDJ-SZ ALSA quirk by patching and rebuilding just the
# in-tree sound/usb kernel module -- not a new driver, not DKMS. See README.md
# for what this does and why. Tested on Raspberry Pi 5, Raspberry Pi OS
# "trixie", kernel 6.18.34+rpt-rpi-2712. Other Raspberry Pi OS kernels should
# work via the same version-matching steps below; non-Raspberry-Pi kernels are
# untested and this script will refuse to run on them.
#
# This will build a kernel module and load it with modprobe. It needs sudo.
# Read this script before running it if that makes you uneasy -- it should.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/patches/0001-ALSA-usb-audio-add-Pioneer-DJ-DDJ-SZ-support.patch"
WORK_DIR="${DDJ_SZ_WORKDIR:-$HOME/projects/ddj-sz-kernel}"
MAX_DEEPEN_STEPS=8
DEEPEN_INCREMENT=150

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

# ---------------------------------------------------------------------------
# 1. Identify the running kernel and make sure it looks like a Raspberry Pi
#    OS kernel we know how to match against upstream raspberrypi/linux.
# ---------------------------------------------------------------------------

KERNEL_RELEASE="$(uname -r)"
log "Running kernel: $KERNEL_RELEASE"

if [[ ! "$KERNEL_RELEASE" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)\+rpt-rpi- ]]; then
	die "This doesn't look like a Raspberry Pi OS kernel release string
(expected something like 6.18.34+rpt-rpi-2712). This script only knows how
to match against raspberrypi/linux release branches. See README.md for the
manual steps if you're on a different distro/kernel."
fi

KVER_MAJOR="${BASH_REMATCH[1]}"
KVER_MINOR="${BASH_REMATCH[2]}"
KVER_SUBLEVEL="${BASH_REMATCH[3]}"
RPI_BRANCH="rpi-${KVER_MAJOR}.${KVER_MINOR}.y"

log "Target branch: $RPI_BRANCH, target SUBLEVEL: $KVER_SUBLEVEL"

if [[ ! -f "/lib/modules/$KERNEL_RELEASE/build/Module.symvers" ]]; then
	die "No matching Module.symvers found at /lib/modules/$KERNEL_RELEASE/build.
Install matching headers first, e.g.:
  sudo apt install linux-headers-$KERNEL_RELEASE"
fi

# ---------------------------------------------------------------------------
# 2. Build dependencies
# ---------------------------------------------------------------------------

log "Installing build dependencies (sudo)..."
sudo apt-get update -qq
sudo apt-get install -y bc bison flex libssl-dev libncurses-dev git >/dev/null

# ---------------------------------------------------------------------------
# 3. Clone the matching branch and find the exact commit for our SUBLEVEL.
#    The branch tip drifts ahead of any specific installed kernel over time,
#    so we deepen the shallow clone incrementally until we find the most
#    recent commit whose Makefile matches our running kernel's version
#    exactly, rather than assuming the tip is what we're running.
# ---------------------------------------------------------------------------

if [[ -d "$WORK_DIR/.git" ]]; then
	log "Reusing existing clone at $WORK_DIR"
else
	log "Cloning raspberrypi/linux ($RPI_BRANCH, shallow)..."
	git clone --depth=1 --branch "$RPI_BRANCH" \
		https://github.com/raspberrypi/linux.git "$WORK_DIR"
fi

cd "$WORK_DIR"
git checkout -- . 2>/dev/null || true

find_matching_commit() {
	git log --oneline | awk '{print $1}' | while read -r hash; do
		sub="$(git show "$hash:Makefile" 2>/dev/null | awk '/^SUBLEVEL/{print $3; exit}')"
		ver="$(git show "$hash:Makefile" 2>/dev/null | awk '/^VERSION/{print $3; exit}')"
		pl="$(git show "$hash:Makefile" 2>/dev/null | awk '/^PATCHLEVEL/{print $3; exit}')"
		if [[ "$ver" == "$KVER_MAJOR" && "$pl" == "$KVER_MINOR" && "$sub" == "$KVER_SUBLEVEL" ]]; then
			echo "$hash"
			return 0
		fi
	done
	return 1
}

MATCH=""
for ((step = 1; step <= MAX_DEEPEN_STEPS; step++)); do
	log "Searching history for SUBLEVEL=$KVER_SUBLEVEL (attempt $step/$MAX_DEEPEN_STEPS)..."
	if MATCH="$(find_matching_commit)"; then
		break
	fi
	log "Not found yet, deepening clone by $DEEPEN_INCREMENT commits..."
	git fetch --deepen="$DEEPEN_INCREMENT" origin "$RPI_BRANCH" >/dev/null 2>&1 || true
done

[[ -n "$MATCH" ]] || die "Couldn't find a commit matching kernel $KVER_MAJOR.$KVER_MINOR.$KVER_SUBLEVEL
after deepening $((MAX_DEEPEN_STEPS * DEEPEN_INCREMENT)) commits of history.
Your kernel version may be too new/old for this script's search window, or
raspberrypi/linux may have changed its versioning. See README.md to do this
step by hand."

log "Matched commit: $MATCH"
git checkout "$MATCH"

# ---------------------------------------------------------------------------
# 4. Apply the patch
# ---------------------------------------------------------------------------

log "Applying DDJ-SZ quirk patch..."
git apply --check "$PATCH_FILE" || die "Patch doesn't apply cleanly to $MATCH.
The raspberrypi/linux tree may have changed around sound/usb/quirks*.
See README.md for how to apply the two edits by hand."
git apply "$PATCH_FILE"

# ---------------------------------------------------------------------------
# 5. Configure and build just the sound/usb module
# ---------------------------------------------------------------------------

log "Extracting running kernel config..."
sudo modprobe configs
zcat /proc/config.gz > .config

log "Reconciling config against this source tree..."
ARCH=arm64 make olddefconfig >/dev/null

# Match CONFIG_LOCALVERSION to the installed kernel's packaging suffix so the
# built module's vermagic matches uname -r exactly (otherwise modprobe will
# refuse to load it). The pulled config's LOCALVERSION is the raw upstream
# RPi default, not the Debian packaging suffix -- they differ.
LOCAL_SUFFIX="${KERNEL_RELEASE#"$KVER_MAJOR.$KVER_MINOR.$KVER_SUBLEVEL"}"
sed -i "s/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=\"$LOCAL_SUFFIX\"/" .config

cp "/lib/modules/$KERNEL_RELEASE/build/Module.symvers" . 2>/dev/null || true

log "Building sound/usb (this can take a few minutes)..."
# LOCALVERSION= (empty, but set) suppresses the kernel build's "+dirty-tree"
# release-string suffix, which would otherwise break vermagic matching below.
# shellcheck disable=SC1007
ARCH=arm64 LOCALVERSION= make -j"$(nproc)" modules_prepare
# shellcheck disable=SC1007
ARCH=arm64 LOCALVERSION= make -j"$(nproc)" M=sound/usb

BUILT_KO="sound/usb/snd-usb-audio.ko"
BUILT_VERMAGIC="$(modinfo -F vermagic "$BUILT_KO" | awk '{print $1}')"
if [[ "$BUILT_VERMAGIC" != "$KERNEL_RELEASE" ]]; then
	die "Built module vermagic ($BUILT_VERMAGIC) doesn't match running kernel
($KERNEL_RELEASE). Refusing to install a module that won't load. See
README.md troubleshooting section."
fi
log "Vermagic matches: $BUILT_VERMAGIC"

# ---------------------------------------------------------------------------
# 6. Pre-flight safety check before touching the live module
# ---------------------------------------------------------------------------

if lsmod | grep -q '^snd_usb_audio'; then
	if lsof /dev/snd/* 2>/dev/null | grep -q .; then
		die "snd_usb_audio is loaded and something has /dev/snd/* open.
Close whatever's using audio and re-run, or reboot first."
	fi
	warn "snd_usb_audio is currently loaded (but nothing appears to have it
open). It will be unloaded and reloaded."
fi

# ---------------------------------------------------------------------------
# 7. Install
# ---------------------------------------------------------------------------

MODDIR="/lib/modules/$KERNEL_RELEASE/kernel/sound/usb"
BACKUP_DIR="/root/ddj-sz-backup"

log "Backing up stock module to $BACKUP_DIR..."
sudo mkdir -p "$BACKUP_DIR"
if [[ -f "$MODDIR/snd-usb-audio.ko.xz" ]]; then
	sudo cp -n "$MODDIR/snd-usb-audio.ko.xz" "$BACKUP_DIR/" || true
elif [[ -f "$MODDIR/snd-usb-audio.ko" ]]; then
	sudo cp -n "$MODDIR/snd-usb-audio.ko" "$BACKUP_DIR/" || true
fi

log "Installing patched module..."
sudo rm -f "$MODDIR/snd-usb-audio.ko.xz" "$MODDIR/snd-usb-audio.ko"
sudo cp "$BUILT_KO" "$MODDIR/"
sudo depmod -a

log "Reloading snd_usb_audio..."
sudo modprobe -r snd_usb_audio 2>/dev/null || true
sudo modprobe snd_usb_audio

log "Done."
cat <<'EOF'

Installed. This persists across reboots (the module file was replaced
in place), but a future kernel package update will overwrite it back to
stock -- re-run this script after any kernel update to reinstall.

Stock module backed up at: /root/ddj-sz-backup/

Now plug in the DDJ-SZ and check:
  dmesg | tail -20                                    # clean enumeration, no probe errors
  aplay -l ; arecord -l                                # look for "DDJSZ" / "DDJ-SZ"
  speaker-test -D hw:X,0 -c 10 -r 44100 -F S24_3LE -l 1 # X = card number from aplay -l
  arecord -D hw:X,0 -c 10 -f S24_3LE -r 44100 test.wav  # talk into the mic; ch8/9 should show signal

See README.md if something doesn't look right.
EOF

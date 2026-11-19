#!/bin/sh
# Kiln GNU/Linux on Apple Silicon (Asahi).
#
#   macOS Terminal (newcomers, or adding a third OS):  curl -L https://kiln.mandrusia.tech/asahi | sh
#   Existing Asahi Linux (tri-boot from Linux):          sudo sh kiln-asahi.sh linux
#
# macOS mode runs the official Asahi installer with Kiln's OS list, so it
# handles resizing macOS, the boot stub and the m1n1/U-Boot chain. It never
# touches anything you do not confirm in its own prompts.
# Linux mode adds a Kiln root next to your existing Asahi install and a boot
# entry on the existing ESP. It defaults to a dry run.
set -eu

KILN_BASE="${KILN_BASE:-https://github.com/kilnorg/kiln-gnu-linux/releases/latest/download}"
ASAHI_CDN="${ASAHI_CDN:-https://cdn.asahilinux.org}"
INSTALLER_BASE_URL="${INSTALLER_BASE:-$ASAHI_CDN/installer}"
say() { printf '%s\n' "$*"; }
die() { printf 'kiln-asahi: %s\n' "$*" >&2; exit 1; }
ask() { printf '%s [y/N] ' "$1"; read -r a </dev/tty || a=n; [ "$a" = y ] || [ "$a" = Y ]; }

case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) mode=macos ;;
  Linux-aarch64) mode=linux ;;
  *) die "needs an Apple Silicon Mac (macOS or Asahi Linux); this is $(uname -s)-$(uname -m)" ;;
esac
[ "${1:-}" = linux ] && mode=linux
[ "${1:-}" = macos ] && mode=macos

# ---------------------------------------------------------------- macOS mode
macos_mode() {
  say "Kiln GNU/Linux for Apple Silicon"
  say "This starts the official Asahi installer with Kiln in its OS list."
  say "It can shrink macOS to make room; you confirm every step inside it."
  say "Already have Asahi Linux? Run this again: Kiln is added as another OS (tri-boot)."
  say "Back up your data first."
  ask "Continue?" || exit 0
  work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
  say "Fetching the Asahi installer..."
  curl -fL --progress-bar -o "$work/installer.tar.gz" "$INSTALLER_BASE_URL/installer-$(curl -fsSL "$INSTALLER_BASE_URL/latest").tar.gz" \
    || die "could not download the Asahi installer"
  tar -xzf "$work/installer.tar.gz" -C "$work"
  curl -fsSL -o "$work/installer_data.json" "$KILN_BASE/asahi-installer_data.json" \
    || die "could not fetch Kiln's OS list from $KILN_BASE"
  export INSTALLER_BASE="$INSTALLER_BASE_URL" REPO_BASE="$ASAHI_CDN" \
         INSTALLER_DATA="file://$work/installer_data.json" KILN_BASE
  cd "$work"
  # Asahi's own bootstrap (same as https://alx.sh): runs from macOS or recovery.
  if [ -x ./install.sh ]; then exec ./install.sh; fi
  exec python3 ./main.py
}

# ---------------------------------------------------------------- Linux mode
linux_mode() {
  [ "$(id -u)" = 0 ] || die "run as root: sudo sh kiln-asahi.sh linux"
  grep -qi apple /proc/device-tree/compatible 2>/dev/null || die "this is not an Apple Silicon machine"
  DRY=1; [ "${2:-}" = --apply ] && DRY=0
  for t in sgdisk mkfs.ext4 rsync curl unsquashfs; do command -v $t >/dev/null || die "missing tool: $t"; done
  ESP="${KILN_ESP:-$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)}"
  [ -n "$ESP" ] || die "no mounted ESP at /boot/efi (set KILN_ESP=/dev/nvme0n1pN)"
  disk="/dev/$(lsblk -no PKNAME "$ESP")"
  say "Existing Asahi found. ESP: $ESP on $disk"
  say "Free space on $disk (Kiln needs 20 GB or more):"
  sgdisk -p "$disk" | tail -n +1
  free_gb=$(parted -sm "$disk" unit GB print free 2>/dev/null | awk -F: '$1=="1" || /free/ {gsub("GB","",$4); if ($4+0>m) m=$4+0} END{print int(m)}')
  say "Largest free block: ${free_gb:-0} GB"
  [ "${free_gb:-0}" -ge 20 ] || die "not enough unpartitioned space; shrink a partition first (macOS Disk Utility or Asahi's own resize)"
  say "Plan: create a Kiln root partition in the largest free block, unpack Kiln into it,"
  say "      copy its kernel + initramfs to the ESP, and add a Kiln entry to the existing boot menu."
  if [ "$DRY" = 1 ]; then say "Dry run only. Re-run with:  sudo sh kiln-asahi.sh linux --apply"; exit 0; fi
  ask "This writes to $disk. Continue?" || exit 0
  before=$(sgdisk -p "$disk" | awk '$1~/^[0-9]+$/{n=$1} END{print n+0}')
  sgdisk -n 0:0:0 -t 0:8300 -c 0:Kiln "$disk"
  partprobe "$disk"; sleep 2
  new=$(sgdisk -p "$disk" | awk '$1~/^[0-9]+$/{n=$1} END{print n}')
  [ "$new" -gt "$before" ] || die "partition was not created"
  case "$disk" in *[0-9]) p="${disk}p${new}";; *) p="${disk}${new}";; esac
  mkfs.ext4 -L kiln-root "$p"
  mnt=/mnt/kiln-root; mkdir -p $mnt; mount "$p" $mnt
  work="$(mktemp -d)"
  say "Downloading Kiln root image..."
  curl -fL --progress-bar -o "$work/root.squashfs" "$KILN_BASE/kiln-asahi-root.squashfs" || die "download failed"
  unsquashfs -f -d $mnt "$work/root.squashfs" >/dev/null
  uuid=$(blkid -s UUID -o value "$p")
  printf 'UUID=%s / ext4 defaults,noatime 0 1\n' "$uuid" > $mnt/etc/fstab
  espuuid=$(blkid -s UUID -o value "$ESP")
  printf 'UUID=%s /boot/efi vfat umask=0077 0 2\n' "$espuuid" >> $mnt/etc/fstab
  mkdir -p /boot/efi/kiln
  cp $mnt/boot/vmlinuz-* /boot/efi/kiln/vmlinuz
  cp $mnt/boot/initrd.img-* /boot/efi/kiln/initrd.img
  cat > /etc/grub.d/45_kiln <<GRUB
#!/bin/sh
cat <<'ENTRY'
menuentry 'Kiln GNU/Linux' {
  search --no-floppy --fs-uuid --set=espdev $espuuid
  linux (\$espdev)/kiln/vmlinuz root=UUID=$uuid rw quiet
  initrd (\$espdev)/kiln/initrd.img
}
ENTRY
GRUB
  chmod +x /etc/grub.d/45_kiln
  if command -v grub2-mkconfig >/dev/null; then grub2-mkconfig -o /boot/grub2/grub.cfg
  elif command -v update-grub >/dev/null; then update-grub
  else say "Regenerate your GRUB config to see the Kiln entry."; fi
  umount $mnt; rm -rf "$work"
  say "Done. Reboot and pick 'Kiln GNU/Linux' in the boot menu (hold power for the Apple picker for macOS/Asahi)."
}

if [ "$mode" = macos ]; then macos_mode "$@"; else linux_mode "$@"; fi

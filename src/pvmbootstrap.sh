#!/bin/bash
###############################################################################
#     parabola-vmbootstrap -- create and start parabola virtual machines      #
#                                                                             #
#     Copyright (C) 2017 - 2019  Andreas Grapentin                            #
#                                                                             #
#     This program is free software: you can redistribute it and/or modify    #
#     it under the terms of the GNU General Public License as published by    #
#     the Free Software Foundation, either version 3 of the License, or       #
#     (at your option) any later version.                                     #
#                                                                             #
#     This program is distributed in the hope that it will be useful,         #
#     but WITHOUT ANY WARRANTY; without even the implied warranty of          #
#     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
#     GNU General Public License for more details.                            #
#                                                                             #
#     You should have received a copy of the GNU General Public License       #
#     along with this program.  If not, see <http://www.gnu.org/licenses/>.   #
###############################################################################

# shellcheck source=/usr/lib/libretools/messages.sh
. "$(librelib messages)"

usage() {
  print "usage: %s [-h] [-s size] [-M mirror] filename arch" "${0##*/}"
  echo
  echo  "this script is developed as part of parabola-vmbootstrap."
}

pvm_native_arch() {
  local arch
	case "$1" in
		arm*) arch=armv7l;;
		*)    arch="$1";;
	esac

  setarch "$arch" /bin/true 2>/dev/null || return
}

pvm_bootstrap() {
  msg "%s: starting image creation for %s" "$file" "$arch"

  qemu-img create -f raw "$file" "$size" || return

  trap 'pvm_cleanup' INT TERM RETURN

  local workdir loopdev
  workdir="$(mktemp -d -t pvm-rootfs-XXXXXXXXXX)" || return
  loopdev="$(sudo losetup -fLP --show "$file")" || return

  sudo dd if=/dev/zero of="$loopdev" bs=1M count=8 || return

  # partition and mount
  case "$arch" in
    i686|x86_64)
      sudo parted -s "$loopdev" \
        mklabel gpt \
        mkpart primary 1MiB 2Mib \
        set 1 bios_grub on \
        mkpart primary ext2 2MiB 514MiB \
        mkpart primary linux-swap 514MiB 4610MiB \
        mkpart primary ext4 4610MiB 100% || return

      sudo partprobe "$loopdev"

      sudo mkfs.ext2 "$loopdev"p2 || return
      sudo mkswap "$loopdev"p3 || return
      sudo mkfs.ext4 "$loopdev"p4 || return

      sudo mount "$loopdev"p4 "$workdir" || return
      sudo mkdir -p "$workdir"/boot || return
      sudo mount "$loopdev"p2 "$workdir"/boot || return
      ;;
    ppc64le|riscv64)
      sudo parted -s "$loopdev" \
        mklabel gpt \
        mkpart primary ext2 1MiB 513MiB \
        set 1 boot on \
        mkpart primary linux-swap 513MiB 4609MiB \
        mkpart primary ext4 4609MiB 100% || return

      sudo partprobe "$loopdev"

      sudo mkfs.ext2 "$loopdev"p1 || return
      sudo mkswap "$loopdev"p2 || return
      sudo mkfs.ext4 "$loopdev"p3 || return

      sudo mount "$loopdev"p3 "$workdir" || return
      sudo mkdir -p "$workdir"/boot || return
      sudo mount "$loopdev"p1 "$workdir"/boot || return
      ;;
    armv7h)
      sudo parted -s "$loopdev" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 boot on \
        mkpart primary linux-swap 513MiB 4609MiB \
        mkpart primary ext4 4609MiB 100% || return

      sudo partprobe "$loopdev"

      sudo mkfs.vfat -F 32 "$loopdev"p1 || return
      sudo mkswap "$loopdev"p2 || return
      sudo mkfs.ext4 "$loopdev"p3 || return

      sudo mount "$loopdev"p3 "$workdir" || return
      sudo mkdir -p "$workdir"/boot || return
      sudo mount "$loopdev"p1 "$workdir"/boot || return
      ;;
  esac

  # setup qemu-user-static
  if ! pvm_native_arch "$arch"; then
    # target arch can't execute natively, pacstrap is going to need help by qemu
    local qemu_arch
    case "$arch" in
      armv7h) qemu_arch=arm ;;
      *) qemu_arch="$arch" ;;
    esac

		if [[ -z $(sudo grep -l -F \
			     -e "interpreter /usr/bin/qemu-$qemu_arch-" \
			     -r -- /proc/sys/fs/binfmt_misc 2>/dev/null \
			   | xargs -r sudo grep -xF 'enabled') ]]
		then
      error "%s: missing qemu-user-static for %s" "$file" "$arch"
      return "$EXIT_FAILURE"
		fi

    sudo mkdir -p "$workdir"/usr/bin
    sudo cp -v "/usr/bin/qemu-$qemu_arch-"* "$workdir"/usr/bin || return
  fi

  # pacstrap
  local pacconf
  pacconf="$(mktemp -t pvm-pacconf-XXXXXXXXXX)" || return
  cat > "$pacconf" << EOF
[options]
Architecture = $arch
[libre]
Server = $mirror
[core]
Server = $mirror
[extra]
Server = $mirror
[community]
Server = $mirror
EOF

  local pkg=(base)

  case "$arch" in
    i686|x86_64) pkg+=(grub) ;;
  esac

  sudo pacstrap -GMcd -C "$pacconf" "$workdir" "${pkg[@]}" || return

  # finalize
  case "$arch" in
    i686|x86_64)
      # create an fstab
      sudo swapoff --all
      sudo swapon "$loopdev"p3
      genfstab -U "$workdir" | sudo tee "$workdir"/etc/fstab
      sudo swapoff "$loopdev"p3
      sudo swapon --all

      # install grub to the VM
      sudo sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX="console=tty0 console=ttyS0"/' \
        "$workdir"/etc/default/grub || return
      sudo arch-chroot "$workdir" grub-install --target=i386-pc "$loopdev" || return
      sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || return

      # regenerate the chroot-botched initcpio
      sudo cp "$workdir"/etc/mkinitcpio.d/linux-libre.preset{,.backup} || return
      echo "default_options=\"-S autodetect\"" \
        | sudo tee -a "$workdir"/etc/mkinitcpio.d/linux-libre.preset || return
      sudo arch-chroot "$workdir" mkinitcpio -p linux-libre || return
      sudo mv "$workdir"/etc/mkinitcpio.d/linux-libre.preset{.backup,} || return
      ;;
    armv7h)
      # create an fstab
      sudo swapoff --all
      sudo swapon "$loopdev"p2
      genfstab -U "$workdir" | sudo tee "$workdir"/etc/fstab
      sudo swapoff "$loopdev"p2
      sudo swapon --all
      ;;
    riscv64)
      # FIXME: for the time being, use fedora bbl to boot
      sudo wget https://fedorapeople.org/groups/risc-v/disk-images/bbl \
        -O "$workdir"/boot/bbl || return
      ;;
  esac

  pvm_cleanup
}

pvm_cleanup() {
  trap - INT TERM RETURN

  [ -n "$pacconf" ] && rm -f "$pacconf"
  unset pacconf
  if [ -n "$workdir" ]; then
    sudo rm -f "$workdir"/usr/bin/qemu-*
    sudo umount -R "$workdir"
    rmdir "$workdir"
  fi
  unset workdir
  [ -n "$loopdev" ] && sudo losetup -d "$loopdev"
  unset loopdev
}

main() {
  if [ "$(id -u)" -eq 0 ]; then
    error "This program must be run as a regular user"
    exit "$EXIT_NOPERMISSION"
  fi

  local size="64G"
  local mirror="https://repo.parabola.nu/\$repo/os/\$arch"

  # parse options
  while getopts 'hs:M:' arg; do
    case "$arg" in
      h) usage; return "$EXIT_SUCCESS";;
      s) size="$OPTARG";;
      M) mirror="$OPTARG";;
      *) usage >&2; exit "$EXIT_INVALIDARGUMENT";;
    esac
  done
  local shiftlen=$(( OPTIND - 1 ))
  shift $shiftlen
  if [ "$#" -ne 2 ]; then usage >&2; exit "$EXIT_INVALIDARGUMENT"; fi

  local file="$1"
  local arch="$2"

  # determine if the target arch is supported
  case "$arch" in
    i686|x86_64|armv7h) ;;
    ppc64le|riscv64)
      warning "%s: arch %s is experimental" "$file" "$arch";;
    *)
      error "%s: arch %s is unsupported" "$file" "$arch"
      exit "$EXIT_INVALIDARGUMENT";;
  esac

  if [ -e "$file" ]; then
    warning "%s: file exists. Continue? [y/N]" "$file"
    read -p " " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit "$EXIT_FAILURE"
    fi
    rm -f "$file" || exit
  fi

  if ! pvm_bootstrap; then
    error "%s: bootstrap failed" "$file"
    exit "$EXIT_FAILURE"
  fi
  msg "%s: bootstrap complete" "$file"
}

main "$@"

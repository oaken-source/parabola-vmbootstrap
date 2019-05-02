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
  print "usage: %s [-hO] [-s SIZE] [-M MIRROR] [-H HOOK]... IMG ARCH" "${0##*/}"
  prose "Produce preconfigured parabola GNU/Linux-libre virtual machine instances."
  echo
  prose "The produced image file is written to IMG, and is configured and
         bootstrapped for the achitecture specified in ARCH. ARCH can ether be
         one of the officially supported architectures x86_64, i686 or armv7h,
         or one of the unofficial arches ppc64le and riscv64 (refer to -M for
         custom package mirrors)"
  echo
  echo  "Supported options:"
  echo  "  -O          bootstrap an openrc system instead of a systemd one"
  echo  "  -s SIZE     Set the size of the VM image (default: 64GiB)"
  echo  "  -M MIRROR   Choose a different mirror to pacstrap from"
  echo  "                default: <https://repo.parabola.nu/\$repo/os/\$arch>"
  echo  "  -H HOOK     Enable a hook to customize the created image. This can be"
  echo  "                the path to a script, which will be executed once within"
  echo  "                the running VM, or one of the predefined hooks described"
  echo  "                below. This option can be specified multiple times."
  echo  "  -h          Display this help and exit"
  echo
  echo  "Predefined hooks:"
  echo  "  ethernet-dhcp:  configure and enable an ethernet device in the virtual"
  echo  "                  machine, using openresolv, dhcp and systemd-networkd"
  echo
  echo  "This script is part of parabola-vmbootstrap. source code available at:"
  echo  " <https://git.parabola.nu/~oaken-source/parabola-vmbootstrap.git>"
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

  # create the raw image file
  qemu-img create -f raw "$file" "$size" || return

  # prepare for cleanup
  trap 'pvm_cleanup' INT TERM RETURN

  # mount the virtual disk
  local workdir loopdev
  workdir="$(mktemp -d -t pvm-rootfs-XXXXXXXXXX)" || return
  loopdev="$(sudo losetup -fLP --show "$file")" || return

  # clean out the first 8MiB
  sudo dd if=/dev/zero of="$loopdev" bs=1M count=8 || return

  # partition
  case "$arch" in
    i686|x86_64)
      sudo parted -s "$loopdev" \
        mklabel gpt \
        mkpart primary 1MiB 2Mib \
        set 1 bios_grub on \
        mkpart primary ext2 2MiB 514MiB \
        mkpart primary linux-swap 514MiB 4610MiB \
        mkpart primary ext4 4610MiB 100% || return ;;
    armv7h)
      sudo parted -s "$loopdev" \
        mklabel gpt \
        mkpart ESP fat32 1MiB 513MiB \
        set 1 boot on \
        mkpart primary linux-swap 513MiB 4609MiB \
        mkpart primary ext4 4609MiB 100% || return ;;
    ppc64le|riscv64)
      sudo parted -s "$loopdev" \
        mklabel gpt \
        mkpart primary ext2 1MiB 513MiB \
        set 1 boot on \
        mkpart primary linux-swap 513MiB 4609MiB \
        mkpart primary ext4 4609MiB 100% || return ;;
  esac

  # refresh partition data
  sudo partprobe "$loopdev"

  # make file systems
  local swapdev
  case "$arch" in
    i686|x86_64)
      sudo mkfs.ext2 "$loopdev"p2 || return
      sudo mkswap "$loopdev"p3 || return
      sudo mkfs.ext4 "$loopdev"p4 || return
      swapdev="$loopdev"p3 ;;
    armv7h)
      sudo mkfs.vfat -F 32 "$loopdev"p1 || return
      sudo mkswap "$loopdev"p2 || return
      sudo mkfs.ext4 "$loopdev"p3 || return
      swapdev="$loopdev"p2 ;;
    ppc64le|riscv64)
      sudo mkfs.ext2 "$loopdev"p1 || return
      sudo mkswap "$loopdev"p2 || return
      sudo mkfs.ext4 "$loopdev"p3 || return
      swapdev="$loopdev"p2 ;;
  esac

  # mount partitions
  case "$arch" in
    i686|x86_64)
      sudo mount "$loopdev"p4 "$workdir" || return
      sudo mkdir -p "$workdir"/boot || return
      sudo mount "$loopdev"p2 "$workdir"/boot || return
      ;;
    armv7h|ppc64le|riscv64)
      sudo mount "$loopdev"p3 "$workdir" || return
      sudo mkdir -p "$workdir"/boot || return
      sudo mount "$loopdev"p1 "$workdir"/boot || return
      ;;
  esac

  # setup qemu-user-static, if necessary
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

  # prepare pacstrap config
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
[pcr]
Server = $mirror
EOF

  # prepare lists of packages
  local pkg=("base$init" "openssh$init" openresolv ldns)
  case "$arch" in
    i686|x86_64) pkg+=(grub) ;;
  esac
  case "$arch" in
    riscv64) ;;
    *) pkg+=("haveged$init" net-tools) ;;
  esac
  local pkg_guest_cache=(ca-certificates-utils)

  # pacstrap! :)
  sudo pacstrap -GMc -C "$pacconf" "$workdir" "${pkg[@]}" || return
  sudo pacstrap -GM -C "$pacconf" "$workdir" "${pkg_guest_cache[@]}" || return

  # create an fstab
  case "$arch" in
    riscv64) ;;
    *)
      sudo swapoff --all
      sudo swapon "$swapdev"
      genfstab -U "$workdir" | sudo tee "$workdir"/etc/fstab
      sudo swapoff "$swapdev"
      sudo swapon --all ;;
  esac

  # produce a hostname
  echo "parabola" | sudo tee "$workdir"/etc/hostname

  # produce an /etc/locale.conf
  echo "LANG=en_US.UTF-8" | sudo tee "$workdir"/etc/locale.conf
  sudo sed -i 's/#en_US.UTF-8/en_US.UTF-8/' "$workdir"/etc/locale.gen

  # install a boot loader
  case "$arch" in
    i686|x86_64)
      # enable serial console
      local field=GRUB_CMDLINE_LINUX_DEFAULT
      local value="console=tty0 console=ttyS0"
      sudo sed -i "s/.*$field=.*/$field=\"$value\"/" \
        "$workdir"/etc/default/grub || return
      # disable boot menu timeout
      local field=GRUB_TIMEOUT
      local value=0
      sudo sed -i "s/.*$field=.*/$field=$value/" \
        "$workdir"/etc/default/grub || return
      # install grub to the VM
      sudo arch-chroot "$workdir" grub-install --target=i386-pc "$loopdev" || return
      sudo arch-chroot "$workdir" grub-mkconfig -o /boot/grub/grub.cfg || return
      ;;
    riscv64)
      # FIXME: for the time being, use fedora bbl to boot
      sudo wget https://fedorapeople.org/groups/risc-v/disk-images/bbl \
        -O "$workdir"/boot/bbl || return
      ;;
    # armv7h has no boot loader.
    # FIXME: what about ppc64le
  esac

  # regenerate the initcpio, skipping the autodetect hook
  sudo cp "$workdir"/etc/mkinitcpio.d/linux-libre.preset{,.backup} || return
  echo "default_options=\"-S autodetect\"" \
    | sudo tee -a "$workdir"/etc/mkinitcpio.d/linux-libre.preset || return
  sudo arch-chroot "$workdir" mkinitcpio -p linux-libre || return
  sudo mv "$workdir"/etc/mkinitcpio.d/linux-libre.preset{.backup,} || return

  # disable audit
  sudo arch-chroot "$workdir" systemctl mask systemd-journald-audit.socket

  # initialize the pacman keyring
  sudo arch-chroot "$workdir" pacman-key --init
  sudo arch-chroot "$workdir" pacman-key --populate archlinux archlinux32 archlinuxarm parabola

  # enable the entropy daemon, to avoid stalling https
  sudo arch-chroot "$workdir" systemctl enable haveged.service

  # push hooks into the image
  sudo mkdir -p "$workdir/root/hooks"
  [ "${#hooks[@]}" -eq 0 ] || sudo cp -v "${hooks[@]}" "$workdir"/root/hooks/

  # create a master hook script
  sudo tee "$workdir"/root/hooks.sh << 'EOF'
#!/bin/bash
systemctl disable preinit.service

# generate the locale
locale-gen

# fix the mkinitcpio
mkinitcpio -p linux-libre

# fix ca-certificates
pacman -U --noconfirm /var/cache/pacman/pkg/ca-certificates-utils-*.pkg.tar.xz

# run the hooks
for hook in /root/hooks/*; do
  echo "running hook \"$hook\""
  . "$hook" || return
done

# clean up after yourself
rm -rf /root/hooks
rm -f /root/hooks.sh
rm -f /usr/lib/systemd/system/preinit.service
rm -f /var/cache/pacman/pkg/*
rm -f /root/.bash_history

# report success :)
echo "preinit hooks successful"
EOF

  # create a preinit service to run the hooks
  sudo tee "$workdir"/usr/lib/systemd/system/preinit.service << 'EOF'
[Unit]
Description=Oneshot VM Preinit
After=multi-user.target

[Service]
StandardOutput=journal+console
StandardError=journal+console
ExecStart=/usr/bin/bash /root/hooks.sh
Type=oneshot
ExecStopPost=shutdown -r now

[Install]
WantedBy=multi-user.target
EOF

  # enable the preinit service
  sudo arch-chroot "$workdir" systemctl enable preinit.service || return

  # unmount everything
  pvm_cleanup

  # boot the machine, and run the preinit scripts
  local qemu_flags=(-no-reboot)
  local pvmboot
  if [ -f "./src/pvmboot.sh" ]; then
    pvmboot=(bash ./src/pvmboot.sh)
  elif type -p pvmboot &>/dev/null; then
    pvmboot=(pvmboot)
  else
    error "%s: pvmboot not available -- unable to run hooks" "$file"
    return "$EXIT_FAILURE"
  fi

  exec 3>&1
  DISPLAY='' "${pvmboot[@]}" "$file" "${qemu_flags[@]}" \
    | tee /dev/fd/3 | grep -q "preinit hooks successful"
  local res=$?
  exec 3>&-

  if [ "$res" -ne 0 ]; then
    error "%s: failed to complete preinit hooks" "$file"
    return "$res"
  fi
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
  local hooks=()
  local init

  # parse options
  while getopts 'hOs:M:H:' arg; do
    case "$arg" in
      O) init="-openrc";;
      h) usage; return "$EXIT_SUCCESS";;
      s) size="$OPTARG";;
      M) mirror="$OPTARG";;
      H) if [ -e "/usr/lib/libretools/pvmbootstrap/hook-$OPTARG.sh" ]; then
           hooks+=("/usr/lib/libretools/pvmbootstrap/hook-$OPTARG.sh")
         elif [ -e "./src/hooks/hook-$OPTARG.sh" ]; then
           hooks+=("./src/hooks/hook-$OPTARG.sh")
         elif [ -e "$OPTARG" ]; then
           hooks+=("$OPTARG")
         else
           warning "%s: hook does not exist" "$OPTARG"
         fi ;;
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

  # determine whether the target output file already exists
  if [ -e "$file" ]; then
    warning "%s: file exists. Continue? [y/N]" "$file"
    read -p " " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
      exit "$EXIT_FAILURE"
    fi
    rm -f "$file" || exit
  fi

  # create the virtual machine
  if ! pvm_bootstrap; then
    error "%s: bootstrap failed" "$file"
    exit "$EXIT_FAILURE"
  fi

  msg "%s: bootstrap complete" "$file"
}

main "$@"

#!/bin/bash
###############################################################################
#     parabola-vmbootstrap -- create and start parabola virtual machines      #
#                                                                             #
#     Copyright (C) 2017 - 2019  Andreas Grapentin                            #
#     Copyright (C) 2019 - 2020  bill-auger                                   #
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
source "$(librelib messages)"

readonly DEF_KERNEL='linux-libre' # ASSERT: must be 'linux-libre', per 'parabola-base'
readonly DEF_RAM_MB=1000

Kernel=$DEF_KERNEL
RedirectSerial=0


usage() {
  print "USAGE:"
  print "  pvmboot [-h] [-k <kernel>] [-r] <img> [qemu-args ...]"
  echo
  prose "Determine the architecture of <img> and boot it using qemu. <img> is assumed
         to be a valid, raw-formatted parabola virtual machine image, ideally
         created using pvmbootstrap. The started instances are assigned
         ${DEF_RAM_MB}MB of RAM and one SMP core."
  echo
  prose "When a graphical desktop environment is available, start the machine
         normally, otherwise append -nographic to the qemu options. This behavior
         can be forced by unsetting DISPLAY manually, for example through:"
  echo
  echo  "  DISPLAY= ${0##*/} IMG ..."
  echo
  prose "When the architecture of IMG is compatible with the host architecture,
         append -enable-kvm to the qemu arguments."
  echo
  prose "Further arguments provided after IMG will be passed unmodified to the
         qemu invocation. This can be used to allocate more resources to the virtual
         machine, for example:"
  echo
  echo  "  ${0##*/} IMG -m 2G -smp 2"
  echo
  echo  "Supported options:"
  echo  "  -h           Display this help and exit"
  echo  "  -k <kernel>  Choose the kernel to boot, for images with no bootloader"
  echo  "               (default: $DEF_KERNEL)"
  echo  "  -r           Redirect serial console to host console, even in graphics mode"
  echo
  echo  "This script is part of parabola-vmbootstrap. source code available at:"
  echo  "  <https://git.parabola.nu/parabola-vmbootstrap.git>"
}

pvm_mount() {
  if ! file "$imagefile" | grep -q ' DOS/MBR '; then
    error "%s: does not seem to be a raw qemu image." "$imagefile"
    return "$EXIT_FAILURE"
  fi

  msg "mounting filesystems"
  trap 'pvm_umount' INT TERM EXIT

  workdir="$(mktemp -d -t pvm-XXXXXXXXXX)"           || return "$EXIT_FAILURE"
  loopdev="$(sudo losetup -fLP --show "$imagefile")" || return "$EXIT_FAILURE"
  sudo mount "$loopdev"p1 "$workdir"                 || \
  sudo mount "$loopdev"p2 "$workdir"                 || return "$EXIT_FAILURE"
}

pvm_umount() {
  trap - INT TERM EXIT

  [ -n "$workdir" ] && (sudo umount "$workdir"; rmdir "$workdir")
  [ -n "$loopdev" ] && sudo losetup -d "$loopdev"
  unset workdir
  unset loopdev
}

pvm_probe_arch() {
  local kernel

  kernel=$(find "$workdir" -maxdepth 1 -type f -iname '*vmlinu*' | head -n1)
  if [ -z "$kernel" ]; then
    warning "%s: unable to find kernel binary" "$imagefile"
    return "$EXIT_FAILURE"
  fi

  # attempt to get kernel arch from elf header
  arch="$(readelf -h "$kernel" 2>/dev/null | grep Machine | awk '{print $2}')"
  case "$arch" in
    PowerPC64) arch=ppc64   ; return "$EXIT_SUCCESS" ;;
    RISC-V   ) arch=riscv64 ; return "$EXIT_SUCCESS" ;;
    *        ) arch=""                               ;;
  esac

  # attempt to get kernel arch from objdump
  arch="$(objdump -f "$kernel" 2>/dev/null | grep architecture: | awk '{print $2}' | tr -d ',')"
  case "$arch" in
    i386  ) arch=i386   ; return "$EXIT_SUCCESS" ;;
    i386:*) arch=x86_64 ; return "$EXIT_SUCCESS" ;;
    *     ) arch=""                              ;;
  esac

  # attempt to get kernel arch from file magic
  arch="$(file "$kernel")"
  case "$arch" in
    *"ARM boot executable"*) arch=arm ; return "$EXIT_SUCCESS" ;;
    *                      ) arch=""                           ;;
  esac

  # no more ideas; giving up.
}

pvm_native_arch() {
  local arch

  case "$1" in
    arm*) arch=armv7l ;;
    *   ) arch="$1"   ;;
  esac

  setarch "$arch" /bin/true 2>/dev/null || return
}

pvm_guess_qemu_args() {
  # if we're not running on X / wayland, disable graphics
  if [ -z "$DISPLAY" ]; then qemu_args+=(-nographic);
  elif (( ${RedirectSerial} )); then qemu_args+=(-serial "mon:stdio");
  fi

  # if we're running a supported arch, enable kvm
  if pvm_native_arch "$arch"; then qemu_args+=(-enable-kvm); fi

  # find root filesystem partition (necessary for arches without bootloader)
  local root_loopdev_n=$(echo $(parted "$imagefile" print 2> /dev/null | grep ext4) | cut -d ' ' -f 1)
  local root_loopdev="$loopdev"p$root_loopdev_n
  local root_vdev=/dev/vda$root_loopdev_n
  if [[ -b "$root_loopdev" ]]
  then
      msg "found root filesystem loop device: %s" "$root_loopdev"
  else
      error "%s: unable to determine root filesystem loop device" "$imagefile"
      return "$EXIT_FAILURE"
  fi

  # set arch-specific args
  local kernel_console
  case "$arch" in
    i386|x86_64|ppc64)
      qemu_args+=(-m $DEF_RAM_MB -hda "$imagefile")
      # unmount the unneeded virtual drive early
      pvm_umount ;;
    arm)
      kernel_console="console=tty0 console=ttyAMA0 "
      qemu_args+=(-machine virt
                  -m       $DEF_RAM_MB
                  -kernel "$workdir"/vmlinuz-${Kernel}
                  -initrd "$workdir"/initramfs-${Kernel}.img
                  -append  "${kernel_console}rw root=${root_vdev}"
                  -drive   "if=none,file=${imagefile},format=raw,id=hd"
                  -device  "virtio-blk-device,drive=hd"
                  -netdev  "user,id=mynet"
                  -device  "virtio-net-device,netdev=mynet") ;;
    riscv64)
      kernel_console=$( [ -z "$DISPLAY" ] && echo "console=ttyS0 " )
      qemu_args+=(-machine virt
                  -m       $DEF_RAM_MB
                  -kernel  "$workdir"/bbl
                  -append  "${kernel_console}rw root=/dev/vda"
                  -drive   "file=${root_vdev},format=raw,id=hd0"
                  -device  "virtio-blk-device,drive=hd0"
                  -object  "rng-random,filename=/dev/urandom,id=rng0"
                  -device  "virtio-rng-device,rng=rng0"
                  -netdev  "user,id=usernet"
                  -device  "virtio-net-device,netdev=usernet") ;;
    *)
      error "%s: unable to determine default qemu args" "$imagefile"
      return "$EXIT_FAILURE" ;;
  esac
}

main() {
  if [ "$(id -u)" -eq 0 ]; then
    error "This program must be run as a regular user"
    exit "$EXIT_NOPERMISSION"
  fi

  # parse options
  while getopts 'hk:r' arg; do
    case "$arg" in
      h) usage; return "$EXIT_SUCCESS";;
      k) Kernel="$OPTARG";;
      r) RedirectSerial=1;;
      *) error "invalid argument: %s\n" "$arg"; usage >&2; exit "$EXIT_INVALIDARGUMENT";;
    esac
  done
  local shiftlen=$(( OPTIND - 1 ))
  shift $shiftlen
  local imagefile="$1"
  shift
  [ ! -n "$imagefile" ] && error "no image file specified"                 && exit "$EXIT_FAILURE"
  [ ! -e "$imagefile" ] && error "image file not found: '%s'" "$imagefile" && exit "$EXIT_FAILURE"

  msg "initializing ...."
  local workdir loopdev
  pvm_mount || exit

  local arch
  pvm_probe_arch || exit
  if [ -z "$arch" ]; then
    error "image arch is unknown: '%s'" "$arch"
    exit "$EXIT_FAILURE"
  fi

  local qemu_args=()
  pvm_guess_qemu_args || exit
  qemu_args+=("$@")

  msg "booting VM ...."
  (set -x; qemu-system-"$arch" "${qemu_args[@]}")

  # clean up the terminal, in case SeaBIOS did something weird
  echo -n "[?7h[0m"
  pvm_umount
}

main "$@"

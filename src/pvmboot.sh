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
  print "usage: %s [-h] filename [args...]" "${0##*/}"
  echo
  prose "  this script is designed to smartly boot a parabola GNU/Linux-libre
         virtual machine with qemu. It takes the path to a virtual machine image
         as parameter, and determines the architecture of that image. It sets
         default qemu parameters for the target architecture, and determines
         whether kvm acceleration is available."
  echo
  prose "  the script also determines whether a graphical desktop environment
         is available by evaluating the DISPLAY environment variable, and sets
         default options accordingly."
  echo
  prose "  the default qemu parameters can be overwritten and extended by adding
         custom arguments after the image file name."
  echo
  echo  "this script is developed as part of parabola-vmbootstrap."
}

pvm_mount() {
  if ! file "$1" | grep -q ' DOS/MBR '; then
    error "$1: does not seem to be a raw qemu image."
    return "$EXIT_FAILURE"
  fi

  trap 'pvm_umount' INT TERM EXIT

  workdir="$(mktemp -d -t pvm-XXXXXXXXXX)" || return
  loopdev="$(sudo losetup -fLP --show "$1")" || return
  sudo mount "$loopdev"p1 "$workdir" || return
}

pvm_umount() {
  trap - INT TERM EXIT

  [ -n "$workdir" ] && (sudo umount "$workdir"; rmdir "$workdir")
  unset workdir
  [ -n "$loopdev" ] && sudo losetup -d "$loopdev"
  unset loopdev
}

pvm_probe_arch() {
  local kernel
  kernel=$(find "$workdir" -maxdepth 1 -type f -iname '*vmlinu*' | head -n1)
  if [ -z "$kernel" ]; then
    warning "%s: unable to find kernel binary" "$1"
    return
  fi

  # attempt to get kernel arch from elf header
  arch="$(readelf -h "$kernel" 2>/dev/null | grep Machine | awk '{print $2}')"
  case "$arch" in
    PowerPC64) arch=ppc64; return;;
    RISC-V) arch=riscv64; return;;
    *) arch="";;
  esac

  # attempt to get kernel arch from objdump
  arch="$(objdump -f "$kernel" 2>/dev/null | grep architecture: | awk '{print $2}' | tr -d ',')"
  case "$arch" in
    i386) arch=i386; return;;
    i386:*) arch=x86_64; return;;
    *) arch="";;
  esac

  # attempt to get kernel arch from file magic
  arch="$(file "$kernel")"
  case "$arch" in
    *"ARM boot executable"*) arch=arm; return;;
    *) arch="";;
  esac

  # no more ideas; giving up.
}

pvm_native_arch() {
  local arch
	case "$1" in
		arm*) arch=armv7l;;
		*)    arch="$1";;
	esac

  setarch "$arch" /bin/true 2>/dev/null || return
}

pvm_build_qemu_args() {
  # if we're not running on X / wayland, disable graphics
  if [ -z "$DISPLAY" ]; then qemu_args+=(-nographic); fi

  # if we're running a supported arch, enable kvm
  if pvm_native_arch "$2"; then qemu_args+=(-enable-kvm); fi

  # otherwise, decide by target arch
  case "$2" in
    i386|x86_64|ppc64)
      qemu_args+=(-m 1G "$1")
      if [ -z "$DISPLAY" ]; then qemu_args+=(-append "console=ttyS0"); fi
      # unmount the drive early
      pvm_umount ;;
    arm)
      qemu_args+=(
        -machine vexpress-a9
        -cpu cortex-a9
        -m 1G
        -kernel "$workdir"/vmlinuz-linux-libre
        -dtb "$workdir"/dtbs/linux-libre/vexpress-v2p-ca9.dtb
        -initrd "$workdir"/initramfs-linux-libre.img
        -append " rw root=/dev/mmcblk0p3"
        -drive "if=sd,driver=raw,cache=writeback,file=$1")
      if [ -z "$DISPLAY" ]; then qemu_args+=(-append " console=ttyAMA0"); fi ;;
    riscv64)
      qemu_args+=(
        -machine virt
        -m 1G
        -kernel "$workdir"/bbl
        -append " rw root=/dev/vda"
        -drive "file=${loopdev}p3,format=raw,id=hd0"
        -device "virtio-blk-device,drive=hd0"
        -object "rng-random,filename=/dev/urandom,id=rng0"
        -device "virtio-rng-device,rng=rng0"
        -device "virtio-net-device,netdev=usernet"
        -netdev "user,id=usernet")
      if [ -z "$DISPLAY" ]; then qemu_args+=(-append " console=ttyS0"); fi ;;
    *)
      error "%s: unable to determine default qemu args" "$1"
      return "$EXIT_FAILURE" ;;
  esac
}

main() {
  if [ "$(id -u)" -eq 0 ]; then
    error "This program must be run as regular user"
    exit "$EXIT_NOPERMISSION"
  fi

  # parse options
  while getopts 'h' arg; do
    case "$arg" in
      h) usage; return "$EXIT_SUCCESS";;
      *) usage >&2; exit "$EXIT_INVALIDARGUMENT";;
    esac
  done
  local shiftlen=$(( OPTIND - 1 ))
  shift $shiftlen
  if [ "$#" -lt 1 ]; then usage >&2; exit "$EXIT_INVALIDARGUMENT"; fi

  local imagefile="$1"
  shift

  if [ ! -e "$imagefile" ]; then
    error "%s: file not found" "$imagefile"
    exit "$EXIT_FAILURE"
  fi

  local workdir loopdev
  pvm_mount "$imagefile" || exit

  local arch
  pvm_probe_arch "$imagefile" || exit

  if [ -z "$arch" ]; then
    error "%s: arch is unknown" "$imagefile"
    exit "$EXIT_FAILURE"
  fi

  local qemu_args=()
  pvm_build_qemu_args "$imagefile" "$arch" || exit
  qemu_args+=("$@")

  (set -x; qemu-system-"$arch" "${qemu_args[@]}")
  pvm_umount
}

main "$@"

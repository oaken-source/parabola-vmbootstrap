#!/bin/bash
 ##############################################################################
 #                         parabola-imagebuilder                              #
 #                                                                            #
 #    Copyright (C) 2017  Andreas Grapentin                                   #
 #                                                                            #
 #    This program is free software: you can redistribute it and/or modify    #
 #    it under the terms of the GNU General Public License as published by    #
 #    the Free Software Foundation, either version 3 of the License, or       #
 #    (at your option) any later version.                                     #
 #                                                                            #
 #    This program is distributed in the hope that it will be useful,         #
 #    but WITHOUT ANY WARRANTY; without even the implied warranty of          #
 #    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the           #
 #    GNU General Public License for more details.                            #
 #                                                                            #
 #    You should have received a copy of the GNU General Public License       #
 #    along with this program.  If not, see <http://www.gnu.org/licenses/>.   #
 ##############################################################################
 # this is a convenience script to start a parabola VM using qemu
 ##############################################################################

# common directories
startdir="$(pwd)"
export TOPBUILDDIR="$startdir"/build
export TOPSRCDIR="$startdir"/src
mkdir -p "$TOPBUILDDIR"
chown "$SUDO_USER" "$TOPBUILDDIR"

# shellcheck source=src/shared/common.sh
. "$TOPSRCDIR"/shared/common.sh

# sanity checks
if [ "$(id -u)" -ne 0 ]; then
  die -e "$ERROR_INVOCATION" "must be root"
fi

# shellcheck source=src/qemu.sh
. "$TOPSRCDIR"/qemu.sh

check_kernel_arch() {
  echo -n "checking for kernel name ..."
  local kernel
  kernel=$(find "$1" -maxdepth 1 -type f -iname '*vmlinu*' | head -n1)
  [ -n "$kernel" ] || kernel=no
  echo "$(basename "$kernel")"

  [ "x$kernel" != "xno" ] || return

  # check if the kernel has an elf header and extract arch

  echo -n "checking for kernel elf header ... "
  set -o pipefail
  machine=$(readelf -h "$kernel" 2>/dev/null | grep Machine | awk '{print $2}') || machine=no
  set +o pipefail
  echo "$machine"

  [ "x$machine" != "xno" ] && return

  # check if the kernel arch can be gathered from objdump

  echo -n "checking for kernel binary header ... "
  set -o pipefail
  machine=$(objdump -f "$kernel" 2>/dev/null | grep architecture: | awk '{print $2}' | tr -d ',') \
    || machine=no
  set +o pipefail
  echo "$machine"

  [ "x$machine" != "xno" ] && return

  # no usable binary headers? maybe arm?

  echo -n "checking for ARM boot executable ... "
  local is_arm=no
  file "$kernel" | grep -q 'ARM boot executable' && is_arm=yes
  echo "$is_arm"
  [ "x$is_arm" == "xyes" ] && machine=ARM

  [ "x$machine" != "xno" ] && return

  # no idea; bail.

  error "unable to extract kernel arch from image"
  return "$ERROR_MISSING"
}

qemu_setargs_arm() {
  qemu_args+=(
    -machine vexpress-a9
    -cpu cortex-a9
    -m 1G
    -kernel "$1"/vmlinuz-linux-libre
    -dtb "$1"/dtbs/linux-libre/vexpress-v2p-ca9.dtb
    -initrd "$1"/initramfs-linux-libre.img
    --append "console=ttyAMA0 rw root=/dev/mmcblk0p3"
    -drive if=sd,driver=raw,cache=writeback,file="$2"
  )
}

qemu_setargs_riscv64() {
  qemu_args+=(
    -machine virt
    -m 2G
    -kernel "$1"/bbl
    -append "console=ttyS0 rw root=/dev/vda"
    -drive file="${3}p3",format=raw,id=hd0
    -device virtio-blk-device,drive=hd0
    -object rng-random,filename=/dev/urandom,id=rng0
    -device virtio-rng-device,rng=rng0
    -device virtio-net-device,netdev=usernet
    -netdev user,id=usernet
  )
}

qemu_setargs_i386() {
    qemu_setargs_x86_64 "$@"
}

qemu_setargs_x86_64() {
  qemu_args+=(
    -m 2G
    -kernel "$1"/vmlinuz-linux-libre
    -initrd "$1"/initramfs-linux-libre.img
    -append "console=ttyS0 rw root=/dev/sda3"
    -drive file="$2"
  )
}

boot_from_image() {
  [ -f "$1" ] || die "$1: image does not exist"

  local loopdev
  qemu_img_losetup "$1" || return

  # mount the boot partition
  mkdir -p "$TOPBUILDDIR"/mnt
  mount "${loopdev}p1" "$TOPBUILDDIR"/mnt || return
  trap_add "umount -R $TOPBUILDDIR/mnt" INT TERM EXIT

  local machine
  check_kernel_arch "$TOPBUILDDIR"/mnt || return

  case "$machine" in
    RISC-V) arch=riscv64 ;;
    ARM)    arch=arm     ;;
    i386)   arch=i386    ;;
    i386:*) arch=x86_64  ;;
    *)      error "unrecognized machine '$machine'"
            return "$ERROR_UNSPECIFIED" ;;
  esac

  qemu_args=(-snapshot -nographic)
  "qemu_setargs_$arch" "$TOPBUILDDIR"/mnt "$1" "$loopdev"
  qemu_arch_is_foreign "$arch" || qemu_args+=(-enable-kvm)
  QEMU_AUDIO_DRV=none "qemu-system-$arch" "${qemu_args[@]}"
}

boot_from_image "$1" || die "boot failed"

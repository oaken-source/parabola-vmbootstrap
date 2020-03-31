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


readonly DEF_KERNEL='linux-libre' # ASSERT: must be 'linux-libre', per 'parabola-base'
readonly DEF_RAM_MB=1000

Kernel=$DEF_KERNEL
RedirectSerial=0


usage()
{
  print "USAGE:"
  print "  pvmboot [-h] [-k <kernel>] [-r] <img> [qemu-args ...]"
  echo
  prose "Determine the architecture of <img> and boot it using qemu. <img> is assumed
         to be a valid, raw-formatted parabola virtual machine image, ideally
         created using pvmbootstrap. If the image was not created using pvmbootstrap,
         the boot partition must be vfat or ext2, and the root partition must be ext4
         The machine instance is assigned ${DEF_RAM_MB}MB of RAM and one SMP core."
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


pvm_guess_qemu_cmd() # assumes: $arch , sets: $qemu_cmd
{
  case "$arch" in
    armv7h ) qemu_cmd="qemu-system-arm"                                         ;;
    i686   ) qemu_cmd="qemu-system-i386"                                        ;;
    ppc64le) qemu_cmd="qemu-system-ppc64"                                       ;;
    riscv64) qemu_cmd="qemu-system-riscv64"                                     ;;
    x86_64 ) qemu_cmd="qemu-system-x86_64"                                      ;;
    *      ) error "unknown image arch: '%s'" "$arch" ; return "$EXIT_FAILURE"  ;;
  esac
}

pvm_guess_qemu_args() # assumes: $qemu_args $imagefile $arch $bootdir , appends: $qemu_args
{
  msg "configuring the virtual machine ($arch)"

  qemu_args+=(-m $DEF_RAM_MB )

  # optional large qemu disk
  qemu_args+=( $( [[ -w $DATA_IMG ]] && echo "-hdb $DATA_IMG" ) )

  # if we're not running on X / wayland, disable graphics
  if [ -z "$DISPLAY" ]; then qemu_args+=(-nographic);
  elif (( ${RedirectSerial} )); then qemu_args+=(-serial "mon:stdio");
  fi

  # find root filesystem partition
  local root_part_n
  pvm_find_root_part_n "$imagefile" || return "$EXIT_FAILURE" # sets: $root_part_n

  # if we're running a supported arch, enable kvm
  if pvm_native_arch "$arch"; then qemu_args+=(-enable-kvm); fi

  # set arch-specific args
  local kernel_tty
  case "$arch" in
    armv7h ) kernel_tty="console=tty0 console=ttyAMA0 "                   ;;
    i686   ) kernel_tty=$( [[ -z "$DISPLAY" ]] && echo "console=ttyS0 " ) ;;
    ppc64le)                                                              ;; # TODO:
    riscv64)                                                              ;; # TODO:
    x86_64 ) kernel_tty=$( [[ -z "$DISPLAY" ]] && echo "console=ttyS0 " ) ;;
  esac
  case "$arch" in
    armv7h ) qemu_args+=(-machine virt
                         -kernel  "$bootdir"/vmlinuz-${Kernel}
                         -initrd  "$bootdir"/initramfs-${Kernel}.img
                         -append  "${kernel_tty}rw root=/dev/vda$root_part_n"
                         -drive   "if=none,file=${imagefile},format=raw,id=hd"
                         -device  "virtio-blk-device,drive=hd"
                         -netdev  "user,id=mynet"
                         -device  "virtio-net-device,netdev=mynet")            ;;
    i686   ) qemu_args+=(-hda     "$imagefile")                                ;;
    ppc64le) qemu_args+=(-hda "   $imagefile")                                 ;;
    riscv64) qemu_args+=(-machine virt
                         -kernel  "$bootdir"/bbl
                         -append  "${kernel_tty}rw root=/dev/vda"
                         -drive   "file=/dev/vda$root_part_n,format=raw,id=hd0"
                         -device  "virtio-blk-device,drive=hd0"
                         -object  "rng-random,filename=/dev/urandom,id=rng0"
                         -device  "virtio-rng-device,rng=rng0"
                         -netdev  "user,id=usernet"
                         -device  "virtio-net-device,netdev=usernet")          ;;
    x86_64 ) qemu_args+=(-hda     "$imagefile")                                ;;
  esac
}

main() # ( [cli_options] imagefile qemu_args )
{
  pvm_check_unprivileged # exits on failure

  # parse options
  while getopts 'hk:r' arg; do
    case "$arg" in
      h) usage; return "$EXIT_SUCCESS"                                                  ;;
      k) Kernel="$OPTARG"                                                               ;;
      r) RedirectSerial=1                                                               ;;
      *) error "invalid argument: %s\n" "$arg"; usage >&2; exit "$EXIT_INVALIDARGUMENT" ;;
    esac
  done
  local shiftlen=$(( OPTIND - 1 )) ; shift $shiftlen ;
  local imagefile="$1"             ; shift           ;
  local cli_args=$@
  [ ! -n "$imagefile" ] && error "no image file specified"                  && exit "$EXIT_FAILURE"
  [ ! -e "$imagefile" ] && error "image file not found: '%s'"  "$imagefile" && exit "$EXIT_FAILURE"
  [ ! -w "$imagefile" ] && error "image file not writable: %s" "$imagefile" && exit "$EXIT_FAILURE"

  msg "initializing ...."
  local bootdir workdir loopdev
  local arch
  local qemu_cmd
  local qemu_args=()
  local was_error
  pvm_mount           || exit "$EXIT_FAILURE" # assumes: $imagefile , sets: $loopdev $bootdir $workdir
  pvm_probe_arch      || exit "$EXIT_FAILURE" # assumes: $bootdir $workdir $imagefile , sets: $arch
  pvm_guess_qemu_cmd  || exit "$EXIT_FAILURE" # assumes: $arch , sets: $qemu_cmd
  pvm_guess_qemu_args || exit "$EXIT_FAILURE" # assumes: $qemu_args $imagefile $arch $bootdir , appends: $qemu_args

  # unmount the virtual disks early, for images with a bootloader
  [[ "$arch" =~ ^i686$|^x86_64$|^ppc64le$ ]] && pvm_cleanup

  msg "booting the virtual machine ...."
  (set -x; $qemu_cmd "${qemu_args[@]}" $cli_args) ; was_error=$? ;

  # clean up the terminal, in case SeaBIOS did something weird
  echo -n "[?7h[0m"
  pvm_cleanup

  (( ! $was_error )) && exit "$EXIT_SUCCESS" || exit "$EXIT_FAILURE"
}


if   source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")"/pvm-common.sh.inc 2> /dev/null || \
     source /usr/lib/parabola-vmbootstrap/pvm-common.sh.inc                     2> /dev/null
then main "$@"
else echo "can not find pvm-common.sh.inc" && exit 1
fi

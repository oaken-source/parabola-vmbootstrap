#!/bin/bash
 ##############################################################################
 #                         parabola-imagebuilder                              #
 #                                                                            #
 #    Copyright (C) 2018  Andreas Grapentin                                   #
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

qemu_img_partition_and_mount_for_armv7h() {
  parted -s "$1" \
    mklabel gpt \
    mkpart ESP fat32 1MiB 513MiB \
    set 1 boot on \
    mkpart primary linux-swap 513MiB 4609MiB \
    mkpart primary ext4 4609MiB 100% || return

  check_exe -r mkfs.vfat mkfs.ext4

  mkfs.vfat -F 32 "${1}p1"
  mkswap "${1}p2"
  mkfs.ext4 "${1}p3"

  mkdir -p "$2"
  mount "${1}p3" "$2" || return
  trap_add "umount -R $2" INT TERM EXIT
  mkdir -p "$2"/boot
  mount "${1}p1" "$2"/boot || return
}

qemu_img_partition_and_mount_for_riscv64() {
  qemu_img_partition_and_mount_for_x86_64 "$@"
}

qemu_img_partition_and_mount_for_powerpc64le() {
  qemu_img_partition_and_mount_for_x86_64 "$@"
}

qemu_img_partition_and_mount_for_i686() {
  qemu_img_partition_and_mount_for_x86_64 "$@"
}

qemu_img_partition_and_mount_for_x86_64() {
  parted -s "$1" \
    mklabel gpt \
    mkpart primary ext2 1MiB 513MiB \
    set 1 boot on \
    mkpart primary linux-swap 513MiB 4609MiB \
    mkpart primary ext4 4609MiB 100% || return

  check_exe mkfs.ext2 mkfs.ext4

  mkfs.ext2 "${1}p1"
  mkswap "${1}p2"
  mkfs.ext4 "${1}p3"

  mkdir -p "$2"
  mount "${1}p3" "$2" || return
  trap_add "umount -R $2" INT TERM EXIT
  mkdir -p "$2"/boot
  mount "${1}p1" "$2"/boot || return
}

qemu_img_losetup() {
  echo -n "checking for free loop device ... "
  loopdev=$(losetup -f --show "$1") || loopdev=no
  echo "$loopdev"
  partprobe "$loopdev"

  [ "x$loopdev" == "xno" ] && return "$ERROR_MISSING"

  trap_add "qemu_img_lorelease $loopdev" INT TERM EXIT
}

qemu_img_lorelease() {
  losetup -d "$1"
}

qemu_arch_is_foreign() {
  # borrowed from /usr/bin/librechroot
  local setarch
	case "$1" in
		arm*) setarch=armv7l  ;;
		*)    setarch="$1"    ;;
	esac

  echo -n "checking if arch '$1' is foreign ... "
  local need_qemu=no
  setarch "$setarch" /bin/true 2>/dev/null || need_qemu=yes
  echo "$need_qemu"

  [ "x$need_qemu" == "xyes" ] || return
}

qemu_setup_user_static() {
	local interpreter
	case "$ARCH" in
		armv7h)       interpreter=/usr/bin/qemu-arm-     ;;
    powerpc64le)  interpreter=/usr/bin/qemu-ppc64le- ;;
		*)            interpreter=/usr/bin/qemu-"$ARCH"- ;;
	esac

	if qemu_arch_is_foreign "$ARCH"; then
    # target arch can't execute natively, pacstrap is going to need help by qemu
		if [[ -z $(grep -l -F \
			     -e "interpreter $interpreter" \
			     -r -- /proc/sys/fs/binfmt_misc 2>/dev/null \
			   | xargs -r grep -xF 'enabled') ]]
		then
      error "unable to continue - need qemu-user-static for $ARCH"
      return "$ERROR_MISSING"
		fi

    mkdir -p "$1"/usr/bin
    cp -v "$interpreter"* "$1"/usr/bin || return
    trap_add "qemu_cleanup_user_static $1"
  fi
}

qemu_cleanup_user_static() {
  rm -f "$1"/usr/bin/qemu-*
}

qemu_img_finalize_for_armv7h() {
  true
}

qemu_img_finalize_for_riscv64() {
  # for the time being, use fedora bbl to boot
  wget https://fedorapeople.org/groups/risc-v/disk-images/bbl \
    -O "$1"/boot/bbl
}

qemu_img_finalize_for_powerpc64le() {
  true
}

qemu_img_finalize_for_i686() {
  true
}

qemu_img_finalize_for_x86_64() {
  true
}

qemu_make_image() {
  msg "preparing parabola qemu image for $ARCH"

  # skip, if already exists
  check_file "$1" && return

  check_exe -r parted

  # write to preliminary file
  local tmpfile="$1.part"
  rm -f "$tmpfile"

  # create an empty image
  qemu-img create -f raw "$tmpfile" "$2" || return

  # create a minimal pacman.conf
  cat > "$TOPBUILDDIR/pacman.conf.$ARCH" << EOF
[options]
Architecture = $ARCH
[libre]
Server = $MIRROR
[core]
Server = $MIRROR
[extra]
Server = $MIRROR
[community]
Server = $MIRROR
EOF

  # setup the image (in a subshell for trap management)
  (
    loopdev=''
    qemu_img_losetup "$tmpfile" || return

    dd if=/dev/zero of="$loopdev" bs=1M count=8 || return
    "qemu_img_partition_and_mount_for_$ARCH" "$loopdev" "$TOPBUILDDIR"/mnt || return

    qemu_setup_user_static "$TOPBUILDDIR"/mnt || return

    pacstrap -GMcd -C "$TOPBUILDDIR/pacman.conf.$ARCH" "$TOPBUILDDIR"/mnt || return

    "qemu_img_finalize_for_$ARCH" "$TOPBUILDDIR"/mnt || return
  ) || return

  mv "$tmpfile" "$1"
}

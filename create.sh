#!/bin/bash

set -eu

# this script prepares an archlinuxarm image for use with start.sh

OUTFILE=${OUTFILE:-armv7h.raw}
SIZE=${SIZE:-64G}

_builddir=build
_outfile=$_builddir/$(basename $OUTFILE)

mkdir -p $_builddir

# create an empty image
rm -f $_outfile
qemu-img create -f raw $_outfile $SIZE

# setup an available loop device
_loopdev=$(losetup -f --show $_outfile)

# setup an error exit handler for cleanup
function cleanup {
  echo "exiting due to earlier errors..." >&2
  for part in p1 p2; do
    umount $_loopdev$part || true
  done
  losetup -d $_loopdev || true
  rm -rf $_builddir/boot $_builddir/root
  rm -f $_outfile
}
trap cleanup ERR

# fetch latest archlinuxarm tarball
wget -nc http://os.archlinuxarm.org/os/ArchLinuxARM-armv7-latest.tar.gz

# following are the installation instructions provided on
# https://archlinuxarm.org/platforms/armv7/arm/versatile-express
dd if=/dev/zero of=$_loopdev bs=1M count=8
parted -s $_loopdev \
  mklabel gpt \
  mkpart ESP fat32 1MiB 513MiB \
  set 1 boot on \
  mkpart primary ext4 513MiB 100%
mkfs.vfat -F 32 ${_loopdev}p1
mkdir -p $_builddir/boot
mount ${_loopdev}p1 $_builddir/boot
mkfs.ext4 ${_loopdev}p2
mkdir $_builddir/root
mount ${_loopdev}p2 $_builddir/root
bsdtar -vxpf ArchLinuxARM-armv7-latest.tar.gz -C $_builddir/root
sync
mv -v $_builddir/root/boot/* $_builddir/boot
cat >> $_builddir/root/etc/fstab << EOF
/dev/mmcblk0p1  /boot   vfat    defaults        0       0
EOF

# tie up any loose ends
for part in p1 p2; do
  umount $_loopdev$part
done
losetup -d $_loopdev
mv -v $_outfile $OUTFILE
rm -rf $_builddir

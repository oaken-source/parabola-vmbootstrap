#!/bin/bash

set -eu

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
wget -nc http://os.archlinuxarm.org/os/$ARCHTARBALL

# the following installation instructions are taken from
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
bsdtar -vxpf $ARCHTARBALL -C $_builddir/root
sync
mv -v $_builddir/root/boot/* $_builddir/boot
cat >> $_builddir/root/etc/fstab << EOF
/dev/mmcblk0p1  /boot   vfat    defaults        0       0
EOF

# create and install root ssh keys for access
mkdir -p keys
test -f keys/id_rsa || ssh-keygen -N '' -f keys/id_rsa
chown $(logname) keys/id_rsa*
mkdir -m 700 $_builddir/root/root/.ssh
install -m 600 -o 0 -g 0 keys/id_rsa.pub $_builddir/root/root/.ssh/authorized_keys

# create and install ssh host keys
for cipher in dsa ecdsa ed25519 rsa; do
  if [ ! -f keys/ssh_host_${cipher}_key ]; then
    ssh-keygen -N '' -t ${cipher} -f keys/ssh_host_${cipher}_key
  fi
  install -m 600 -o 0 -g 0 keys/ssh_host_${cipher}_key $_builddir/root/etc/ssh
  install -m 644 -o 0 -g 0 keys/ssh_host_${cipher}_key.pub $_builddir/root/etc/ssh
done

# tie up any loose ends
for part in p1 p2; do
  umount $_loopdev$part
done
losetup -d $_loopdev
rm -rf $_builddir/boot $_builddir/root

#!/bin/bash

set -eu

_builddir=build
mkdir -p $_builddir

_imagefile=$1
_pidfile=$_builddir/qemu.pid

_loopdev=$(sudo losetup -f --show $_imagefile)
_bootdir=.boot

# register a cleanup error handler
function cleanup {
  test -f $_pidfile && (sudo kill -9 $(cat $_pidfile) || true)
  rm -f $_pidfile
  sudo umount ${_loopdev}p1
  sudo losetup -d $_loopdev
  rm -rf $_bootdir
}
trap cleanup ERR

# start the VM
mkdir -p $_bootdir
sudo mount ${_loopdev}p1 $_bootdir
QEMU_AUDIO_DRV=none qemu-system-arm \
  -M vexpress-a9 \
  -m 1G \
  -dtb $_bootdir/dtbs/vexpress-v2p-ca9.dtb \
  -kernel $_bootdir/zImage \
  --append "root=/dev/mmcblk0p2 rw roottype=ext4 console=ttyAMA0" \
  -drive if=sd,driver=raw,cache=writeback,file=$_imagefile \
  -display none \
  -net user,hostfwd=tcp::2022-:22 \
  -net nic \
  -daemonize \
  -snapshot \
  -pidfile $_pidfile

# wait for ssh to be up
_sshopts="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
while ! ssh -p 2022 -i keys/id_rsa root@localhost $_sshopts true 2>/dev/null; do
  echo -n . && sleep 5
done && echo

# open a session
ssh -p 2022 -i keys/id_rsa parabola@localhost

# shutdown the VM
ssh -p 2022 -i keys/id_rsa root@localhost "nohup shutdown -h now &>/dev/null & exit"
while sudo kill -0 $(cat $_pidfile) 2> /dev/null; do echo -n . && sleep 5; done && echo
rm -f $_pidfile

# cleanup
sudo umount ${_loopdev}p1
sudo losetup -d $_loopdev
rm -rf $_bootdir

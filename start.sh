#!/bin/bash

IMAGE=${IMAGE:-armv7h.raw}

_loopdev=$(sudo losetup -f --show $IMAGE)
_bootdir=.boot

function cleanup {
  sudo umount ${_loopdev}p1
  sudo losetup -d $_loopdev
  rm -rf $_bootdir
}
trap cleanup EXIT

mkdir -p $_bootdir
sudo mount ${_loopdev}p1 $_bootdir

qemu-system-arm \
  -M vexpress-a9 \
  -dtb $_bootdir/dtbs/vexpress-v2p-ca9.dtb \
  -kernel $_bootdir/zImage \
  --append "root=/dev/mmcblk0p2 rw roottype=ext4 console=ttyAMA0" \
  -drive if=sd,driver=raw,cache=writeback,file=$IMAGE \
  --nographic \
  -snapshot

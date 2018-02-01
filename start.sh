#!/bin/bash
 ##############################################################################
 #                       parabola-arm-imagebuilder                            #
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

set -eu

_builddir=build
mkdir -p "$_builddir"

_imagefile=$1
_pidfile="$_builddir"/qemu-$$.pid
_bootdir="$_builddir"/boot-$$

_loopdev=$(sudo losetup -f --show "$_imagefile")
sudo partprobe $_loopdev
touch "$_pidfile"

# register a cleanup error handler
function cleanup {
  test -f "$_pidfile" && (sudo kill -9 $(cat "$_pidfile") || true)
  rm -f "$_pidfile"
  sudo umount ${_loopdev}p1
  sudo losetup -d $_loopdev
  rm -rf "$_bootdir"
}
trap cleanup ERR

# start the VM
mkdir -p "$_bootdir"
sudo mount ${_loopdev}p1 "$_bootdir"
_board="vexpress-a9"
# FIXME: archlinuxarm rust SIGILLs on cortex-a9 cpus, using cortex-a15 for now
_cpu="cortex-a15"
_memory="1G"
_snapshot=""
[ -z "${PERSISTENT:-}" ] && _snapshot="-snapshot"
_daemonize="-nographic -serial mon:stdio"
[ -z "${FOREGROUND:-}" ] && _daemonize="-daemonize -pidfile \"$_pidfile\" -net user,hostfwd=tcp::2022-:22 -net nic -display none"
if [ -f "$_bootdir"/zImage ]; then
  _kernel="$_bootdir"/zImage
  _dtb="$_bootdir"/dtbs/vexpress-v2p-ca9.dtb
  _initrd="$_bootdir"/initramfs-linux.img
else
  _kernel="$_bootdir"/vmlinuz-linux-libre
  _dtb="$_bootdir"/dtbs/linux-libre/vexpress-v2p-ca9.dtb
  _initrd="$_bootdir"/initramfs-linux-libre.img
fi
QEMU_AUDIO_DRV=none qemu-system-arm \
  -M $_board \
  -cpu $_cpu \
  -m $_memory \
  -kernel "$_kernel" \
  -dtb "$_dtb" \
  -initrd "$_initrd" \
  --append "root=/dev/mmcblk0p3 rw roottype=ext4 console=ttyAMA0" \
  -drive if=sd,driver=raw,cache=writeback,file="$_imagefile" \
  $_daemonize \
  $_snapshot

if [ -z "${FOREGROUND:-}" ]; then
  # wait for ssh to be up
  _sshopts="-o StrictHostKeyChecking=no -o ConnectTimeout=5"
  while ! ssh -p 2022 -i keys/id_rsa root@localhost $_sshopts true 2>/dev/null; do
    echo -n . && sleep 5
  done && echo

  # open a session
  ssh -p 2022 -i keys/id_rsa parabola@localhost

  # shutdown the VM
  ssh -p 2022 -i keys/id_rsa root@localhost "nohup shutdown -h now &>/dev/null & exit"
  while sudo kill -0 $(cat "$_pidfile") 2> /dev/null; do echo -n . && sleep 5; done && echo
fi

# cleanup
sudo umount ${_loopdev}p1
sudo losetup -d $_loopdev
rm -rf "$_bootdir" "$_pidfile"

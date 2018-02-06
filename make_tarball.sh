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

die() { echo "$*" 1>&2 ; exit 1; }

[ $(id -u) -ne 0 ] && die "must be root"

_builddir=build
mkdir -p "$_builddir"

_imagefile="$_builddir/$(basename "$1")"
cp $1 $_imagefile
_rootdir="$_builddir"/root-$$

_loopdev=$(sudo losetup -f --show "$_imagefile")
sudo partprobe $_loopdev

# register a cleanup error handler
function cleanup {
  sudo umount ${_loopdev}p1
  sudo umount ${_loopdev}p3
  sudo losetup -d $_loopdev
  rm -rf "$_rootdir" "$_imagefile"
}
trap cleanup ERR

# mount the image
mkdir -p "$_rootdir"
sudo mount ${_loopdev}p3 "$_rootdir"
sudo mount ${_loopdev}p1 "$_rootdir"/boot

# clean the image
rm -fvr \
  "$_rootdir"/root/.ssh \
  "$_rootdir"/etc/ssh/ssh_host_* \
  "$_rootdir"/var/log/* \
  "$_rootdir"/var/cache/* \
  "$_rootdir"/lost+found

# create the tarball
tar -czf ParabolaARM-armv7-$(date "+%Y-%m-%d").tar.gz -C "$_rootdir" .

# cleanup
sudo umount ${_loopdev}p1
sudo umount ${_loopdev}p3
sudo losetup -d $_loopdev
rm -rf "$_rootdir" "$_imagefile"

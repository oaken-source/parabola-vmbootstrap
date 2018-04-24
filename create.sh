#!/bin/bash
 ##############################################################################
 #                         parabola-imagebuilder                              #
 #                                                                            #
 #    Copyright (C) 2017, 2018  Andreas Grapentin                             #
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

# target options
export ARCH="${ARCH:-armv7h}"
export SIZE="${SIZE:-64G}"
export MIRROR="${MIRROR:-https://redirector.parabola.nu/\$repo/os/\$arch}"

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

qemu_make_image "$TOPBUILDDIR/parabola-$ARCH.img" "$SIZE" \
  || die "failed to prepare qemu base image"

msg "all done."

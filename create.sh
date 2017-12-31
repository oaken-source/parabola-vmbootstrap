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

# this script prepares an armv7h parabola image for use with start.sh

export OUTFILE=${OUTFILE:-armv7h.img}
export SIZE=${SIZE:-64G}
export ARCHTARBALL=${ARCHTARBALL:-ArchLinuxARM-armv7-latest.tar.gz}

export _builddir=build
mkdir -p $_builddir
chown $(logname):$(logname) $_builddir

export _outfile=$_builddir/$(basename $OUTFILE)

# prepare the empty image
./src/stage0.sh

# install a clean archlinuxarm in the empty image
./src/stage1.sh

# migrate the installed image to a clean parabola
./src/stage2.sh

# setup package development environment
./src/stage3.sh

# cleanup
chown $(logname) $_outfile
mv -v $_outfile $OUTFILE
rm -rf $_builddir

echo "all done :)"

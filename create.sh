#!/bin/bash

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

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
set -x

die() { echo "$*" 1>&2 ; exit 1; }

_tarball=$1

# parse date from tarball
_date=$(echo "${_tarball%.tar.gz}" | rev | cut -d'-' -f1-3 | rev)

# create checksums
sha512sum $_tarball > SHA512SUMS
whirlpool-hash $_tarball > WHIRLPOOLSUMS

# sign tarball and checksum
gpg --detach-sign $_tarball
gpg --detach-sign SHA512SUMS
gpg --detach-sign WHIRLPOOLSUMS

# upload tarball and checksum
_repopath="/srv/repo/main/iso/arm/$_date"
ssh repo@repo "mkdir -p $_repopath"
scp $_tarball{,.sig} SHA512SUMS{,.sig} WHIRLPOOLSUMS{,.sig} repo@repo:$_repopath/

# update LATEST symlinks
ssh repo@repo "mkdir -p $_repopath/../LATEST"
for f in $_tarball{,.sig} SHA512SUMS{,.sig} WHIRLPOOLSUMS{,.sig}; do
  ssh repo@repo "ln -fs ../$_date/$f $_repopath/../LATEST/$(echo $f | sed "s/$_date/LATEST/g")"
done

# cleanup
rm -rf $_tarball.sig SHA512SUMS{,.sig} WHIRLPOOLSUMS{,.sig}

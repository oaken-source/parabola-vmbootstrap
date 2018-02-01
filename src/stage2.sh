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

_scriptfile="$_builddir"/migrate.sh
_pidfile="$_builddir"/qemu-$$.pid
_bootdir="$_builddir"/boot-$$

_loopdev=$(sudo losetup -f --show $_outfile)

# register cleanup handler to stop the started VM
function cleanup {
  test -f "$_pidfile" && (kill -9 $(cat "$_pidfile") || true)
  rm -f "$_pidfile"
  umount ${_loopdev}p1
  losetup -d $_loopdev
  rm -rf "$_bootdir"
  rm -f "$_scriptfile"
}
trap cleanup ERR

# create the migration script, adapted from
# https://wiki.parabola.nu/Migration_from_Arch_ARM
cat > "$_scriptfile" << 'EOF'
#!/bin/bash

set -eu

# install the keyrings and mirrorlist
sed -i 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf
pacman --noconfirm -U https://www.parabola.nu/packages/libre/any/parabola-keyring/download/
pacman --noconfirm -U https://www.parabola.nu/packages/libre/any/archlinux32-keyring/download/
pacman --noconfirm -U https://www.parabola.nu/packages/core/any/archlinux-keyring/download/
pacman --noconfirm -U https://www.parabola.nu/packages/libre/any/pacman-mirrorlist/download/
pacman --noconfirm -S archlinuxarm-keyring
sed -i 's/^SigLevel.*/SigLevel = Required DatabaseOptional/' /etc/pacman.conf

# update the keyring
pacman-key --init
pacman-key --populate archlinuxarm archlinux archlinux32 parabola
pacman-key --refresh-keys

# install the mirrorlist
[ -f /etc/pacman.d/mirrorlist.pacnew ] && mv /etc/pacman.d/mirrorlist{.pacnew,}

# enable the [libre] and disable [alarm] in pacman.conf
sed -i '/^\[core\]/i \
[libre] \
Include = /etc/pacman.d/mirrorlist \
' /etc/pacman.conf
sed -Ei '/^\[alarm\]|\[aur\]/,+2d' /etc/pacman.conf

# clear the pacman cache. all of it.
yes | pacman -Scc

# fix the architecture in /etc/pacman.conf
sed -i 's/^Architecture.*/Architecture = armv7h/' /etc/pacman.conf

# update the system to parabola
pacman --noconfirm -Syy
pacman --noconfirm -S pacman
mv /etc/pacman.conf{.pacnew,}
pacman --noconfirm -Syuu
pacman --noconfirm -S your-freedom
yes | pacman -S linux-libre

# cleanup users
userdel -r alarm
useradd -mU parabola
echo 'parabola:parabola' | chpasswd
echo 'root:parabola' | chpasswd

# cleanup hostname
echo "parabola-arm" > /etc/hostname

# enable UTF-8 locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
sed -i 's/LANG.*/LANG=en_US.UTF-8/' /etc/locale.conf
EOF
chmod +x "$_scriptfile"

# start the VM
mkdir -p "$_bootdir"
mount ${_loopdev}p1 $_bootdir
QEMU_AUDIO_DRV=none qemu-system-arm \
  -M vexpress-a9 \
  -m 1G \
  -dtb "$_bootdir"/dtbs/vexpress-v2p-ca9.dtb \
  -kernel "$_bootdir"/zImage \
  --append "root=/dev/mmcblk0p3 rw roottype=ext4 console=ttyAMA0" \
  -drive if=sd,driver=raw,cache=writeback,file="$_outfile" \
  -display none \
  -net user,hostfwd=tcp::2022-:22 \
  -net nic \
  -daemonize \
  -pidfile "$_pidfile"

# wait for ssh to be up
while ! ssh -p 2022 -i keys/id_rsa root@localhost -o StrictHostKeyChecking=no true 2>/dev/null; do
  echo -n . && sleep 5
done && echo

# copy and execute the migration script
scp -P 2022 -i keys/id_rsa "$_scriptfile" root@localhost:
ssh -p 2022 -i keys/id_rsa root@localhost "./$(basename "$_scriptfile")"

# stop the VM
ssh -p 2022 -i keys/id_rsa root@localhost "nohup shutdown -h now &>/dev/null & exit"
while kill -0 $(cat "$_pidfile") 2> /dev/null; do echo -n . && sleep 5; done && echo

# cleanup
umount ${_loopdev}p1
losetup -d $_loopdev
rm -rf "$_bootdir" "$_scriptfile" "$_pidfile"

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

_loopdev=$(sudo losetup -f --show "$_outfile")

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

# create the package build preparation script, adapted from
# https://wiki.parabola.nu/Package_maintainer_guide
(source /etc/makepkg.conf && cat > "$_scriptfile" << EOF
#!/bin/bash

set -eu

# setup parabola login keys
cat /root/.ssh/authorized_keys >> /home/parabola/.ssh/authorized_keys

# fix key permissions and ownership
chown -R parabola:parabola /home/parabola/{.gnupg,.ssh,.gitconfig}
chmod 600 /home/parabola/.ssh/authorized_keys

# install needed packages
pacman --noconfirm -S libretools base-devel vim sudo \
  rxvt-unicode-terminfo bash-completion htop

# update configuration
sed -i \
    -e 's_^#PKGDEST.*_PKGDEST="/home/parabola/output/packages_' \
    -e 's_^#SRCDEST.*_SRCDEST="/home/parabola/output/sources_' \
    -e 's_^#SRCPKGDEST.*_SRCPKGDEST="/home/parabola/output/srcpackages_' \
    -e 's_^#LOGDEST.*_LOGDEST="/home/parabola/output/makepkglogs_' \
    -e 's_^#PACKAGER.*_PACKAGER="$PACKAGER"_' \
    -e 's_^#GPGKEY.*_GPGKEY="$GPGKEY"_' \
  /etc/makepkg.conf

sed -i \
    -e 's_^CHROOTDIR.*_CHROOTDIR="/home/parabola/build"_' \
    -e 's_^CHROOTEXTRAPKG.*_CHROOTEXTRAPKG=(vim)_' \
  /etc/libretools.d/chroot.conf

sed -i \
    -e 's_^HOOKPOSTRELEASE.*_HOOKPOSTRELEASE=""_' \
  /etc/libretools.conf

# create directories
mkdir -p /home/parabola/output/{packages,sources,srcpackages,makepkglogs}
chown -R parabola:parabola /home/parabola/output

# disable systemd-stdin hack...
sed -i '/XXX: SYSTEMD-STDIN HACK/,+9d' /usr/bin/librechroot

# setup sudo
cat > /etc/sudoers.d/parabola << IEOF
# grant full permissions to user parabola
parabola ALL=(ALL) NOPASSWD: ALL
IEOF

# setup work directories
su - parabola -c createworkdir
su - parabola -c "sudo librechroot make"

# setup batch building
pacman --noconfirm -S task-spooler

cat >> /home/parabola/.bashrc << 'IEOF'

alias sudo='sudo '

function librespool() {
  local cmd
  printf -v cmd '%q ' "\$@"
  tsp -d script --return --quiet --command "\$cmd" /dev/null
}

alias librechroot-spool='librespool sudo /usr/bin/librechroot'
alias libremakepkg-spool='librespool sudo /usr/bin/libremakepkg'

alias qbuild='if tsp | grep " \$(pwd)\\$" >/dev/null; then tspr; fi && tsp echo \$(pwd) && librechroot-spool update && libremakepkg-spool && tsp -d librestage'

alias tspr='d=\$(tsp | grep " \$(pwd)\\$" | head -n1 | cut -d" " -f1) && for i in \$(seq \$d \$((\$d+3))); do tsp -r \$i; done'
alias tspl='watch -n5 tsp'
alias tspc='while tsp | grep -q running; do tsp -c; done'

alias librecommit='if tsp | grep " \$(pwd)\\$" >/dev/null; then tspr; fi && git commit -m "\$(pwd | rev | cut -d"/" -f1-2 | rev): updated to \$(bash -c "source PKGBUILD && echo \\\$pkgver")"'
IEOF
EOF
)
chmod +x "$_scriptfile"

# start the VM
mkdir -p "$_bootdir"
mount ${_loopdev}p1 "$_bootdir"
_board="vexpress-a9"
_cpu="cortex-a9"
_memory="1G"
_kernel="$_bootdir"/vmlinuz-linux-libre
_dtb="$_bootdir"/dtbs/linux-libre/vexpress-v2p-ca9.dtb
_initrd="$_bootdir"/initramfs-linux-libre.img
QEMU_AUDIO_DRV=none qemu-system-arm \
  -M $_board \
  -cpu $_cpu \
  -m $_memory \
  -kernel "$_kernel" \
  -dtb "$_dtb" \
  -initrd "$_initrd" \
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

# copy the current users keys to the VM
scp -rP 2022 -i keys/id_rsa "$(sudo -iu $SUDO_USER pwd)"/.gnupg root@localhost:/home/parabola/
scp -rP 2022 -i keys/id_rsa "$(sudo -iu $SUDO_USER pwd)"/.ssh root@localhost:/home/parabola/
scp -rP 2022 -i keys/id_rsa "$(sudo -iu $SUDO_USER pwd)"/.gitconfig root@localhost:/home/parabola/

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

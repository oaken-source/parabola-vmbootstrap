#!/bin/bash

set -eu

_scriptfile=$_builddir/migrate.sh
_pidfile=$_builddir/qemu.pid

_loopdev=$(sudo losetup -f --show $_outfile)
_bootdir=.boot

# register cleanup handler to stop the started VM
function cleanup {
  test -f $_pidfile && (kill -9 $(cat $_pidfile) || true)
  rm -f $_pidfile
  umount ${_loopdev}p1
  losetup -d $_loopdev
  rm -rf $_bootdir
  rm -f $_scriptfile
}
trap cleanup ERR

# create the package build preparation script, adapted from
# https://wiki.parabola.nu/Package_maintainer_guide
(source /etc/makepkg.conf && cat > $_scriptfile << EOF
#!/bin/bash

set -eu

# setup parabola login keys
cat /root/.ssh/authorized_keys >> /home/parabola/.ssh/authorized_keys

# fix key permissions and ownership
chown -R parabola:parabola /home/parabola/{.gnupg,.ssh,.gitconfig}
chmod 600 /home/parabola/.ssh/authorized_keys

# install needed packages
pacman --noconfirm -S libretools base-devel vim sudo rxvt-unicode-terminfo bash-completion

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

alias qbuild='if tsp | grep "\$(pwd)\\$" >/dev/null; then tspdel; fi && tsp echo \$(basename \$(pwd)) && librechroot-spool update && libremakepkg-spool && tsp -d librestage'

alias tspdel='d=\$(tsp | grep "\$(pwd)\\$" | head -n1 | cut -d" " -f1) && for i in \$(seq \$d \$((\$d+3))); do tsp -r \$i; done'

alias librecommit='if tsp | grep "\$(pwd)\\$" >/dev/null; then tspdel; fi && git commit -m "\$(pwd | rev | cut -d"/" -f1-2 | rev): updated to \$(bash -c "source PKGBUILD && echo \\\$pkgver")"'
IEOF

# enable UTF-8 locale
sed -i 's/#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
sed -i 's/LANG.*/LANG=en_US.UTF-8/' /etc/locale.conf
EOF
)
chmod +x $_scriptfile

# start the VM
mkdir -p $_bootdir
mount ${_loopdev}p1 $_bootdir
QEMU_AUDIO_DRV=none qemu-system-arm \
  -M vexpress-a9 \
  -m 1G \
  -dtb $_bootdir/dtbs/vexpress-v2p-ca9.dtb \
  -kernel $_bootdir/zImage \
  --append "root=/dev/mmcblk0p2 rw roottype=ext4 console=ttyAMA0" \
  -drive if=sd,driver=raw,cache=writeback,file=$_outfile \
  -display none \
  -net user,hostfwd=tcp::2022-:22 \
  -net nic \
  -daemonize \
  -pidfile $_pidfile

# wait for ssh to be up
while ! ssh -p 2022 -i keys/id_rsa root@localhost -o StrictHostKeyChecking=no true 2>/dev/null; do
  echo -n . && sleep 5
done && echo

# copy the current users keys keys to the VM
scp -rP 2022 -i keys/id_rsa $(sudo -iu $(logname) pwd)/.gnupg root@localhost:/home/parabola/
scp -rP 2022 -i keys/id_rsa $(sudo -iu $(logname) pwd)/.ssh root@localhost:/home/parabola/
scp -rP 2022 -i keys/id_rsa $(sudo -iu $(logname) pwd)/.gitconfig root@localhost:/home/parabola/

# copy and execute the migration script
scp -P 2022 -i keys/id_rsa $_scriptfile root@localhost:
ssh -p 2022 -i keys/id_rsa root@localhost "./$(basename $_scriptfile)"

# open a shell for debugging
# ssh -p 2022 -i keys/id_rsa root@localhost

# stop the VM
ssh -p 2022 -i keys/id_rsa root@localhost "nohup shutdown -h now &>/dev/null & exit"
while kill -0 $(cat $_pidfile) 2> /dev/null; do echo -n . && sleep 5; done && echo
rm -f $_pidfile

# cleanup
umount ${_loopdev}p1
losetup -d $_loopdev
rm -rf $_bootdir
rm $_scriptfile

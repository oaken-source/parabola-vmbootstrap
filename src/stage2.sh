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

# create the migration script, adapted from
# https://wiki.parabola.nu/Migration_from_Arch_ARM
cat > $_scriptfile << 'EOF'
#!/bin/bash

set -eu

sed -i 's/^SigLevel.*/SigLevel = Never/' /etc/pacman.conf

pacman --noconfirm -U https://www.parabola.nu/packages/libre/any/parabola-keyring/download/
pacman --noconfirm -U https://www.parabola.nu/packages/libre/any/archlinux32-keyring/download/
pacman --noconfirm -U https://www.parabola.nu/packages/core/any/archlinux-keyring/download/
pacman --noconfirm -U https://www.parabola.nu/packages/libre/any/pacman-mirrorlist/download/
pacman --noconfirm -S archlinuxarm-keyring

sed -i 's/^SigLevel.*/SigLevel = Required DatabaseOptional/' /etc/pacman.conf

pacman-key --init
pacman-key --populate archlinuxarm archlinux archlinux32 parabola

test -f /etc/pacman.d/mirrorlist.pacnew && mv /etc/pacman.d/mirrorlist{.pacnew,}

sed -i '/^\[core\]/i \
[libre] \
Include = /etc/pacman.d/mirrorlist \
' /etc/pacman.conf
sed -Ei '/^\[alarm\]|\[aur\]/,+2d' /etc/pacman.conf

yes | pacman -Scc

sed -i 's/^Architecture.*/Architecture = armv7h/' /etc/pacman.conf

pacman --noconfirm -Syy

pacman --noconfirm -S pacman
mv /etc/pacman.conf{.pacnew,}
pacman --noconfirm -Syuu

pacman --noconfirm -S your-freedom
EOF
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

# copy and execute the migration script
scp -P 2022 -i keys/id_rsa $_scriptfile root@localhost:
ssh -p 2022 -i keys/id_rsa root@localhost "./$(basename $_scriptfile)"

# stop the VM
ssh -p 2022 -i keys/id_rsa root@localhost "nohup shutdown -h now &>/dev/null & exit"
while kill -0 $(cat $_pidfile) 2> /dev/null; do echo -n . && sleep 5; done && echo
rm -f $_pidfile

# cleanup
umount ${_loopdev}p1
losetup -d $_loopdev
rm -rf $_bootdir
rm $_scriptfile

#!/bin/bash

set -e

# essential tools
pacman -S --noconfirm base-devel libretools

# matter of preference
pacman -S --noconfirm vim bash-completion

# create builduser
useradd -mU parabola
chpasswd <<<"parabola:parabola"

# enable sudo access
cat >> /etc/sudoers <<EOF
parabola ALL=(ALL) NOPASSWD: ALL
EOF

# setup environment
sed -i 's|#PKGDEST=.*|PKGDEST=/home/parabola/output/packages|' /etc/makepkg.conf
sed -i 's|#SRCDEST=.*|PKGDEST=/home/parabola/output/sources|' /etc/makepkg.conf
sed -i 's|#SRCPKGDEST=.*|PKGDEST=/home/parabola/output/srcpackages|' /etc/makepkg.conf
sed -i 's|#LOGDEST=.*|PKGDEST=/home/parabola/output/makepkglogs|' /etc/makepkg.conf
sed -i '/^OPTIONS=/ s/debug/!debug/' /etc/makepkg.conf

sudo -u parabola createworkdir

#!/bin/bash

set -e

# setup systemd-resolved
systemctl start systemd-resolved.service || return
systemctl enable systemd-resolved.service
ln -sf /var/run/systemd/resolve/resolv.conf /etc/resolv.conf

# determine first ethernet device
eth="$(basename "$(find /sys/class/net/ -mindepth 1 -maxdepth 1 -iname 'e*' | head -n1)")"
[ -n "$eth" ] || eth="eth0"

# setup netctl for ethernet-dhcp
sed "s/eth0/$eth/" /etc/netctl/examples/ethernet-dhcp > /etc/netctl/ethernet-dhcp
netctl start ethernet-dhcp || return
netctl enable ethernet-dhcp

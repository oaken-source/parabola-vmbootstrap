#!/bin/bash

set -e

# determine first ethernet device
eth="$(basename "$(find /sys/class/net/ -mindepth 1 -maxdepth 1 -iname 'e*' | head -n1)")"
[ -n "$eth" ] || eth="eth0"

# create a network configuration
cat > /etc/systemd/network/$eth.network << EOF
[Match]
Name=$eth

[Network]
DHCP=yes
EOF

# enable said network configuration
systemctl enable systemd-networkd.service
systemctl enable systemd-resolved.service

#!/bin/bash

set -e

# setup systemd-resolved
systemctl start systemd-resolved.service
systemctl enable systemd-resolved.service
ln -sf /var/run/systemd/resolve/resolv.conf /etc/resolv.conf

# setup netctl for ethernet-dhcp
cp /etc/netctl/examples/ethernet-dhcp /etc/netctl/
netctl start ethernet-dhcp
netctl enable ethernet-dhcp

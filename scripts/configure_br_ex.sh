#!/bin/bash
set -euo pipefail

# 1. Discover Public Network Config
PUBLIC_SUBNET_NAME="public-subnet"
PUBLIC_GW_IP=$(openstack subnet show "$PUBLIC_SUBNET_NAME" -f value -c gateway_ip)
PUBLIC_CIDR=$(openstack subnet show "$PUBLIC_SUBNET_NAME" -f value -c cidr)
PUBLIC_PREFIX="${PUBLIC_CIDR#*/}"

echo "Configuring br-ex with IP $PUBLIC_GW_IP/$PUBLIC_PREFIX"

# 2. Configure Bridge
sudo ip link set br-ex up
sudo ip addr replace "$PUBLIC_GW_IP/$PUBLIC_PREFIX" dev br-ex
sudo sysctl -w net.ipv4.ip_forward=1 >/dev/null

# Disable rp_filter to allow the "weird" routing from host -> VM -> instance
sudo sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sudo sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sudo sysctl -w net.ipv4.conf.br-ex.rp_filter=0 >/dev/null
sudo sysctl -w net.ipv4.conf.enp1s0.rp_filter=0 >/dev/null || true

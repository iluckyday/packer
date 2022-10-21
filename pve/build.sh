#!/bin/sh

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y packer qemu-system-x86 qemu-utils

PVEVER=$(curl -skL http://download.proxmox.com/iso/SHA256SUMS | awk 'END {sub(/proxmox-ve_/,"",$2);sub(/.iso/,"",$2);print $2}')
PVEURL="http://download.proxmox.com/iso/proxmox-ve_"${PVEVER}".iso"

CPUS=$(nproc)

rm -rf /tmp/output-pve
sed -e "s/XPVEVERX/$PVEVER/" -e "s|XPVEURLX|$PVEURL|" -e "s/XCPUSX/$CPUS/" pve/pve.json | packer build -

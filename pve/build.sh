#!/bin/sh

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y packer qemu-system-x86 qemu-utils

PVEVER=$(curl -skL http://download.proxmox.com/iso/SHA256SUMS | awk '{if($2~/^proxmox-ve/) print $2}' | awk 'END {sub(/proxmox-ve_/,"",$1);sub(/.iso/,"",$1);print $1}')
PVEURL="http://download.proxmox.com/iso/proxmox-ve_"${PVEVER}".iso"

CPUS=$(nproc)

rm -rf /tmp/output-pve
sed -e "s/XPVEVERX/$PVEVER/" -e "s|XPVEURLX|$PVEURL|" -e "s/XCPUSX/$CPUS/" pve/pve.json | packer build -

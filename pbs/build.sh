#!/bin/sh

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y packer qemu-system-x86 qemu-utils

PBSVER=$(curl -skL http://download.proxmox.com/iso/SHA256SUMS | awk '{if($2~/^proxmox-backup-server/) print $2}' | awk 'END {sub(/proxmox-backup-server_/,"",$1);sub(/.iso/,"",$1);print $1}')
PBSURL="http://download.proxmox.com/iso/proxmox-backup-server_"${PBSVER}".iso"

CPUS=$(nproc)

rm -rf /tmp/output-pbs
sed -e "s/XPBSVERX/$PBSVER/" -e "s|XPBSURLX|$PBSURL|" -e "s/XCPUSX/$CPUS/" pbs/pbs.json | packer build -

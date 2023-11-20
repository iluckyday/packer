#!/bin/sh

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y packer qemu-system-x86 qemu-utils

rm -rf /tmp/output-vyos-rolling-amd64

VYOSURL=$(curl -skL https://vyos.net/get/nightly-builds | awk -F'"' '/amd64.iso/ {print $2;exit}')
sed -e "s|XURLX|${VYOSURL}|" vyos/vyos.json | packer build -

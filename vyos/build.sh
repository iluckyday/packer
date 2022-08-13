#!/bin/sh

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y packer qemu-system-x86 qemu-utils

rm -rf /tmp/output-vyos-rolling-amd64
packer build vyos/vyos.json

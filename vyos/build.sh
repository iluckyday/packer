#!/bin/sh

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y packer

pwd

cd /home/runner/work/packer/packer

packer build -debug vyos/vyos.json

#!/bin/sh

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y packer

packer build -debug vyos.json

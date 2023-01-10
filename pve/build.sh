#!/bin/sh
set -x

export DEBIAN_FRONTEND=noninteractive
apt update
apt install -y packer qemu-system-x86 qemu-utils sshpass guestfs-tools

PVEVER=$(curl -skL http://download.proxmox.com/iso/SHA256SUMS | awk '{if($2~/^proxmox-ve/) print $2}' | awk 'END {sub(/proxmox-ve_/,"",$1);sub(/.iso/,"",$1);print $1}')
PVEURL="http://download.proxmox.com/iso/proxmox-ve_"${PVEVER}".iso"

CPUS=$(nproc)

rm -rf /tmp/output-pve /pve
sed -e "s/XPVEVERX/$PVEVER/" -e "s|XPVEURLX|$PVEURL|" -e "s/XCPUSX/$CPUS/" pve/pve.json | packer build -
# qemu-img convert -c -f raw -O qcow2 /tmp/output-pve/pve-${PVEVER}.raw /tmp/output-pve/pve-orig-${PVEVER}.img

free -h
df -h
df -h /tmp
ls -lh /tmp/output-pve

sleep 10
echo for pveceph ...
loopx=$(losetup --show -f -P /tmp/output-pve/pve-${PVEVER}.raw)

vgscan
vgchange -a y
mkdir -p /pve
mount /dev/pve/root /pve
mount_dir=/pve

ln -sf /dev/null ${mount_dir}/etc/systemd/system/logrotate.timer
ln -sf /dev/null ${mount_dir}/etc/systemd/system/man-db.timer
ln -sf /dev/null ${mount_dir}/etc/systemd/system/apt-daily.timer
ln -sf /dev/null ${mount_dir}/etc/systemd/system/e2scrub_all.timer
ln -sf /dev/null ${mount_dir}/etc/systemd/system/apt-daily-upgrade.timer
ln -sf /dev/null ${mount_dir}/etc/systemd/system/fstrim.timer
ln -sf /dev/null ${mount_dir}/etc/systemd/system/pve-daily-update.timer
ln -sf /dev/null ${mount_dir}/etc/systemd/system/chrony.service
ln -sf /dev/null ${mount_dir}/etc/systemd/system/cron.service
ln -sf /dev/null ${mount_dir}/etc/systemd/system/e2scrub_reap.service
ln -sf /dev/null ${mount_dir}/etc/systemd/system/ceph-crash.service

sed -i -e 's/ens[0-9]/ens10/g' -e 's/static/dhcp/' -e '/address/d' -e '/gateway/d' ${mount_dir}/etc/network/interfaces
sed -i -e 's/terminal_output gfxterm/terminal_output console/' -e 's/timeout=.*/timeout=0/g' ${mount_dir}/boot/grub/grub.cfg

rm -rf ${mount_dir}/etc/systemd/system/multi-user.target.wants/pve* \
       ${mount_dir}/etc/systemd/system/multi-user.target.wants/qmeventd.service \
       ${mount_dir}/etc/systemd/system/multi-user.target.wants/spiceproxy.service \
       ${mount_dir}/etc/systemd/system/pve-manager.service \
       ${mount_dir}/etc/systemd/system/timers.target.wants/*

sync ${mount_dir}
umount ${mount_dir}
sleep 1
vgchange -a n
sleep 1
losetup -d $loopx

echo install pve ceph
systemd-run -G --unit qemu-pve.service qemu-system-x86_64 -machine pc,accel=kvm:hax:hvf:whpx:tcg -cpu kvm64 -smp "$(nproc)" -m 2G -netdev user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:22222-:22 -device virtio-net,netdev=n0,addr=0x0a -display none -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 -boot c -drive file=/tmp/output-pve/pve-${PVEVER}.raw,if=virtio,format=raw,media=disk

sleep 10
while true
do
	sshpass -p proxmox ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22222 -l root 127.0.0.1 'exit 0'
	RCODE=$?
	if [ $RCODE -ne 0 ]; then
		echo "[!] SSH is not available."
		sleep 2
	else
		sleep 2
		break
	fi
done

sshpass -p proxmox ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p 22222 -l root 127.0.0.1 bash -sx << "CMD"
export DEBIAN_FRONTEND=noninteractive
apt update
apt upgrade -y
sleep 3
/usr/bin/pmxcfs -l
sleep 3
echo y | /usr/bin/pveceph install
sleep 1
poweroff
CMD

sleep 300
echo custom ...
loopx=$(losetup --show -f -P /tmp/output-pve/pve-${PVEVER}.raw)

vgscan
vgchange -a y
mkdir -p /pve
mount /dev/pve/root /pve
mount_dir=/pve

cat << EOF >> ${mount_dir}/etc/fstab
tmpfs             /run                    tmpfs defaults,size=90%     0 0
tmpfs             /tmp                    tmpfs mode=1777,size=90%    0 0
tmpfs             /root/.cache            tmpfs   rw,relatime         0 0
EOF

mkdir -p ${mount_dir}/root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyuzRtZAyeU3VGDKsGk52rd7b/rJ/EnT8Ce2hwWOZWp" >> ${mount_dir}/root/.ssh/authorized_keys2
chmod 600 ${mount_dir}/root/.ssh/authorized_keys2

mkdir -p ${mount_dir}/etc/apt/apt.conf.d
cat << EOF > ${mount_dir}/etc/apt/apt.conf.d/99-freedisk
APT::Authentication "0";
APT::Get::AllowUnauthenticated "1";
Dir::Cache "/dev/shm";
Dir::State::lists "/dev/shm";
Dir::Log "/dev/shm";
DPkg::Post-Invoke {"/bin/rm -f /dev/shm/archives/*.deb || true";};
EOF

cat << EOF > ${mount_dir}/etc/apt/apt.conf.d/99norecommend
APT::Install-Recommends "0";
APT::Install-Suggests "0";
EOF

mkdir -p ${mount_dir}/etc/dpkg/dpkg.cfg.d
cat << EOF > ${mount_dir}/etc/dpkg/dpkg.cfg.d/99-nodoc
path-exclude /usr/share/doc/*
path-exclude /usr/share/man/*
path-exclude /usr/share/groff/*
path-exclude /usr/share/info/*
path-exclude /usr/share/lintian/*
path-exclude /usr/share/linda/*
path-exclude /usr/share/locale/*
path-include /usr/share/locale/en*
EOF

mkdir -p ${mount_dir}/etc/systemd/system-environment-generators
cat << EOF > ${mount_dir}/etc/systemd/system-environment-generators/20-python
#!/bin/sh
echo 'PYTHONDONTWRITEBYTECODE=1'
echo 'PYTHONSTARTUP=/usr/lib/pythonstartup'
EOF
chmod +x ${mount_dir}/etc/systemd/system-environment-generators/20-python

cat << EOF > ${mount_dir}/etc/profile.d/python.sh
#!/bin/sh
export PYTHONDONTWRITEBYTECODE=1 PYTHONSTARTUP=/usr/lib/pythonstartup
EOF

cat << EOF > ${mount_dir}/usr/lib/pythonstartup
import readline
import time

readline.add_history("# " + time.asctime())
readline.set_history_length(-1)
EOF

cat << EOF >> ${mount_dir}/root/.bashrc
export HISTSIZE=1000 LESSHISTFILE=/dev/null HISTFILE=/dev/null
export PYTHONDONTWRITEBYTECODE=1 PYTHONSTARTUP=/usr/lib/pythonstartup
EOF

ver="$(curl -skL https://api.github.com/repos/cirros-dev/cirros/releases/latest | grep -oP '"tag_name": "\K(.*)(?=")')"
curl -skL -o ${mount_dir}/root/cirros-"$ver"-x86_64-disk.img https://github.com/cirros-dev/cirros/releases/download/"$ver"/cirros-"$ver"-x86_64-disk.img
#file=$(curl -skL https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/latest-releases.yaml | awk '/file: alpine-virt/ {print $2}')
#curl -skL -o ${mount_dir}/var/lib/vz/template/iso/${file} https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64/${file}
ctfile=$(curl -skL http://download.proxmox.com/images/aplinfo-pve-${PVEVER%%.*}.dat | awk '/system\/alpine-/ {SAVE=$2} END{print SAVE}')
curl -skL -o ${mount_dir}/var/lib/vz/template/cache/${ctfile##*/} http://download.proxmox.com/images/${ctfile}

sed -i '/example/d' ${mount_dir}/etc/hosts
rm -rf ${mount_dir}/var/lib/pve-cluster/*

echo clean ...
rm -rf ${mount_dir}/etc/hostname \
       ${mount_dir}/etc/localtime \
       ${mount_dir}/usr/share/doc \
       ${mount_dir}/usr/share/man \
       ${mount_dir}/tmp/* \
       ${mount_dir}/var/tmp/* \
       ${mount_dir}/var/cache/apt/* \
       ${mount_dir}/var/cache/man/* \
       ${mount_dir}/var/cache/proxmox-backup/* \
       ${mount_dir}/var/cache/debconf/* \
       ${mount_dir}/var/lib/apt/lists/* \
       ${mount_dir}/usr/bin/systemd-analyze \
       ${mount_dir}/boot/System.map-*
rm -rf ${mount_dir}/usr/lib/firmware

DELETE_MODULES="
fs/udf
fs/adfs
fs/affs
fs/ocfs2
fs/jfs
fs/ubifs
fs/gfs2
fs/cifs
fs/befs
fs/erofs
fs/hpfs
fs/f2fs
fs/xfs
fs/freevxfs
fs/hfsplus
fs/minix
fs/coda
fs/dlm
fs/afs
fs/omfs
fs/reiserfs
fs/bfs
fs/qnx6
fs/nilfs2
fs/jbd2
fs/efs
fs/hfs
fs/jffs2
fs/orangefs
fs/ufs
net/wireless
net/mpls
net/wimax
net/l2tp
net/nfc
net/tipc
net/appletalk
net/rds
net/dccp
net/netrom
net/lapb
net/mac80211
net/6lowpan
net/rxrpc
net/atm
net/psample
net/rose
net/ax25
net/bluetooth
net/ife
net/phonet
drivers/mfd
drivers/hid
drivers/nfc
drivers/dca
drivers/thunderbolt
drivers/firmware
drivers/xen
drivers/spi
drivers/i2c
drivers/uio
drivers/hv
drivers/ptp
drivers/pcmcia
drivers/isdn
drivers/atm
drivers/w1
drivers/hwmon
drivers/dax
drivers/ssb
drivers/bluetooth
drivers/android
drivers/nvme
drivers/gnss
drivers/firewire
drivers/leds
drivers/media
drivers/parport
drivers/gpu
drivers/video
drivers/net/fddi
drivers/net/hyperv
drivers/net/xen-netback
drivers/net/wireless
drivers/net/slip
drivers/net/usb
drivers/net/team
drivers/net/ppp
drivers/net/can
drivers/net/phy
drivers/net/ieee802154
drivers/net/fjes
drivers/net/hippi
drivers/net/wan
drivers/net/plip
drivers/net/appletalk
drivers/net/wimax
drivers/net/arcnet
drivers/net/hamradio
drivers/net/ethernet
sound
"
for m in $DELETE_MODULES; do
	rm -rf ${mount_dir}/lib/modules/*/kernel/$m
done

find ${mount_dir}/usr/*/locale -mindepth 1 -maxdepth 1 ! -name 'locale-archive' -prune -exec rm -rf {} +
find ${mount_dir}/usr -type d -name __pycache__ -prune -exec rm -rf {} +
find ${mount_dir}/var/log -type f -delete

sync ${mount_dir}
umount ${mount_dir}
sleep 1
vgchange -a n
sleep 1
losetup -d $loopx

sleep 1
#qemu-img convert -c -f raw -O qcow2 /tmp/output-pve/pve-${PVEVER}.raw /tmp/output-pve/pve-${PVEVER}.img
virt-sparsify -x -v --check-tmpdir ignore --compress --format raw --convert qcow2 /tmp/output-pve/pve-${PVEVER}.raw /tmp/output-pve/pve-${PVEVER}.img

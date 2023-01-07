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

free -h
df -h
ls -lh /tmp/output-pve

echo install pve ceph
systemd-run -G --unit qemu-pve.service qemu-system-x86_64 -machine pc,accel=kvm:hax:hvf:whpx:tcg -cpu kvm64 -smp "$(nproc)" -m 2G -netdev user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:22222-:22 -device virtio-net,netdev=n0,addr=0x03 -display none -object rng-random,filename=/dev/urandom,id=rng0 -device virtio-rng-pci,rng=rng0 -boot c -drive file=/tmp/output-pve/pve-${PVEVER}.raw,if=virtio,format=raw,media=disk

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
ip address show
ip route
cat /etc/resolv.conf
echo y | pveceph install
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
tmpfs             /var/log                tmpfs defaults,noatime      0 0
tmpfs             /root/.cache            tmpfs   rw,relatime         0 0
EOF

echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyuzRtZAyeU3VGDKsGk52rd7b/rJ/EnT8Ce2hwWOZWp" >> ${mount_dir}/etc/pve/priv/authorized_keys

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

rm -rf ${mount_dir}/etc/hostname \
       ${mount_dir}/etc/localtime \
       ${mount_dir}/usr/share/doc \
       ${mount_dir}/usr/share/man \
       ${mount_dir}/tmp/* \
       ${mount_dir}/var/log/* \
       ${mount_dir}/var/tmp/* \
       ${mount_dir}/var/cache/apt/* \
       ${mount_dir}/var/lib/apt/lists/* \
       ${mount_dir}/usr/bin/systemd-analyze \
       ${mount_dir}/lib/modules/*/kernel/drivers/net/ethernet/* \
       ${mount_dir}/boot/System.map-*
find ${mount_dir}/usr/*/locale -mindepth 1 -maxdepth 1 ! -name 'locale-archive' -prune -exec rm -rf {} +
find ${mount_dir}/usr -type d -name __pycache__ -prune -exec rm -rf {} +

sync ${mount_dir}
umount ${mount_dir}
sleep 1
vgchange -a n
sleep 1
losetup -d $loopx

sleep 1
#qemu-img convert -c -f raw -O qcow2 /tmp/output-pve/pve-${PVEVER}.raw /tmp/output-pve/pve-${PVEVER}.img
virt-sparsify -x -v --compress --convert qcow2 /tmp/output-pve/pve-${PVEVER}.raw /tmp/output-pve/pve-${PVEVER}.img

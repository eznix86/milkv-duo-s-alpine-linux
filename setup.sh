#!/bin/bash

set -e

echo "Setting up Milk-V Duo S with Alpine Linux and OpenRC init..."

MILKV_DUO_S_VERSION="v2.0.1"
MILKV_DUO_S_IMG="milkv-duos-glibc-arm64-sd_$MILKV_DUO_S_VERSION.img"
MILKV_DUO_S_ZIP="$MILKV_DUO_S_IMG.zip"
ALPINE_ROOT_FS="alpine-minirootfs-3.23.2-aarch64.tar.gz"

MOUNT=/mnt/img
ROOT=$MOUNT/root
BOOT=$MOUNT/boot

if [ -f /var/lib/apt/periodic/update-success-stamp ] &&
	[ $(($(date +%s) - $(stat -c %Y /var/lib/apt/periodic/update-success-stamp))) -lt 86400 ]; then
	echo "apt update was already run recently. Skipping."
else
	echo "Running apt update..."
	sudo apt update
fi

commands="unzip wget"
missing=()

for cmd in $commands; do
	if command -v "$cmd" >/dev/null 2>&1; then
		echo "$cmd is available at $(command -v "$cmd")"
	else
		echo "$cmd is NOT available."
		missing+=("$cmd")
	fi
done

if [ ${#missing[@]} -gt 0 ]; then
	echo "Installing missing commands: ${missing[*]}"
	sudo apt-get update
	sudo apt-get install -y "${missing[@]}"
else
	echo "All commands are already installed."
fi

cleanup() {
	echo "Cleaning up..."
	sudo umount $ROOT/dev $ROOT/proc $ROOT/sys 2>/dev/null || true
	sudo umount $BOOT 2>/dev/null || true
	sudo umount $ROOT 2>/dev/null || true
	[ -n "$LOOP" ] && sudo losetup -d "$LOOP" 2>/dev/null || true
	sudo rm -rf $MOUNT 2>/dev/null || true
	cp -f $MILKV_DUO_S_IMG "milkv-duos-alpine-aarch64-sd_$MILKV_DUO_S_VERSION.img"
	rm $MILKV_DUO_S_IMG
}
trap cleanup EXIT

if [ ! -f $MILKV_DUO_S_ZIP ]; then
	echo "Downloading Milk-V Duo S image..."
	wget -O $MILKV_DUO_S_ZIP https://github.com/milkv-duo/duo-buildroot-sdk-v2/releases/download/$MILKV_DUO_S_VERSION/$MILKV_DUO_S_ZIP || {
		echo "Failed to download Milk-V Duo S image"
		exit 1
	}
else
	echo "Milk-V Duo S image already exists, skipping download."
fi

if [ ! -f $ALPINE_ROOT_FS ]; then
	echo "Downloading Alpine Linux rootfs..."
	wget -O $ALPINE_ROOT_FS https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/aarch64/$ALPINE_ROOT_FS || {
		echo "Failed to download Alpine Linux rootfs"
		exit 1
	}
else
	echo "Alpine Linux rootfs already exists, skipping download."
fi

if [ ! -f $MILKV_DUO_S_IMG ]; then
	echo "Extracting Milk-V Duo S image..."
	unzip $MILKV_DUO_S_ZIP
fi

echo "Setting up loop device..."
LOOP=$(sudo losetup -f)
sudo losetup -P "$LOOP" $MILKV_DUO_S_IMG
export LOOP

sleep 2

if [ ! -e "${LOOP}p1" ] || [ ! -e "${LOOP}p3" ]; then
	echo "Error: Expected partitions ${LOOP}p1 and ${LOOP}p3 not found"
	sudo losetup -d "$LOOP"
	exit 1
fi

sudo mkdir -p $ROOT
sudo mkdir -p $BOOT

echo "Mounting partitions..."
sudo mount "${LOOP}p1" $BOOT
sudo mount "${LOOP}p3" $ROOT

echo "Backup Milk v duo S features..."

# Create backup directory structure
BACKUP_DIR="/tmp/milkv_duo_backup"
sudo mkdir -p "$BACKUP_DIR/etc"
sudo mkdir -p "$BACKUP_DIR/mnt"

# Backup specific files from /etc
if [ -f "$ROOT/etc/uhubon.sh" ]; then
	sudo cp "$ROOT/etc/uhubon.sh" "$BACKUP_DIR/etc/"
	echo "Backed up uhubon.sh"
fi

if [ -f "$ROOT/etc/run_usb.sh" ]; then
	sudo cp "$ROOT/etc/run_usb.sh" "$BACKUP_DIR/etc/"
	echo "Backed up run_usb.sh"
fi

if [ -d "$ROOT/mnt" ]; then
	# Backup /mnt/system (hardware-specific kernel modules, firmware, scripts)
	if [ -d "$ROOT/mnt/system" ]; then
		sudo cp -r "$ROOT/mnt/system" "$BACKUP_DIR/mnt/" 2>/dev/null || true
		echo "Backed up /mnt/system (kernel modules, firmware, scripts)"
	fi

	# Backup /mnt/data (sensor configurations)
	if [ -d "$ROOT/mnt/data" ]; then
		sudo cp -r "$ROOT/mnt/data" "$BACKUP_DIR/mnt/" 2>/dev/null || true
		echo "Backed up /mnt/data (sensor configs)"
	fi

	# Backup /mnt/cfg (system configurations)
	if [ -d "$ROOT/mnt/cfg" ]; then
		sudo cp -r "$ROOT/mnt/cfg" "$BACKUP_DIR/mnt/" 2>/dev/null || true
		echo "Backed up /mnt/cfg (system configs)"
	fi

	# Backup /mnt/cvimodel (AI model files)
	if [ -d "$ROOT/mnt/cvimodel" ]; then
		sudo cp -r "$ROOT/mnt/cvimodel" "$BACKUP_DIR/mnt/" 2>/dev/null || true
		echo "Backed up /mnt/cvimodel (AI models)"
	fi

	# Backup any other directories in /mnt
	for mnt_dir in "$ROOT/mnt"/*; do
		if [ -d "$mnt_dir" ]; then
			dir_name=$(basename "$mnt_dir")
			if [ "$dir_name" != "system" ] && [ "$dir_name" != "data" ] && [ "$dir_name" != "cfg" ] && [ "$dir_name" != "cvimodel" ]; then
				sudo cp -r "$mnt_dir" "$BACKUP_DIR/mnt/" 2>/dev/null || true
				echo "Backed up /mnt/$dir_name"
			fi
		fi
	done

	echo "Complete /mnt backup finished"
else
	echo "No /mnt directory found to backup"
fi

echo "Clearing root directory..."
sudo find $ROOT -mindepth 1 -delete

echo "Extracting Alpine Linux rootfs..."

sudo tar -xpf $ALPINE_ROOT_FS -C $ROOT

echo "Restore Milk v duo S features..."
sudo mkdir -p "$ROOT/mnt"

if [ -f "$BACKUP_DIR/etc/uhubon.sh" ]; then
	sudo cp "$BACKUP_DIR/etc/uhubon.sh" "$ROOT/etc/"
	sudo chmod +x "$ROOT/etc/uhubon.sh"
	echo "Restored uhubon.sh (USB hub control)"
fi

if [ -f "$BACKUP_DIR/etc/run_usb.sh" ]; then
	sudo cp "$BACKUP_DIR/etc/run_usb.sh" "$ROOT/etc/"
	sudo chmod +x "$ROOT/etc/run_usb.sh"
	echo "Restored run_usb.sh (USB gadget control)"
fi

if [ -d "$BACKUP_DIR/mnt" ]; then
	if [ -d "$BACKUP_DIR/mnt/system" ]; then
		sudo cp -r "$BACKUP_DIR/mnt/system" "$ROOT/mnt/" 2>/dev/null || true
		sudo find "$ROOT/mnt/system" -name "*.sh" -exec chmod +x {} \; 2>/dev/null || true
		
		
		echo "Restored /mnt/system (kernel modules, firmware, hardware scripts)"
	fi

	if [ -d "$BACKUP_DIR/mnt/data" ]; then
		sudo cp -r "$BACKUP_DIR/mnt/data" "$ROOT/mnt/" 2>/dev/null || true
		echo "Restored /mnt/data (sensor configurations)"
	fi

	if [ -d "$BACKUP_DIR/mnt/cfg" ]; then
		sudo cp -r "$BACKUP_DIR/mnt/cfg" "$ROOT/mnt/" 2>/dev/null || true
		echo "Restored /mnt/cfg (system configurations)"
	fi

	if [ -d "$BACKUP_DIR/mnt/cvimodel" ]; then
		sudo cp -r "$BACKUP_DIR/mnt/cvimodel" "$ROOT/mnt/" 2>/dev/null || true
		echo "Restored /mnt/cvimodel (AI model files)"
	fi

	for backup_dir in "$BACKUP_DIR/mnt"/*; do
		if [ -d "$backup_dir" ]; then
			dir_name=$(basename "$backup_dir")
			if [ "$dir_name" != "system" ] && [ "$dir_name" != "data" ] && [ "$dir_name" != "cfg" ] && [ "$dir_name" != "cvimodel" ]; then
				sudo cp -r "$backup_dir" "$ROOT/mnt/" 2>/dev/null || true
				echo "Restored /mnt/$dir_name"
			fi
		fi
	done

	echo "Complete /mnt restoration finished"

	sudo chmod +x "$ROOT/mnt/system/ko/loadsystemko.sh" 2>/dev/null || true

	echo "Set executable permissions for hardware scripts"
else
	echo "No /mnt backup found to restore"
fi

sudo rm -rf "$BACKUP_DIR"

echo "milkv-duos" | sudo tee $ROOT/etc/hostname > /dev/null

echo "Configuring DNS..."
sudo tee $ROOT/etc/resolv.conf > /dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

echo "Configuring network..."
sudo tee $ROOT/etc/network/interfaces > /dev/null <<'EOF'
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet dhcp

# WiFi interface (uncomment and configure as needed)
#auto wlan0
#iface wlan0 inet dhcp
#    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
EOF

sudo mkdir -p $ROOT/usr/local/bin
sudo tee $ROOT/usr/local/bin/autologin > /dev/null <<'EOF'
#!/bin/sh
exec login -f root
EOF

sudo chmod +x $ROOT/usr/local/bin/autologin

echo "Configuring WiFi..."
sudo mkdir -p $ROOT/etc/wpa_supplicant
sudo tee $ROOT/etc/wpa_supplicant/wpa_supplicant.conf > /dev/null <<'EOF'
ctrl_interface=/var/run/wpa_supplicant
ap_scan=1
update_config=1

# Example WiFi network (edit as needed)
#network={
#    ssid="Your_WiFi_SSID"
#    psk="Your_WiFi_Password"
#    key_mgmt=WPA-PSK
#}
EOF


echo "Setting up network auto-recovery watcher..."
sudo mkdir -p $ROOT/etc/local.d/
cat > $ROOT/etc/local.d/netwatcher.start << 'WATCHER_EOF'
#!/bin/sh
LOGFILE=/var/log/netwatcher.log
log() {
    echo "$(date) - $1" >> $LOGFILE
}
log Netwatcher started
while true; do
    if ! ping -c 1 -W 3 192.168.8.1 >/dev/null 2>&1; then
        log "Gateway ping failed, checking interface..."
        ip link set eth0 up 2>/dev/null
        sleep 2
        if ! ping -c 1 -W 3 8.8.8.8 >/dev/null 2>&1; then
            log "Network down! Restarting networking..."
            /etc/init.d/networking restart
            sleep 5
            ip link set eth0 up 2>/dev/null
            sleep 3
            if ping -c 1 -W 3 192.168.8.1 >/dev/null 2>&1; then
                log "Network restored successfully"
            else
                log "Network restart failed, waiting 60s before retry..."
                sleep 60
            fi
        else
            log "Network restored via interface up"
        fi
    fi
    sleep 10
done &
WATCHER_EOF
sudo chmod +x $ROOT/etc/local.d/netwatcher.start
sudo ln -sf /etc/local.d/netwatcher.start $ROOT/etc/runlevels/default/netwatcher
echo "Network auto-recovery watcher installed"


echo "Configuring fstab..."
sudo tee $ROOT/etc/fstab > /dev/null <<'EOF'
# <file system>   <mount point>   <type>    <options>                        <dump> <pass>
/dev/root         /               ext4      rw,noauto                        0      1
proc              /proc           proc      defaults                         0      0
devpts            /dev/pts        devpts    gid=5,mode=620,ptmxmode=0666     0      0
tmpfs             /dev/shm        tmpfs     mode=1777                        0      0
tmpfs             /tmp            tmpfs     mode=1777                        0      0
tmpfs             /run            tmpfs     mode=0755,nosuid,nodev           0      0
sysfs             /sys            sysfs     defaults                         0      0
debugfs           /sys/kernel/debug debugfs defaults                         0      0
/dev/mmcblk0p1    /boot           vfat      defaults                         0      0
EOF

echo "Configuring inittab for OpenRC..."
sudo tee $ROOT/etc/inittab > /dev/null <<'EOF'
# OpenRC-managed inittab
::sysinit:/sbin/openrc sysinit
::sysinit:/sbin/openrc boot
::wait:/sbin/openrc default

# Console getty with autologin
console::respawn:/sbin/getty -L console 115200 vt100 -n -l /usr/local/bin/autologin

# Shutdown
::shutdown:/sbin/openrc shutdown
EOF

echo "Setting up chroot environment..."
sudo mount --bind /dev $ROOT/dev
sudo mount --bind /proc $ROOT/proc
sudo mount --bind /sys $ROOT/sys

echo "Set dropbear config"
sudo mkdir -p $ROOT/etc/conf.d/
sudo tee $ROOT/etc/conf.d/dropbear > /dev/null <<'EOF'
DROPBEAR_OPTS="-p 22"
EOF

echo "Setup firmware..."
sudo mkdir -p $ROOT/etc/local.d/
sudo tee $ROOT/etc/local.d/99milkv-duo.start > /dev/null <<'EOF'
#!/bin/sh
export USERDATAPATH=/mnt/data/
export SYSTEMPATH=/mnt/system/

echo "Loading Milk-V Duo S kernel modules..."

if [ -d "$SYSTEMPATH/ko" ]; then
    for module_file in "$SYSTEMPATH/ko"/*.ko; do
        if [ -f "$module_file" ]; then
            module_name=$(basename "$module_file")
            # Special handling for cvi_vc_driver with parameters
            if [ "$module_name" = "cvi_vc_driver.ko" ]; then
                insmod "$module_file" MaxVencChnNum=9 MaxVdecChnNum=9 2>/dev/null || true
            else
                insmod "$module_file" 2>/dev/null || true
            fi
        fi
    done
fi

echo "Starting hardware initialization..."

if [ -f "$SYSTEMPATH/duo-init.sh" ]; then
    . "$SYSTEMPATH/duo-init.sh" &
fi

if [ -f "$SYSTEMPATH/blink.sh" ]; then
    . "$SYSTEMPATH/blink.sh" &
fi

if [ -f "$SYSTEMPATH/usb.sh" ]; then
    . "$SYSTEMPATH/usb.sh" &
fi

if [ -f "$USERDATAPATH/auto.sh" ]; then
    sleep 0.03
    . "$USERDATAPATH/auto.sh" &
elif [ -f "$SYSTEMPATH/auto.sh" ]; then
    sleep 0.03
    . "$SYSTEMPATH/auto.sh" &
fi

echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
dmesg -n 4 2>/dev/null || true
EOF

sudo chmod +x $ROOT/etc/local.d/99milkv-duo.start

echo "Installing and configuring packages in chroot..."

sudo chroot $ROOT /bin/sh -c '
set -e

apk update
apk add openssh ca-certificates e2fsprogs util-linux openrc chrony iproute2 tzdata dropbear avahi wpa_supplicant wireless-tools busybox-extras bc dbus busybox-openrc kmod

rc-update add devfs sysinit
rc-update add modules boot
rc-update add sysctl boot
rc-update add hostname boot
rc-update add bootmisc boot
rc-update add localmount boot
rc-update add root boot
rc-update add dmesg boot
rc-update add syslog boot
rc-update add dbus boot
rc-update add networking default
rc-update add local default
rc-update add crond default
rc-update add chronyd default
rc-update add dropbear default
rc-update add avahi-daemon default
rc-update add killprocs shutdown
rc-update add mount-ro shutdown
rc-update add savecache shutdown
rc-update add netwatcher default

ln -s /usr/share/zoneinfo/Etc/UTC /etc/localtime

echo "root:milkv" | chpasswd

echo "Chroot configuration complete"
' || {
	echo "Failed to configure chroot environment"
	exit 1
}

echo "Unmounting filesystems..."
sudo umount $ROOT/dev
sudo umount $ROOT/proc
sudo umount $ROOT/sys
sudo umount $BOOT
sudo umount $ROOT
sudo losetup -d "$LOOP"
sudo rm -rf $MOUNT

echo "============================================"
echo "Image setup complete!"
echo "============================================"
echo "SSH will be enabled on boot"

#!/usr/bin/env bash

set -e

base_dir=$(readlink -nf $(dirname $0)/../..)
source $base_dir/lib/prelude_apply.bash

disk_image=${work}/${stemcell_image_name}

if is_ppc64le; then
  # ppc64le guest images have a PReP partition
  # this and other code changes for ppc64le with input from Paulo Flabiano Smorigo @ IBM
  part_offset=2048s
  part_size=9MiB
else
  #reserve 200mib for esp boot
  part_size=$((${image_create_disk_size} - 201))
fi

dd if=/dev/null of=${disk_image} bs=1M seek=${image_create_disk_size} 2> /dev/null
parted --script ${disk_image} mklabel gpt
if is_ppc64le; then
  parted --script ${disk_image} mkpart primary $part_offset $part_size
  parted --script ${disk_image} set 1 boot on
  parted --script ${disk_image} set 1 prep on
  parted --script ${disk_image} mkpart primary ext4 $part_size 100%
else
  parted --script ${disk_image} mkpart primary ext2 1MiB $part_size
  parted --script ${disk_image} mkpart ESP fat32 $part_size 100% 
  parted --script ${disk_image} set 2 boot on
fi


# unmap the loop device in case it's already mapped
kpartx -dv ${disk_image}

# Map partition in image to loopback
device=$(losetup --show --find ${disk_image})
add_on_exit "losetup --verbose --detach ${device}"

if is_ppc64le; then
  device_partition=$(kpartx -sav ${device} | grep "^add" | grep "p2 " | grep -v "p1" | cut -d" "
  -f3)
else
  device_partition=$(kpartx -sav ${device} | grep "^add" | grep "p1 " | grep -v "p2" | cut -d" " -f3)
  esp_partition=$(kpartx -sav ${device} | grep "^add" | grep "p2 " | grep -v "p1" | cut -d" " -f3)
fi
kpartx -sav ${device}
add_on_exit "kpartx -dv ${device}"

loopback_dev="/dev/mapper/${device_partition}"

# Format partition
mkfs.ext4 ${loopback_dev}

# Mount partition
image_mount_point=${work}/mnt
mkdir -p ${image_mount_point}
mount ${loopback_dev} ${image_mount_point}
add_on_exit "umount ${image_mount_point}"

#mount ESP
if ! is_ppc64le; then
loopback_esp_dev="/dev/mapper/${esp_partition}"
mkfs.vfat ${loopback_esp_dev}
fi

# Copy root
time rsync -aHA $chroot/ ${image_mount_point}

if is_ppc64le; then
  # Add Xen hypervisor console support
  cat > ${image_mount_point}/etc/init/hvc0.conf <<HVC_CONF

start on stopped rc RUNLEVEL=[2345]
stop on runlevel [!2345]

respawn
exec /sbin/getty -8 38400 hvc0
HVC_CONF
fi

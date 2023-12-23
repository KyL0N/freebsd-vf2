#!/bin/sh

set -euo pipefail

BASE_URL=https://download.freebsd.org/snapshots/riscv/riscv64/ISO-IMAGES/14.0
BASE_IMAGE=FreeBSD-14.0-STABLE-riscv-riscv64-GENERICSD-20231216-2ef9079ece5a-266002.img
#BASE_IMAGE=FreeBSD-14.0-CURRENT-riscv-riscv64-GENERICSD-20230420-f369f10dd812-262341.img

# dtb for bsd
DTB_FILE=jh7110-starfive-visionfive-2-v1.3b.dtb

# get base image
if [ ! -f $BASE_IMAGE ] ; then
  curl -LOC - $BASE_URL/$BASE_IMAGE.xz
  xz -kd $BASE_IMAGE.xz
fi

# get dtb
#if [ ! -f $DTB_FILE ] ; then
#  curl -LOC - https://github.com/starfive-tech/VisionFive2/releases/download/VF2_v2.5.0/$DTB_FILE
#fi


# attach the image, so we can extract the partition info
mdconfig -a -t vnode -f $BASE_IMAGE -u 0

# extract the esp and root partitions into their own files
echo 'Extracting EFI partition image...'
dd if=$BASE_IMAGE of=efi.img bs=512 $(gpart show -l /dev/md0 | grep efi | awk '{ printf "skip=%d count=%d", $1, $2 }')
echo 'Extracting root partition image...'
dd if=$BASE_IMAGE of=root.img bs=512 $(gpart show -l /dev/md0 | grep rootfs | awk '{ printf "skip=%d count=%d", $1, $2 }')

# unmount it
mdconfig -d -u 0


# mount the esp image to put the dtb in
echo 'Adding VisionFive2 dtb to EFI image...'
mdconfig -a -t vnode -f efi.img -u 0
mount_msdosfs /dev/md0 /mnt
mkdir -p /mnt/dtb/starfive
cp -v $DTB_FILE /mnt/dtb/starfive/jh7110-starfive-visionfive-2-v1.3b.dtb
umount /dev/md0
mdconfig -d -u 0


# now mount the extracted image
echo 'Customizing root image...'
#truncate -s +2G root.img
mdconfig -a -t vnode -f root.img -u 0
#growfs -y /dev/md0
mount /dev/md0 /mnt
#rsync -av /riscv/ /mnt

# make updates
echo 'root_rw_mount="NO"' >> /mnt/etc/rc.conf
echo 'mmc_load="YES"' >> /mnt/boot/loader.conf
echo 'mmcsd_load="YES"' >> /mnt/boot/loader.conf
echo 'sdhci_load="YES"' >> /mnt/boot/loader.conf
echo 'sdio_load="YES"' >> /mnt/boot/loader.conf
rm -f /mnt/etc/fstab
touch /mnt/etc/fstab

echo 'Pausing for extra copyover:'
echo "New kernel & modules can be patched with sudo make CROSS_TOOLCHAIN=... TARGET_ARCH=risv64 DESTDIR=/mnt reinstallkernel (if you've already done buildkernel)"
echo "If this is done, or you're not patching, press enter to continue"
read ans
echo 'Continuing...'

# and unmount
umount /mnt
mdconfig -d -u 0


# and zip it up
echo 'Zipping compressed root image...'
mkuzip -A zstd -d -o root.img.uzip root.img 


# source and target mountpoints
mkdir -p /mnt/s /mnt/t


# create empty boot image
echo 'Creating boot image...'
truncate -s 2G boot.img
mdconfig -a -t vnode -f boot.img -u 1
newfs -L bootfs /dev/md1

# mount root and boot
mdconfig -a -t vnode -f root.img -u 0
mount -o ro /dev/md0 /mnt/s
mount /dev/md1 /mnt/t

# and copy over everything we need
echo 'Copying over files for the bootloader...'
cp -rv /mnt/s/boot/ /mnt/t/boot
cp -v root.img.uzip /mnt/t

# unmount it all
umount /mnt/s
umount /mnt/t
mdconfig -d -u 0
mdconfig -d -u 1


# build the final image
echo 'Building final image...'
mkimg -s gpt -f raw -p efi/esp:=efi.img -p freebsd-ufs/boot:=boot.img -o vf2.img
echo 'Done.'

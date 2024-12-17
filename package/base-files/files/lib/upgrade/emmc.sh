# Copyright (C) 2021 OpenWrt.org

. /lib/functions.sh

emmc_upgrade_tar() {
	local tar_file="$1"
	[ "$CI_KERNPART" -a -z "$EMMC_KERN_DEV" ] && export EMMC_KERN_DEV="$(find_mmc_part $CI_KERNPART $CI_ROOTDEV)"
	[ "$CI_ROOTPART" -a -z "$EMMC_ROOT_DEV" ] && export EMMC_ROOT_DEV="$(find_mmc_part $CI_ROOTPART $CI_ROOTDEV)"
	[ "$CI_DATAPART" -a -z "$EMMC_DATA_DEV" ] && export EMMC_DATA_DEV="$(find_mmc_part $CI_DATAPART $CI_ROOTDEV)"
	local has_kernel
	local has_rootfs
	local board_dir=$(tar tf "$tar_file" | grep -m 1 '^sysupgrade-.*/$')
	board_dir=${board_dir%/}

	tar tf "$tar_file" ${board_dir}/kernel 1>/dev/null 2>/dev/null && has_kernel=1
	tar tf "$tar_file" ${board_dir}/root 1>/dev/null 2>/dev/null && has_rootfs=1

	[ "$has_rootfs" = 1 -a "$EMMC_ROOT_DEV" ] && {
		# Invalidate kernel image while rootfs is being written
		[ "$has_kernel" = 1 -a "$EMMC_KERN_DEV" ] && {
			dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 count=8
			sync
		}

		export EMMC_ROOTFS_BLOCKS=$(($(tar xf "$tar_file" ${board_dir}/root -O | dd of="$EMMC_ROOT_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))
		# Account for 64KiB ROOTDEV_OVERLAY_ALIGN in libfstools
		EMMC_ROOTFS_BLOCKS=$(((EMMC_ROOTFS_BLOCKS + 127) & ~127))
		sync
	}

	[ "$has_kernel" = 1 -a "$EMMC_KERN_DEV" ] && export EMMC_KERNEL_BLOCKS=$(($(tar xf "$tar_file" ${board_dir}/kernel -O | dd of="$EMMC_KERN_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))

	if [ -z "$UPGRADE_BACKUP" ]; then
		if [ "$EMMC_DATA_DEV" ]; then
			emmc_format_overlay "$EMMC_DATA_DEV" 0
		elif [ "$EMMC_ROOTFS_BLOCKS" ]; then
			emmc_format_overlay "$EMMC_ROOT_DEV" "$EMMC_ROOTFS_BLOCKS"
		elif [ "$EMMC_KERNEL_BLOCKS" ]; then
			emmc_format_overlay "$EMMC_KERN_DEV" "$EMMC_KERNEL_BLOCKS"
		fi
	fi
}

emmc_upgrade_fit() {
	local fit_file="$1"
	[ "$CI_KERNPART" -a -z "$EMMC_KERN_DEV" ] && export EMMC_KERN_DEV="$(find_mmc_part $CI_KERNPART $CI_ROOTDEV)"

	if [ "$EMMC_KERN_DEV" ]; then
		export EMMC_KERNEL_BLOCKS=$(($(get_image "$fit_file" | fwtool -i /dev/null -T - | dd of="$EMMC_KERN_DEV" bs=512 2>&1 | grep "records out" | cut -d' ' -f1)))

		[ -z "$UPGRADE_BACKUP" ] && dd if=/dev/zero of="$EMMC_KERN_DEV" bs=512 seek=$EMMC_KERNEL_BLOCKS count=8
	fi
}

emmc_copy_config() {
	if [ "$EMMC_DATA_DEV" ]; then
		emmc_format_overlay "$EMMC_DATA_DEV" 0
	elif [ "$EMMC_ROOTFS_BLOCKS" ]; then
		emmc_format_overlay "$EMMC_ROOT_DEV" "$EMMC_ROOTFS_BLOCKS"
	elif [ "$EMMC_KERNEL_BLOCKS" ]; then
		emmc_format_overlay "$EMMC_KERN_DEV" "$EMMC_KERNEL_BLOCKS"
	fi
}

emmc_do_upgrade() {
	local file_type=$(identify_magic_long "$(get_magic_long "$1")")

	case "$file_type" in
		"fit")  emmc_upgrade_fit $1;;
		*)      emmc_upgrade_tar $1;;
	esac
}

emmc_format_overlay() {
	local FORMAT_DEV=$1
	local OFFSET_BLOCKS=$2

	# keep sure its unbound
	losetup --detach-all || {
		echo "Failed to detach all loop devices. Skip this try."
		reboot -f
	}

	local LOOPDEV="$(losetup -f)"
	losetup -o $(($OFFSET_BLOCKS*512)) $LOOPDEV $FORMAT_DEV || {
		echo "Failed to mount looped rootfs_data."
		sleep 10
		reboot -f
	}

	mkfs.ext4 -F -L rootfs_data $LOOPDEV
	if [ -n "$UPGRADE_BACKUP" ]; then
		mkdir /tmp/new_root
		mount -t ext4 $LOOPDEV /tmp/new_root && {
			echo "Saving config to rootfs_data."
			cp -v "$UPGRADE_BACKUP" "/tmp/new_root/$BACKUP_FILE"
			umount /tmp/new_root
		}
	fi

	# Cleanup
	losetup -d $LOOPDEV >/dev/null 2>&1
	sync
}
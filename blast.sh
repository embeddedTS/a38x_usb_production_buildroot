#!/bin/sh

mkdir /mnt/sd
mkdir /mnt/emmc
mkdir /mnt/sata
mkdir /tmp/logs

# Turn on both LEDs to show it has started
ts7800ctl -n
ts7800ctl -g

### FPGA ###
ls /mnt/usb/ts7800-fpga-*.rpd > /dev/null 2>&1
if [ "$?" = "0" ]; then
	FPGAFILE=$(ls /mnt/usb/ts7800-fpga*.rpd)
	NEWREV=${FPGAFILE%.rpd}
	NEWREV=${NEWREV:24}

	eval $(ts7800ctl -i)
	fpga_rev=$(printf "%d\n" $fpga_rev)

	if [ "$fpga_rev" -lt "$NEWREV" ]; then
		echo "FPGA $fpga_rev is out of date, updating to $NEWREV and rebooting"
		load_fpga_flash $FPGAFILE 
		# No point to verify.  If it works we will come back 
		# around after a reboot and pass.  If it fails, we can't
		# recover, or even blink the leds since they are on the fpga
		# This should only happen if there is a power interruption while programming anyway
		reboot -f
	fi
fi

### MicroSD ###
if [ -e /mnt/usb/sdimage.tar.xz ]; then
	echo "======= Writing SD card filesystem ========"

	(
# Don't touch the newlines or add tabs/spaces from here to EOF
fdisk /dev/tssdcarda <<EOF
o
n
p
1


w
EOF
# </fdisk commands>
		if [ $? != 0 ]; then
			echo "fdisk tssdcard" >> /tmp/failed
		fi

		mkfs.ext4 /dev/tssdcarda1 -q < /dev/null
		if [ $? != 0 ]; then
			echo "mke2fs tssdcarda" >> /tmp/failed
		fi
		mount /dev/tssdcarda1 /mnt/sd/
		if [ $? != 0 ]; then
			echo "mount tssdcarda" >> /tmp/failed
		fi
		xzcat /mnt/usb/sdimage.tar.xz | tar -x -C /mnt/sd
		if [ $? != 0 ]; then
			echo "tar tssdcarda" >> /tmp/failed
		fi
		sync

		if [ -e "/mnt/sd/md5sums.txt" ]; then
			LINES=$(wc -l /mnt/sd/md5sums.txt  | cut -f 1 -d ' ')
			if [ $LINES = 0 ]; then
				echo "==========MD5sum file blank==========="
				echo "tssdcarda1 md5sum file is blank" >> /tmp/failed
			fi
			# Drop caches so we have to reread all files
			echo 3 > /proc/sys/vm/drop_caches
			cd /mnt/sd/
			md5sum -c md5sums.txt > /tmp/sd_md5sums
			if [ $? != 0 ]; then
				echo "==========SD VERIFY FAILED==========="
				echo "tssdcarda1 filesystem verify" >> /tmp/failed
			fi
			cd /
		fi

		umount /mnt/sd/
	) > /tmp/logs/sd-writefs 2>&1 &
elif [ -e /mnt/usb/sdimage.dd.xz ]; then
	echo "======= Writing SD card disk image ========"
	(
		xzcat /mnt/usb/sdimage.dd.xz | dd bs=4M of=/dev/tssdcarda
		if [ -e /mnt/usb/sdimage.dd.md5 ]; then
			BYTES="$(xzcat /mnt/usb/sdimage.dd.xz  | wc -c)"
			EXPECTED="$(cat /mnt/usb/sdimage.dd.md5 | cut -f 1 -d ' ')"
			ACTUAL=$(dd if=/dev/tssdcarda bs=4M | dd bs=1 count=$BYTES | md5sum)
			if [ "$ACTUAL" != "$EXPECTED" ]; then
				echo "tssdcarda dd verify" >> /tmp/failed
			fi
		fi
	) > /tmp/logs/sd-writeimage 2>&1 &
fi

### EMMC ###
if [ -e /mnt/usb/emmcimage.tar.xz ]; then
	echo "======= Writing eMMC card filesystem ========"
	(

# Don't touch the newlines or add tabs from here to EOF
fdisk /dev/mmcblk0 <<EOF
o
n
p
1


w
EOF
# </fdisk commands>
		if [ $? != 0 ]; then
			echo "fdisk mmcblk0" >> /tmp/failed
		fi
		mkfs.ext4 -O ^metadata_csum,^64bit /dev/mmcblk0p1 -q < /dev/null
		if [ $? != 0 ]; then
			echo "mke2fs mmcblk0" >> /tmp/failed
		fi
		mount /dev/mmcblk0p1 /mnt/emmc/
		if [ $? != 0 ]; then
			echo "mount mmcblk0" >> /tmp/failed
		fi
		xzcat /mnt/usb/emmcimage.tar.xz | tar -x -C /mnt/emmc
		if [ $? != 0 ]; then
			echo "tar mmcblk0" >> /tmp/failed
		fi
		sync

		if [ -e "/mnt/emmc/md5sums.txt" ]; then
			LINES=$(wc -l /mnt/emmc/md5sums.txt  | cut -f 1 -d ' ')
			if [ $LINES = 0 ]; then
				echo "==========MD5sum file blank==========="
				echo "mmcblk0 md5sum file is blank" >> /tmp/failed
			fi
			# Drop caches so we have to reread all files
			echo 3 > /proc/sys/vm/drop_caches
			cd /mnt/emmc/
			md5sum -c md5sums.txt > /tmp/emmc_md5sums
			if [ $? != 0 ]; then
				echo "mmcblk0 filesystem verify" >> /tmp/failed
			fi
			cd /
		fi

		umount /mnt/emmc/
	) > /tmp/logs/emmc-writefs 2>&1 &
elif [ -e /mnt/usb/emmcimage.dd.xz ]; then
	echo "======= Writing eMMC disk image ========"
	(
		xzcat /mnt/usb/emmcimage.dd.xz | dd bs=4M of=/dev/mmcblk0
		if [ -e /mnt/usb/emmcimage.dd.md5 ]; then
			BYTES="$(xzcat /mnt/usb/emmcimage.dd.xz  | wc -c)"
			EXPECTED="$(cat /mnt/usb/emmcimage.dd.md5 | cut -f 1 -d ' ')"
			ACTUAL=$(dd if=/dev/mmcblk0 bs=4M | dd bs=1 count=$BYTES | md5sum)
			if [ "$ACTUAL" != "$EXPECTED" ]; then
				echo "mmcblk0 dd verify" >> /tmp/failed
			fi
		fi
	) > /tmp/logs/emmc-writeimage 2>&1 &
fi

### SATA ###
if [ -e /mnt/usb/sataimage.tar.xz -o -e /mnt/usb/sataimage.dd.xz ]; then
	# Sanity check SATA has sda1.  It should, but if there is any issue
	# with the drive it may not be recognized and this would be the usb
	readlink /sys/class/block/sda | grep sata
	if [ $? != 0 ]; then
		echo "sata not found" >> /tmp/failed
	else 
		if [ -e /mnt/usb/sataimage.tar.xz ]; then
			echo "======= Writing SATA drive filesystem ========"
			(
				# Don't touch the newlines or add tabs from here to EOF
				fdisk /dev/sda <<EOF
o
n
p
1


w
EOF
				# </fdisk commands>
				if [ $? != 0 ]; then
					echo "fdisk sda1" >> /tmp/failed
				fi

				mkfs.ext4 -O ^metadata_csum,^64bit /dev/sda1 -q < /dev/null
				if [ $? != 0 ]; then
					echo "mke2fs sda1" >> /tmp/failed
				fi
				mount /dev/sda1 /mnt/sata/
				if [ $? != 0 ]; then
					echo "mount sda1" >> /tmp/failed
				fi
				xzcat /mnt/usb/sataimage.tar.xz | tar -x -C /mnt/sata/
				if [ $? != 0 ]; then
					echo "tar sda1" >> /tmp/failed
				fi
				sync

				if [ -e "/mnt/sata/md5sums.txt" ]; then
					# Drop caches so we have to reread all files
					echo 3 > /proc/sys/vm/drop_caches
					cd /mnt/sata/
					md5sum -c md5sums.txt > /tmp/sata_md5sums
					if [ $? != 0 ]; then
						echo "sda1 filesystem verify" >> /tmp/failed
					fi
					cd /
				fi

				umount /mnt/sata/
			) > /tmp/logs/sata-writefs 2>&1 &
		elif [ -e /mnt/usb/sataimage.dd.xz ]; then
			echo "======= Writing SATA drive disk image ========"
			(
				xzcat /mnt/usb/sataimage.dd.xz | dd bs=4M of=/dev/sda
				if [ -e /mnt/usb/sataimage.dd.md5 ]; then
					BYTES="$(xzcat /mnt/usb/sataimage.dd.xz  | wc -c)"
					EXPECTED="$(cat /mnt/usb/sataimage.dd.md5 | cut -f 1 -d ' ')"
					ACTUAL=$(dd if=/dev/sda bs=4M | dd bs=1 count=$BYTES | md5sum)
					if [ "$ACTUAL" != "$EXPECTED" ]; then
						echo "sda1 dd verify" >> /tmp/failed
					fi
				fi
			) > /tmp/logs/sata-writeimage 2>&1 &
		fi
	fi
fi

### eMMC boot partition (U-boot) ###
if [ -e /mnt/usb/u-boot.kwb ]; then
	(
		echo 0 > /sys/block/mmcblk0boot0/force_ro
		dd if=/mnt/usb/u-boot.kwb of=/dev/mmcblk0boot0 bs=1024
		if [ -e /mnt/usb/u-boot.kwb.md5 ]; then
			sync
			# Flush any buffer cache
			echo 3 > /proc/sys/vm/drop_caches

			BYTES="$(ls -l /mnt/usb/u-boot.kwb | sed -e 's/[^ ]* *[^ ]* *[^ ]* *[^ ]* *//' -e 's/ .*//')"
			EXPECTED="$(cat /mnt/usb/u-boot.kwb.md5 | cut -f 1 -d ' ')"

			# Read back from spi flash
			dd if=/dev/mmcblk0boot0 of=/tmp/uboot-verify.dd bs=1024 count=$(($BYTES/1024)) 2> /dev/null
			# truncate extra from last block
			dd if=/tmp/uboot-verify.dd of=/tmp/uboot-verify.imx bs=1 count="$BYTES" 2> /dev/null
			UBOOT_FLASH="$(md5sum /tmp/uboot-verify.imx | cut -f 1 -d ' ')"

			if [ "$UBOOT_FLASH" != "$EXPECTED" ]; then
				echo "u-boot verify failed" >> /tmp/failed
			fi
		fi

	) > /tmp/logs/emmc-bootimg &
fi

sync
wait

# Blink green led if it works.  Blink red if bad things happened
(
if [ ! -e /tmp/failed ]; then
	ts7800ctl -F
	ts7800ctl -G
	echo "All images were written correctly!"
	while true; do
		sleep 1
		ts7800ctl -g
		sleep 1
		ts7800ctl -G
	done
else
	ts7800ctl -F
	ts7800ctl -G
	echo "One or more images failed! $(cat /tmp/failed)"
	echo "Check /tmp/logs for more information."
	while true; do
		sleep 1
		ts7800ctl -n
		sleep 1
		ts7800ctl -F
	done
fi
) &

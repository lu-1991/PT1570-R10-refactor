# SPDX-License-Identifier: GPL-2.0-only
# 插入到 target/linux/rtl9617c/image/Makefile 的 $(eval $(call BuildImage)) 之前。
# 纯 refactor (Taurus) 基线 d39cfc6；产物规则与上游 tianyi_tyfza1_2p5g 一致。
# 2026-11-25 重写：
#   * PON 包换成外部 feed 的 rtl9617c-pon-control / luci-app-rtl9617c-pon；
#   * WiFi 换成上游 mac80211 backport 方案：kmod-rtw89-8852ce + ap 固件 +
#     kmod-rtw89-8192xbe（后者在 realtek.mk 里依赖 rtl8192xbe-ap-firmware）；
#   * wpad 由 mbedtls 换成 basic-mbedtls（与上游 tianyi 板一致，避免与
#     wpad-mbedtls 抢包）。

define Device/youhua_pt1570_r10
  DEVICE_VENDOR := Youhua
  DEVICE_MODEL := PT1570-R10
  # 只影响显示文本，不进文件名、不参与 sysupgrade 机型校验（那用 SUPPORTED_DEVICES）。
  DEVICE_VARIANT := UBI
  # profile 名下划线会被转成 youhua,pt1570,r10，与 DTS compatible 对不上，
  # 必须显式追加正确值 youhua,pt1570-r10。
  SUPPORTED_DEVICES += youhua,pt1570-r10
  DEVICE_DTS := rtl9617c-pt1570-r10
  DEVICE_DTS_DIR := ../dts
  DEVICE_PACKAGES := fitblk rtl9617c-pon-control luci-app-rtl9617c-pon \
	wpad-basic-mbedtls kmod-rtw89-8852ce rtl8852ce-ap-firmware \
	kmod-rtw89-8192xbe rtl8192xbe-ap-firmware \
	ubi-utils nand-utils iw wifi-scripts wireless-regdb \
	kmod-gpio-button-hotplug kmod-usb3 kmod-usb-storage kmod-usb-storage-uas \
	block-mount kmod-fs-vfat kmod-fs-ext4 kmod-nls-utf8 \
	luci luci-ssl luci-proto-ppp luci-app-firewall uhttpd uhttpd-mod-ubus \
	firewall4 dnsmasq
  KERNEL := kernel-bin | gzip
  KERNEL_INITRAMFS := kernel-bin | gzip | \
	fit gzip $$(KDIR)/image-rtl9617c-pt1570-r10.dtb with-initrd | pad-to 128k
  KERNEL_INITRAMFS_SUFFIX := -recovery.itb
  FILESYSTEMS := squashfs
  IMAGES := sysupgrade.itb
  IMAGE/sysupgrade.itb := append-kernel | \
	fit gzip $$(KDIR)/image-rtl9617c-pt1570-r10.dtb external-static-with-rootfs | \
	pad-rootfs | append-metadata
endef
TARGET_DEVICES += youhua_pt1570_r10

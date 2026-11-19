#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# PT1570-R10 云端拉库脚本
# 由 GitHub Actions 调用：从上游拉取 OpenWrt 源码，叠加真机验证的硬件层与
# PT1570-R10 设备适配。本地适配仓库只需保留少量小文件，无需上传 292MB 源码树。
#
# 用法：bash scripts/cloud-pull.sh [源码目录名，默认 openwrt]
# 需在网络可用、已安装 git 的环境执行。

set -euo pipefail

SRC="${1:-openwrt}"
ADAPTER="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

REFACTOR_COMMIT="ae4aeac45a70be1bdf68af65cbbacb360f201b27"
HARDWARE_COMMIT="20b4cf4490ca55cc406d07e391691efa8cd8a087"
UPSTREAM="https://github.com/lyq1996/rtl9617c-openwrt.git"
HW_BRANCH="feature/pt1500-h10-openwrt-fixes"

echo "=== [1/6] 克隆上游 refactor 基线 (${REFACTOR_COMMIT:0:7}) ==="
cd "$ADAPTER"
if [ -d "$SRC/.git" ]; then
  echo "源码目录已存在，复用：$SRC"
else
  git clone --depth 1 -b refactor "$UPSTREAM" "$SRC"
fi
cd "$SRC"
ACTUAL="$(git rev-parse HEAD)"
echo "当前 HEAD: ${ACTUAL:0:12}"
if [ "$ACTUAL" != "$REFACTOR_COMMIT" ]; then
  echo "WARN: refactor 基线已前进（${ACTUAL:0:7}），继续用当前 HEAD；若编译异常请固定 $REFACTOR_COMMIT"
fi

echo "=== [2/6] 拉取真机验证的硬件层 commit (${HARDWARE_COMMIT:0:7}) ==="
if ! git fetch -q --depth 1 origin "$HARDWARE_COMMIT"; then
  echo "按 SHA 拉取失败，退化为拉取分支 $HW_BRANCH"
  git fetch -q --depth 1 origin "$HW_BRANCH"
fi
HW_REF="$(git rev-parse FETCH_HEAD)"
echo "硬件层来源: ${HW_REF:0:12}"

echo "=== [3/6] 覆盖 target/linux/rtl9617c 为完整硬件层 ==="
# 用已验证 commit 的整棵 target 树替换，确保驱动/patch/dtsi 内部一致。
rm -rf target/linux/rtl9617c
git checkout -q "$HW_REF" -- target/linux/rtl9617c

echo "=== [4/6] 补齐 PON/WiFi/USB/LED 驱动包与工具修复 ==="
git checkout -q "$HW_REF" -- \
  package/tyfza1-pon-control \
  package/luci-app-tyfza1-pon \
  package/luci-theme-argon \
  package/pt1500-storage \
  tools/mtd-utils/Makefile \
  package/network/config/wifi-scripts/files-ucode/lib/netifd/wireless/mac80211.sh \
  package/network/config/wifi-scripts/files-ucode/usr/bin/iwinfo \
  package/network/config/wifi-scripts/files-ucode/usr/share/ucode/iwinfo.uc

echo "=== [5/6] 应用 PT1570-R10 设备适配（DTS + 2 个补丁） ==="
install -m 0644 "$ADAPTER/board/dts/rtl9617c-pt1570-r10.dts" target/linux/rtl9617c/dts/
git apply --verbose "$ADAPTER/board/patches/901-pt1570-image.patch"
git apply --verbose "$ADAPTER/board/patches/902-pt1570-sysupgrade.patch"

echo "=== [6/6] 校验拉取与适配结果 ==="
fail=0
ck() { if eval "$2"; then echo "  OK   $1"; else echo "  FAIL $1"; fail=1; fi; }
ck "PT1570-R10 DTS"        "test -f target/linux/rtl9617c/dts/rtl9617c-pt1570-r10.dts"
ck "4GE 板级 DTSI"           "test -f target/linux/rtl9617c/dts/rtl9617c-tyfza1-4ge.dts"
ck "PCIe 驱动"               "test -d target/linux/rtl9617c/files-6.18/drivers/pci"
ck "WiFi 驱动"               "test -d target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap"
ck "USB PHY 驱动"            "test -f target/linux/rtl9617c/files-6.18/drivers/phy/phy-rtl9617c-usb.c"
ck "LED 驱动"                "test -d target/linux/rtl9617c/files-6.18/drivers/leds"
ck "PON 控制包"              "test -f package/tyfza1-pon-control/Makefile"
ck "LuCI PON 包"             "test -f package/luci-app-tyfza1-pon/Makefile"
ck "image profile"           "grep -q 'Device/youhua_pt1570_r10' target/linux/rtl9617c/image/Makefile"
ck "sysupgrade 白名单"       "grep -q 'youhua,pt1570-r10' target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"
ck "FIT blk 内核配置"        "grep -q '^CONFIG_UIMAGE_FIT_BLK=y$' target/linux/rtl9617c/config-6.18"
ck "MTD rootfs 配置"         "grep -q '^CONFIG_MTD_ROOTFS_ROOT_DEV=y$' target/linux/generic/config-6.18"
if [ "$fail" -ne 0 ]; then
  echo "ERROR: 适配校验未通过" >&2
  exit 1
fi
echo "云端拉库与适配完成，源码目录：$SRC"

# 输出给后续步骤使用的路径（GitHub Actions 可通过 $GITHUB_ENV 读取）
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "WRT_SRC=$SRC" >> "$GITHUB_ENV"
fi

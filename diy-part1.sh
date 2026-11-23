#!/bin/bash
# ================================================================
# diy-part1.sh —— 源码树定制（feeds 安装之后、加载 .config 之前）
# 运行目录：OpenWrt 源码根（$BUILD_ROOT/openwrt）
#
# diy-part1 = 往源码树里"注入"，diy-part2 = 对 .config "定型"。
#
# 本脚本做三件事（全部幂等，重复执行安全）：
#   1) 注入 PT1570-R10 板级支持（DTS + image/Makefile + sysupgrade 白名单）
#   2) 移植上游官方 rtw89 驱动（替换逆向 rtl_ax_ap 方案）：
#      驱动源码 + 内核补丁 740 + config（rtw89 on / rtl_ax_ap off / NVMEM on）
#      + DTS factory 校准 cell 绑定。rtw89 直读 factory 卷的 TYFC0003，
#      绕开逆向驱动的 PE/TSSI/RFE50/symlink/284 字节一连串坑。
#   3) 修补上游包内脚本（fitblk 上限 + R10 面板端口命名），
#      校准提取脚本 tyfza1-factory 仅供 PON/BOSA 使用，不再参与 WiFi。
# ================================================================
set -euo pipefail

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$PWD}"
BOARD="r10"          # R10-only，固定值
DTS_STATUS="${DTS_STATUS:-verified}"

echo "=========================================="
echo "diy-part1: 注入 PT1570-R10 板级支持"
echo "  assets = $ASSETS"
echo "  wrt    = $WRT"
echo "=========================================="

test -f "$WRT/package/base-files/files/bin/config_generate" \
  || { echo "ERROR: $WRT 不是 OpenWrt 源码根" >&2; exit 1; }

# ---- 1. 板级支持 ----
PT1570_BOARD="$BOARD" ASSETS="$ASSETS" WRT="$WRT" DTS_STATUS="$DTS_STATUS" \
  bash "$ASSETS/scripts/apply-board.sh"

# ---- 2. rtw89 官方 WiFi 驱动移植（必须在任何 make 之前：内核展开 files-6.18 要用）----
ASSETS="$ASSETS" WRT="$WRT" bash "$ASSETS/scripts/overlay-rtw89.sh"

# ---- 3. 上游包内修补（fitblk 上限 / R10 端口命名）----
ASSETS="$ASSETS" WRT="$WRT" bash "$ASSETS/scripts/patch-upstream.sh"

echo "🎉 diy-part1.sh 完成"

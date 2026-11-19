#!/bin/bash
# ================================================================
# diy-part1.sh —— 源码树定制（feeds 安装之后、加载 .config 之前）
# 运行目录：OpenWrt 源码根（$BUILD_ROOT/openwrt）
#
# diy-part1 = 往源码树里"注入"，diy-part2 = 对 .config "定型"。
#
# 本脚本做三件事（全部幂等，重复执行安全）：
#   1) 注入 PT1570-R10 板级支持（DTS + image/Makefile + sysupgrade 白名单）
#   2) 把 rtl_ax_ap 驱动整套替换为已真机验证的 PT1570 版本
#      （PE IRAM revert；含 pe-tx-code.h，md5 校验在 overlay 脚本内）
#      ⚠️ 因此 workflow 不再需要 "Build PE firmware" 现场编译步骤——
#         那一步编出的正是已知坏版 PE 头文件，会被这里直接覆盖。
#   3) 修补上游包内脚本（tyfza1-factory：flash-calibration.bin 必须是
#      精确 284 字节，4096 会 -EINVAL 导致两颗 WiFi 芯片 probe 失败）
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

# ---- 2. WiFi 驱动 overlay（必须在任何 make 之前：内核展开 files-6.18 要用）----
ASSETS="$ASSETS" WRT="$WRT" bash "$ASSETS/scripts/overlay-wifi-driver.sh"

# ---- 3. 上游包内修补（factory 校准提取 284 字节）----
ASSETS="$ASSETS" WRT="$WRT" bash "$ASSETS/scripts/patch-upstream.sh"

echo "🎉 diy-part1.sh 完成"

#!/bin/bash
# ================================================================
# diy-part1.sh —— 源码树定制（feeds 安装之后、加载 .config 之前）
# 运行目录：OpenWrt 源码根（$BUILD_ROOT/openwrt）
#
# diy-part1 = 往源码树里"注入"，diy-part2 = 对 .config "定型"。
#
# 2026-11-25 重写为纯 refactor (Taurus) 基线 d39cfc6：
#   1) 注入 PT1570-R10 板级支持（新写 Taurus DTS + Device + sysupgrade 白名单）
#   2) 主题切换 argon -> design（拉库 ucode 版 + 清厂商抢主题脚本）
#   3) 修补 fitblk 4MiB 上限（刷入态 /dev/fit0 挂根必需）
# 不再做：overlay-rtw89（上游已把 rtw89 改为 mac80211 backport + AP 固件包，
#         由 config/diy-part2 的 kmod 包符号启用）、tyfza1-factory 284 字节修补
#         与整套旧射频表/固件（新驱动把表编译进驱动、校准走 DTS nvmem cell、
#         固件由 rtl*-ap-firmware 包提供）、R10 xram 端口命名补丁
#         （Taurus NI 驱动直接读 DTS label，端口名已在 DTS 里定好）。
# ================================================================
set -euo pipefail

# 失败时给 GitHub 注解（run 页面顶部直接能看到是哪一行挂的），
# 避免再出现"只有 exit code 1、日志里什么都没打"的静默失败。
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "::error::diy-part1 第 $LINENO 行失败 rc=$rc：$BASH_COMMAND" >&2' ERR

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$PWD}"
BOARD="r10"          # R10-only，固定值
DTS_STATUS="${DTS_STATUS:-verified}"

echo "=========================================="
echo "diy-part1: 注入 PT1570-R10 板级支持（纯 refactor / Taurus）"
echo "  assets = $ASSETS"
echo "  wrt    = $WRT"
echo "=========================================="

test -f "$WRT/package/base-files/files/bin/config_generate" \
  || { echo "ERROR: $WRT 不是 OpenWrt 源码根" >&2; exit 1; }

# ---- 1. 板级支持 ----
PT1570_BOARD="$BOARD" ASSETS="$ASSETS" WRT="$WRT" DTS_STATUS="$DTS_STATUS" \
  bash "$ASSETS/scripts/apply-board.sh"

# ---- 2. 主题切换：拉库 ucode 版 design + 移除厂商 PON 包默认主题设置 ----
ASSETS="$ASSETS" WRT="$WRT" bash "$ASSETS/scripts/overlay-theme.sh"

# ---- 3. fitblk 上限修补（fit_do_upgrade / /dev/fit0 挂根必需）----
ASSETS="$ASSETS" WRT="$WRT" bash "$ASSETS/scripts/patch-upstream.sh"

echo "🎉 diy-part1.sh 完成"

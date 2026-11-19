#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-only
# PT1570-R10 云编译配置脚本
# 由 .github/workflows/build-pt1570-r10.yml 在 Configure 阶段调用。
# 作用：写默认 IP/主机名/SSID/时区/NTP，并在 make defconfig 之后重新断言
#       被 profile 依赖裁剪掉的软件包。

set -euo pipefail

[ -f package/base-files/files/bin/config_generate ] || {
  echo "ERROR: 必须在 OpenWrt 源码根目录执行本脚本" >&2
  exit 1
}

CFG="package/base-files/files/bin/config_generate"
WIFI_UC="package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc"

WRT_IP="${WRT_IP:-192.168.1.1}"
WRT_NAME="${WRT_NAME:-PT1570-R10}"
WRT_SSID="${WRT_SSID:-PT1570-R10}"
WRT_WORD="${WRT_WORD:-12345678}"

# ---- 1. 默认 LAN IP / 主机名 ----
sed -i "s/192\.168\.[0-9]*\.[0-9]*/$WRT_IP/g" "$CFG"
sed -i "s|set system\.@system\[-1\]\.hostname='[^']*'|set system.@system[-1].hostname='$WRT_NAME'|" "$CFG"
echo "customize: IP=$WRT_IP hostname=$WRT_NAME"

# ---- 2. SSID / WiFi 密码 ----
if [ -f "$WIFI_UC" ]; then
  sed -i "s/ssid '.*'/ssid '$WRT_SSID'/g; s/key '.*'/key '$WRT_WORD'/g" "$WIFI_UC"
  echo "customize: SSID=$WRT_SSID"
else
  echo "WARN: wifi-scripts mac80211.uc 未找到，跳过 SSID 设置" >&2
fi

# ---- 3. 时区 UTC+8 + 国内 NTP ----
sed -i "s|timezone='[^']*'|timezone='<+08>-8'|" "$CFG"
sed -i "s|zonename='[^']*'|zonename='Asia/Shanghai'|" "$CFG"
sed -i \
  -e "s|time\.apple\.com|ntp.aliyun.com|g" \
  -e "s|time1\.google\.com|time1.cloud.tencent.com|g" \
  -e "s|time\.cloudflare\.com|ntp.ntsc.ac.cn|g" \
  -e "s|pool\.ntp\.org|cn.pool.ntp.org|g" "$CFG"
echo "customize: timezone=Asia/Shanghai, NTP 国内源"

# ---- 4. 重新断言关键包（defconfig 之后调用） ----
ASSERT_PKGS="
CONFIG_PACKAGE_fitblk=y
CONFIG_PACKAGE_tyfza1-pon-control=y
CONFIG_PACKAGE_luci-app-tyfza1-pon=y
CONFIG_PACKAGE_kmod-rtl-ax-ap=y
CONFIG_PACKAGE_luci=y
CONFIG_PACKAGE_luci-ssl=y
CONFIG_PACKAGE_luci-theme-argon=y
CONFIG_PACKAGE_uhttpd=y
CONFIG_PACKAGE_uhttpd-mod-ubus=y
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_dnsmasq=y
CONFIG_PACKAGE_ucode-mod-math=y
"
echo "$ASSERT_PKGS" >> .config
echo "customize: 关键包已重新断言"

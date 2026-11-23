#!/bin/bash
# ================================================================
# overlay-rtw89.sh —— 把上游 refactor 官方 rtw89 WiFi 驱动移植到
# 20b4cf4 硬件层源码树（替换逆向 rtl_ax_ap 方案）。
#
# 来源：lyq1996/rtl9617c-openwrt @ fd909a3
#   "rtl9617c: add rtw89 wifi driver for rtl8192xbe and rtl8852ce"
#
# 为什么换：
#   逆向 rtl_ax_ap 方案在本仓库踩了 PE 引擎 / TSSI / RFE50 / calibration
#   symlink / 284 字节 / regdb 一连串坑，2.4G 真机始终搜不到。上游官方
#   rtw89 驱动直接从 factory 卷的 nvmem cell 读 TYFC0003 校准（mac/xtal/
#   gain/tssi 全解析），不依赖 /tmp 软链、不校验 size==284，从根上绕开。
#
# 硬件层（20b4cf4）与上游（5ba60e0）的 target 树完全不同（补丁集 100-215
# vs 300-740），所以不能整树 clone 上游。本脚本只移植 rtw89 相关四件套：
#   1. 驱动源码 6 个文件 -> target/linux/rtl9617c/files-6.18/.../rtw89/
#   2. 内核补丁 740      -> target/linux/rtl9617c/patches-6.18/
#   3. 内核 config       -> target/linux/rtl9617c/config-6.18
#      （开 rtw89 + NVMEM + MTD_UBI_NVMEM，关 rtl_ax_ap）
#   4. DTS nvmem 绑定    -> R10 DTS 的 &pcie0/&pcie1 wifi 节点
#      固件 rtw8192xb_fw.bin / rtw8852c_fw.bin 由 files/ 覆盖链落地
#      （files/lib/firmware/rtw89/，在 workflow 的 rootfs 步骤 cp）。
#
# 幂等：重复执行安全。任何一步不满足预期都 fail，绝不产出半套驱动。
# ================================================================
set -euo pipefail

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$PWD}"

fail() { echo "ERROR: $*" >&2; exit 1; }

DRV_SRC="$ASSETS/board/rtw89/driver"
PATCH_SRC="$ASSETS/board/rtw89/patches/740-wifi-rtw89-8192xb.patch"
DRV_DST="$WRT/target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtw89"
PATCH_DST="$WRT/target/linux/rtl9617c/patches-6.18/740-wifi-rtw89-8192xb.patch"
CFG="$WRT/target/linux/rtl9617c/config-6.18"
DTS="$WRT/target/linux/rtl9617c/dts/rtl9617c-pt1570-r10.dts"

for f in "$DRV_SRC" "$PATCH_SRC" "$CFG" "$DTS"; do
  [ -e "$f" ] || fail "缺少 $f"
done

echo "=========================================="
echo "overlay-rtw89: 官方驱动替换 rtl_ax_ap"
echo "  assets = $ASSETS"
echo "  wrt    = $WRT"
echo "=========================================="

# ---- 1. 驱动源码 ----
mkdir -p "$DRV_DST"
n=0
for f in rtw8192xb.c rtw8192xb.h rtw8192xb_table.c rtw8192xbe.c \
         rtw89_factory.c rtw89_factory.h; do
  [ -f "$DRV_SRC/$f" ] || fail "缺少驱动源文件 $DRV_SRC/$f"
  cp -f "$DRV_SRC/$f" "$DRV_DST/$f"
  n=$((n + 1))
done
[ "$n" -eq 6 ] || fail "驱动源文件数 $n != 6"
md5sum "$DRV_DST"/* | sha256sum | cut -d' ' -f1 > /tmp/rtw89-driver.sha256
echo "  驱动源码 $n 个文件已落地"

# ---- 2. 内核补丁 ----
cp -f "$PATCH_SRC" "$PATCH_DST"
grep -q 'RTL8192XB' "$PATCH_DST" \
  || fail "740 补丁落地后没有 RTL8192XB 标记"
echo "  内核补丁 740-wifi-rtw89-8192xb.patch 已落地"

# ---- 2b. 物理移除旧的 rtl_ax_ap 驱动（根因修复）----
# 201-native-radio.patch 会往内核注入两行：
#   +source "drivers/net/wireless/realtek/rtl_ax_ap/Kconfig"   -> 定义 config RTL_AX_AP
#   +obj-$(CONFIG_RTL_AX_AP)  += rtl_ax_ap/                    -> 递归编译该目录
# 只要这两行在，内核 Kconfig 就有 RTL_AX_AP 符号，syncconfig 在缺值时按
# tristate 默认重新打开(=m)，进而编译 rtl_ax_ap 并撞上已删除的 pe-tx-code.h
# （CI 连续两次同一报错）。改 config 的 not-set 不可靠——syncconfig 会覆盖。
# 彻底解法：从补丁里删掉这两行 + 删除驱动目录，让内核根本看不到该符号。
python3 - "$WRT" <<'PY'
import pathlib, sys
wrt = pathlib.Path(sys.argv[1])
patch = wrt / "target/linux/rtl9617c/patches-6.18/201-native-radio.patch"
if patch.exists():
    lines = patch.read_text(encoding="utf-8", errors="replace").splitlines()
    out = []
    removed = 0
    for ln in lines:
        s = ln.strip()
        if s == '+source "drivers/net/wireless/realtek/rtl_ax_ap/Kconfig"':
            removed += 1
            continue
        if s.startswith('+obj-$(CONFIG_RTL_AX_AP)'):
            removed += 1
            continue
        out.append(ln)
    patch.write_text('\n'.join(out) + '\n', encoding='utf-8', newline='\n')
    print(f'  201 补丁移除 rtl_ax_ap 注入 {removed} 行')
else:
    print('  201 补丁不存在，跳过')

drv = wrt / "target/linux/rtl9617c/files-6.18/drivers/net/wireless/realtek/rtl_ax_ap"
if drv.exists():
    import shutil
    shutil.rmtree(drv)
    print('  已删除 rtl_ax_ap 驱动目录')
else:
    print('  rtl_ax_ap 驱动目录不存在，跳过')
PY
# 断言：201 补丁和内核树里都不能再有 rtl_ax_ap / RTL_AX_AP 引用
! grep -rq 'rtl_ax_ap' "$WRT/target/linux/rtl9617c/patches-6.18/" \
  || fail "201 补丁仍有 rtl_ax_ap 引用（内核会重新编译旧驱动）"
! grep -rq 'CONFIG_RTL_AX_AP' "$WRT/target/linux/rtl9617c/files-6.18/drivers/net/wireless/" \
  || fail "内核源码树仍有 CONFIG_RTL_AX_AP 引用"
echo "  内核树已无 rtl_ax_ap 驱动（RTL_AX_AP 符号不再存在）"

# ---- 3. 内核 config ----
# 硬件层 config 默认：CONFIG_RTL_AX_AP=m，NVMEM 全关。rtw89 必须反过来。
# 用 python 逐行幂等处理：删旧符号 -> 追加新符号；保留其余原样。
python3 - "$CFG" <<'PY'
import pathlib, sys

p = pathlib.Path(sys.argv[1])
lines = p.read_text(encoding='utf-8').splitlines()

# 新块要写入的符号全集 —— 这些符号的旧行（=y/=m/not set）全部先删，
# 保证每个符号在新块里只有一行，避免 make defconfig 因重复符号告警/行为不定。
write_syms = (
    'CONFIG_WLAN_VENDOR_REALTEK', 'CONFIG_CFG80211',
    'CONFIG_CFG80211_DEVELOPER_WARNINGS',
    'CONFIG_CFG80211_REQUIRE_SIGNED_REGDB',
    'CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS',
    'CONFIG_CFG80211_DEFAULT_PS', 'CONFIG_CFG80211_DEBUGFS',
    'CONFIG_CFG80211_CRDA_SUPPORT', 'CONFIG_CFG80211_WEXT',
    'CONFIG_MAC80211', 'CONFIG_MAC80211_RC_MINSTREL',
    'CONFIG_MAC80211_RC_DEFAULT_MINSTREL',
    'CONFIG_MAC80211_LEDS', 'CONFIG_MAC80211_DEBUG_MENU',
    'CONFIG_RTW89', 'CONFIG_RTW89_CORE', 'CONFIG_RTW89_PCI',
    'CONFIG_RTW89_8192XB', 'CONFIG_RTW89_8192XBE',
    'CONFIG_RTW89_8852C', 'CONFIG_RTW89_8852CE',
    # 740 补丁/内核 Kconfig 里 RTW89 菜单下其余芯片符号：必须全部显式设置，
    # 否则 syncconfig 遇到 (NEW) 符号在非交互编译下报 Error 1（真机 CI 已踩）。
    'CONFIG_RTW89_8851BE', 'CONFIG_RTW89_8851BU',
    'CONFIG_RTW89_8852AE', 'CONFIG_RTW89_8852BE',
    'CONFIG_RTW89_8852BU', 'CONFIG_RTW89_8852BTE',
    'CONFIG_RTW89_8922AE', 'CONFIG_RTW89_DEBUGMSG',
    'CONFIG_NVMEM', 'CONFIG_NVMEM_LAYOUTS', 'CONFIG_NVMEM_SYSFS',
    'CONFIG_NVMEM_REALTEK_TAURUS_OTP', 'CONFIG_MTD_UBI_NVMEM',
    # 旧的逆向驱动符号：先删旧值（=m），下面 new 块显式写 not set。
    # 只删不写会让 syncconfig 视其为 NEW 并按 Kconfig 默认重新打开（=m），
    # 内核随即编译 rtl_ax_ap 并撞上已删除的 pe-tx-code.h（CI 已踩）。
    'CONFIG_RTL_AX_AP',
)

def is_target(line):
    s = line.strip()
    for sym in write_syms:
        if s == sym or s.startswith(sym + '=') or s == '# ' + sym + ' is not set':
            return True
    return False

lines = [l for l in lines if not is_target(l)]

# 上游 rtw89 内核配置口径（全部 built-in =y，不开 debug）。
# CFG80211_REQUIRE_SIGNED_REGDB / USE_KERNEL_REGDB_KEYS 关闭：与上游一致，
# 避免 world domain(00) NO-IR 让 5G AP 起不来（本仓库 regdb 仍随 files 落地）。
new = [
    '# ===== rtw89 official WiFi (from lyq1996/refactor fd909a3) =====',
    'CONFIG_WLAN_VENDOR_REALTEK=y',
    'CONFIG_CFG80211=y',
    '# CONFIG_CFG80211_DEVELOPER_WARNINGS is not set',
    '# CONFIG_CFG80211_REQUIRE_SIGNED_REGDB is not set',
    '# CONFIG_CFG80211_USE_KERNEL_REGDB_KEYS is not set',
    'CONFIG_CFG80211_DEFAULT_PS=y',
    '# CONFIG_CFG80211_DEBUGFS is not set',
    'CONFIG_CFG80211_CRDA_SUPPORT=y',
    '# CONFIG_CFG80211_WEXT is not set',
    'CONFIG_MAC80211=y',
    'CONFIG_MAC80211_RC_MINSTREL=y',
    'CONFIG_MAC80211_RC_DEFAULT_MINSTREL=y',
    '# CONFIG_MAC80211_LEDS is not set',
    # MAC80211_MESH / HAS_RC / RC_DEFAULT 保留硬件层原值（rtw89 不改这些）
    '# CONFIG_MAC80211_DEBUG_MENU is not set',
    'CONFIG_RTW89=y',
    'CONFIG_RTW89_CORE=y',
    'CONFIG_RTW89_PCI=y',
    'CONFIG_RTW89_8192XB=y',
    'CONFIG_RTW89_8192XBE=y',
    'CONFIG_RTW89_8852C=y',
    'CONFIG_RTW89_8852CE=y',
    # 必须显式 not set：否则 syncconfig 视其为 (NEW)，非交互编译直接 Error 1。
    '# CONFIG_RTW89_8851BE is not set',
    '# CONFIG_RTW89_8851BU is not set',
    '# CONFIG_RTW89_8852AE is not set',
    '# CONFIG_RTW89_8852BE is not set',
    '# CONFIG_RTW89_8852BU is not set',
    '# CONFIG_RTW89_8852BTE is not set',
    '# CONFIG_RTW89_8922AE is not set',
    '# CONFIG_RTW89_DEBUGMSG is not set',
    # 显式关闭旧逆向驱动：否则 syncconfig 按 Kconfig 默认(=m)重新启用，
    # 内核编译 rtl_ax_ap 会因缺 pe-tx-code.h 而 Stop（真机 CI 已踩）。
    '# CONFIG_RTL_AX_AP is not set',
    '# ===== nvmem: factory calibration cell for rtw89 =====',
    'CONFIG_NVMEM=y',
    'CONFIG_NVMEM_LAYOUTS=y',
    'CONFIG_NVMEM_SYSFS=y',
    'CONFIG_NVMEM_REALTEK_TAURUS_OTP=y',
    'CONFIG_MTD_UBI_NVMEM=y',
]
p.write_text('\n'.join(lines + new) + '\n', encoding='utf-8', newline='\n')
PY
for sym in CONFIG_RTW89=y CONFIG_RTW89_CORE=y CONFIG_RTW89_PCI=y \
           CONFIG_RTW89_8192XB=y CONFIG_RTW89_8192XBE=y \
           CONFIG_RTW89_8852C=y CONFIG_RTW89_8852CE=y \
           '# CONFIG_RTW89_8851BE is not set' \
           '# CONFIG_RTW89_8851BU is not set' \
           '# CONFIG_RTW89_8852AE is not set' \
           '# CONFIG_RTW89_8852BE is not set' \
           '# CONFIG_RTW89_8852BU is not set' \
           '# CONFIG_RTW89_8852BTE is not set' \
           '# CONFIG_RTW89_8922AE is not set' \
           '# CONFIG_RTW89_DEBUGMSG is not set' \
           CONFIG_NVMEM=y CONFIG_NVMEM_LAYOUTS=y CONFIG_NVMEM_SYSFS=y \
           CONFIG_NVMEM_REALTEK_TAURUS_OTP=y CONFIG_MTD_UBI_NVMEM=y; do
  grep -qx "$sym" "$CFG" || fail "config 缺 $sym（缺 not-set 会让 syncconfig 遇 NEW 报错）"
done
grep -qx '# CONFIG_RTL_AX_AP is not set' "$CFG" \
  || fail "config 未显式关闭 CONFIG_RTL_AX_AP（只删行会让 syncconfig 按默认=m 重开，编译撞 pe-tx-code.h）"
! grep -q '^CONFIG_RTL_AX_AP=' "$CFG" || fail "config 仍有 CONFIG_RTL_AX_AP=m/y（两套驱动会抢 PCI 设备）"
echo "  config 已切 rtw89（NVMEM on / rtl_ax_ap off）"

# ---- 4. DTS：把 factory 校准 cell 接到 PCIe wifi 节点 ----
# 硬件层 dtsi 已定义 wifi_cal_radio0(@2000,5G)/radio1(@3000,2.4G)，但没接到
# PCIe 下的 wifi 设备。rtw89_factory.c 用 nvmem_cell_get(dev,"wifi-calibration")
# 从各自 PCI 设备节点读取，所以必须在这里绑。
python3 - "$DTS" <<'PY'
import pathlib, sys

p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
if 'RTW89_NVMEM_BIND' in text:
    print('  DTS nvmem 绑定已存在，跳过')
    raise SystemExit(0)

block = '''
/* RTW89_NVMEM_BIND: 官方 rtw89 校准链路（来自上游 tyfza1-2p5g.dts） */
&pcie0 {
	status = "okay";

	wifi5g: wifi@0,0 {
		compatible = "pci10ec,c852";
		reg = <0x0000 0 0 0 0>;
		nvmem-cells = <&wifi_cal_radio0>;
		nvmem-cell-names = "wifi-calibration";
	};
};

&pcie1 {
	status = "okay";

	wifi2g: wifi@0,0 {
		compatible = "pci10ec,0192";
		reg = <0x0000 0 0 0 0>;
		nvmem-cells = <&wifi_cal_radio1>;
		nvmem-cell-names = "wifi-calibration";
	};
};
'''
p.write_text(text.rstrip() + '\n' + block, encoding='utf-8', newline='\n')
PY
grep -q 'RTW89_NVMEM_BIND' "$DTS" || fail "DTS nvmem 绑定失败"
grep -q 'nvmem-cells = <&wifi_cal_radio0>' "$DTS" || fail "5G 校准 cell 未绑定"
grep -q 'nvmem-cells = <&wifi_cal_radio1>' "$DTS" || fail "2.4G 校准 cell 未绑定"
echo "  DTS: pcie0(5G)/pcie1(2.4G) 已绑定 factory 校准 cell"

# ---- 5. 固件落地校验（files/ 链路） ----
# rtw89 从 /lib/firmware/rtw89/ 请求固件；files/ 会被 workflow cp 进 rootfs。
for fw in rtw8192xb_fw.bin rtw8852c_fw.bin; do
  f="$ASSETS/files/lib/firmware/rtw89/$fw"
  [ -f "$f" ] || fail "缺固件 $f"
  [ "$(stat -c %s "$f")" -gt 100000 ] || fail "固件 $fw 大小异常"
done
echo "  rtw89 固件 2/2 就位"

echo "RTW89_OVERLAY_OK=True (driver 6 + patch 1 + config + dts + fw 2)"

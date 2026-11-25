#!/bin/bash
# 把「PT1570-R10 机型支持」注入纯 refactor (Taurus) 源码树。幂等。
#
#   env PT1570_BOARD = r10（当前唯一支持的机型）
#   env ASSETS       = 本资产目录（含 board/ scripts/）
#   env WRT          = 源码树路径
#   env DTS_STATUS   = experimental | verified
#
# 2026-11-25 重写：适配 d39cfc6 双基线废弃后的纯 refactor 树。
#   * refactor 已自带 Taurus 平台驱动/LED/USB/PCIe；platform.sh 已用
#     fit_do_upgrade，无需再注入升级流程或 H10 fip 钩子守护。
#   * 本脚本只做 3 件事：注入 R10 DTS、注入 Device 定义、扩展 sysupgrade 白名单。
#
# 注入点：
#   1. target/linux/rtl9617c/dts/rtl9617c-pt1570-r10.dts   新增板级 DTS（新写，基于 rtk-taurus.dtsi）
#   2. target/linux/rtl9617c/image/Makefile               在 BuildImage 之前插入 Device 定义
#   3. target/linux/rtl9617c/base-files/lib/upgrade/platform.sh
#                                                         platform_check_image / platform_do_upgrade
#                                                         白名单加 youhua,pt1570-r10

set -euo pipefail

trap 'rc=$?; [ "$rc" -eq 0 ] || echo "::error::apply-board 第 $LINENO 行失败 rc=$rc：$BASH_COMMAND" >&2' ERR

BOARD="${PT1570_BOARD:-}"
ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
STATUS="${DTS_STATUS:-experimental}"

case "$BOARD" in
  r10) PROFILE="youhua_pt1570_r10"; DTS="rtl9617c-pt1570-r10"; BOARD_NAME="youhua,pt1570-r10" ;;
  *) echo "ERROR: PT1570_BOARD must be r10 (R10-only scope)" >&2; exit 1 ;;
esac

INC="$ASSETS/board/devices/pt1570-${BOARD}.mk.inc"
DTS_SRC="$ASSETS/board/dts/${DTS}.dts"
IMG_MK="$WRT/target/linux/rtl9617c/image/Makefile"
PLATFORM="$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"

for f in "$INC" "$DTS_SRC" "$IMG_MK" "$PLATFORM"; do
  test -f "$f" || { echo "ERROR: missing $f" >&2; exit 1; }
done

# ---- 0. 确认这是 refactor (Taurus) 树 ----
grep -q '#include "rtk-taurus.dtsi"' "$DTS_SRC" \
  || { echo "ERROR: R10 DTS 未基于 rtk-taurus.dtsi（纯 refactor 基线要求）" >&2; exit 1; }
test -f "$WRT/target/linux/rtl9617c/dts/rtk-taurus.dtsi" \
  || { echo "ERROR: 源码树缺 rtk-taurus.dtsi（不是 refactor Taurus 树？）" >&2; exit 1; }
# 两张板载 WiFi 卡的 PERST#：taurus-pcie 驱动 devm_gpiod_get_optional(dev,"reset")
# 拿不到这行就永不释放复位，PCIe link down、没有 phy0/phy1、无线全灭。
grep -q 'reset-gpios = <&gpio_bank3 5 GPIO_ACTIVE_LOW>' "$DTS_SRC" \
  || { echo "ERROR: R10 DTS pcie0 缺 PERST# reset-gpios（5G 卡不会枚举）" >&2; exit 1; }
grep -q 'reset-gpios = <&gpio_bank3 6 GPIO_ACTIVE_LOW>' "$DTS_SRC" \
  || { echo "ERROR: R10 DTS pcie1 缺 PERST# reset-gpios（2.4G 卡不会枚举）" >&2; exit 1; }

# ---- 1. DTS ----
cp -v "$DTS_SRC" "$WRT/target/linux/rtl9617c/dts/${DTS}.dts"
if [ "$STATUS" = "verified" ]; then
  if grep -q 'UNVERIFIED' "$WRT/target/linux/rtl9617c/dts/${DTS}.dts"; then
    echo "ERROR: DTS_STATUS=verified 但 DTS 仍带 UNVERIFIED 标记；请先完成真机核对" >&2
    exit 1
  fi
fi

# ---- 2. Device 定义 ----
if ! grep -q "define Device/${PROFILE}" "$IMG_MK"; then
  python3 - "$IMG_MK" "$INC" <<'PY'
import sys, pathlib
mk = pathlib.Path(sys.argv[1])
inc = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')
text = mk.read_text(encoding='utf-8')
marker = '$(eval $(call BuildImage))'
if marker not in text:
    raise SystemExit('ERROR: BuildImage marker not found in image/Makefile')
text = text.replace(marker, inc.rstrip() + '\n\n' + marker, 1)
mk.write_text(text, encoding='utf-8')
print('injected Device definition before BuildImage')
PY
else
  echo "Device/${PROFILE} already present, skip"
fi

# ---- 3. sysupgrade 白名单（check + upgrade 两处）----
# refactor 的 platform.sh 用 case "$board" in ... 列出支持机型，两处 case
# （platform_check_image / platform_do_upgrade）都要加入 R10。
if ! grep -q "$BOARD_NAME" "$PLATFORM"; then
  python3 - "$PLATFORM" "$BOARD_NAME" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
name = sys.argv[2]
lines = p.read_text(encoding='utf-8').splitlines(keepends=True)
out = []
inserted = 0
for line in lines:
    out.append(line)
    # 在每个机型 case 分支的 "tianyi,tyfza1-2p5g)" 行后插入 R10 分支。
    # refactor platform.sh 里 check/do 两处各有一个这样的行。
    if 'tianyi,tyfza1-2p5g)' in line:
        indent = line[:len(line) - len(line.lstrip())]
        out.append(f'{indent}{name} |\n')
        inserted += 1
if inserted == 0:
    raise SystemExit('ERROR: platform.sh 里找不到 tianyi,tyfza1-2p5g) case 分支；上游布局变了？')
p.write_text(''.join(out), encoding='utf-8')
print(f'platform.sh whitelist extended with {name} ({inserted} case branches)')
PY
else
  echo "platform.sh already lists $BOARD_NAME, skip"
fi

# ---- 4. 去掉默认 WAN（pon0.<vlan> + PPPoE + 关 PON offload）----
# refactor 的 PON 包来自外部 feed，默认 WAN 脚本在 feed 包内
# （scripts/overlay-theme.sh 之后由 diy-part1 处理）。这里只处理 target 树内
# 可能存在的旧脚本；新树 base-files/etc/uci-defaults 多数机型已不含它。
UPSTREAM_WAN="$WRT/target/linux/rtl9617c/base-files/etc/uci-defaults/90-tyfza1-pon-wan"
if [ -f "$UPSTREAM_WAN" ]; then
  rm -f "$UPSTREAM_WAN"
  echo "removed upstream default WAN uci-default: 90-tyfza1-pon-wan"
fi

# ---- 结果校验 ----
grep -q "SUPPORTED_DEVICES += ${BOARD_NAME}" "$IMG_MK" \
  || { echo "ERROR: SUPPORTED_DEVICES missing in image/Makefile" >&2; exit 1; }
# platform.sh 两处 case 都要有 R10（check + upgrade），用出现次数 >=2 判定
n_board=$(grep -c "$BOARD_NAME" "$PLATFORM")
[ "$n_board" -ge 2 ] \
  || { echo "ERROR: platform.sh 白名单 R10 出现 $n_board 次(<2)，check/upgrade 未都覆盖" >&2; exit 1; }
grep -q 'fit_do_upgrade "$1"' "$PLATFORM" \
  || { echo "ERROR: platform.sh 未用 fit_do_upgrade（系统内升级会失败）" >&2; exit 1; }
grep -q 'rootdisk' "$WRT/target/linux/rtl9617c/dts/rtk-taurus.dtsi" \
  || echo "WARN: rtk-taurus.dtsi 无 rootdisk 属性（DTS 已自带 chosen.rootdisk，通常无碍）"

echo "apply-board OK: board=$BOARD profile=$PROFILE dts=$DTS status=$STATUS"

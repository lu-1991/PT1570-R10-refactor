#!/bin/bash
# 把「新增机型支持」注入 lyq1996/rtl9617c-openwrt 源码树（只改 3 处，幂等）。
#
#   env PT1570_BOARD = r10（当前唯一支持的机型）
#   env ASSETS       = 本资产目录（含 board/ scripts/）
#   env WRT          = 源码树路径
#   env DTS_STATUS   = experimental | verified
#   env PT1570_ALLOW_H10 = 1 时才允许处理 h10（DORMANT，默认拒绝）
#
# 2026-11-09：按用户决定收窄为 R10-only。H10 资产保留但不参与构建，
# 且 H10 DTS 没有真机数据支撑，默认必须拒绝，避免误产出不可刷固件。
#
# 注入点：
#   1. target/linux/rtl9617c/dts/<DTS>.dts          新增板级 DTS
#   2. target/linux/rtl9617c/image/Makefile         在 BuildImage 之前插入 Device 定义
#   3. target/linux/rtl9617c/base-files/lib/upgrade/platform.sh
#                                                    platform_check_image 白名单加 board_name
#                                                    + fit_do_upgrade 升级流程修复（3b）
# 不改 board.d/02_network：LAN 接线由 files/etc/uci-defaults/99-pt1570-fit 兜底。

set -euo pipefail

BOARD="${PT1570_BOARD:-}"
ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"
STATUS="${DTS_STATUS:-experimental}"

case "$BOARD" in
  r10) PROFILE="youhua_pt1570_r10"; DTS="rtl9617c-pt1570-r10"; BOARD_NAME="youhua,pt1570-r10" ;;
  h10)
    if [ "${PT1570_ALLOW_H10:-0}" != "1" ]; then
      echo "ERROR: PT1570-H10 已暂缓（DORMANT），当前范围是 R10-only。" >&2
      echo "       该机型的 DTS 没有真机数据支撑，禁止产出固件。" >&2
      echo "       确需恢复双机型：先完成 H10 真机采集，再设 PT1570_ALLOW_H10=1。" >&2
      exit 1
    fi
    PROFILE="youhua_pt1570_h10"; DTS="rtl9617c-pt1570-h10"; BOARD_NAME="youhua,pt1570-h10" ;;
  *) echo "ERROR: PT1570_BOARD must be r10 (R10-only scope)" >&2; exit 1 ;;
esac

INC="$ASSETS/board/devices/pt1570-${BOARD}.mk.inc"
DTS_SRC="$ASSETS/board/dts/${DTS}.dts"
IMG_MK="$WRT/target/linux/rtl9617c/image/Makefile"
PLATFORM="$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"

for f in "$INC" "$DTS_SRC" "$IMG_MK" "$PLATFORM"; do
  test -f "$f" || { echo "ERROR: missing $f" >&2; exit 1; }
done

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

# ---- 3. sysupgrade 白名单 ----
if ! grep -q "$BOARD_NAME" "$PLATFORM"; then
  python3 - "$PLATFORM" "$BOARD_NAME" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
name = sys.argv[2]
lines = p.read_text(encoding='utf-8').splitlines(keepends=True)
for i, line in enumerate(lines):
    # 不能写死 "pt1500-h10-2p5g) ;;"：第一个机型注入后该串就消失了，
    # 同一源码树再注入第二个机型会失败。按「含锚点 + 以 ) ;; 收尾」定位。
    if 'youhua,pt1500-h10-2p5g' in line and ') ;;' in line:
        lines[i] = line.replace(') ;;', '|' + name + ') ;;', 1)
        break
else:
    raise SystemExit('ERROR: platform.sh whitelist line not found; check upstream layout')
p.write_text(''.join(lines), encoding='utf-8')
print('platform_check_image whitelist extended with ' + name)
PY
else
  echo "platform.sh already lists $BOARD_NAME, skip"
fi

# ---- 3b. sysupgrade 升级流程修复（上游 8c91b228b4 "release fitblk before sysupgrade"）----
# 2026-11-16 朋友真机实证（对应其 run31 起系统内升级可用）：
#   旧 platform.sh 用 nand_do_upgrade 硬编码写 UBI 卷，但运行中的 rootfs 正
#   挂在该卷的 fitblk/ubiblock 设备上 —— 卷被占用，写入无效，表现为
#   "系统里升级成功、重启后固件没有任何变化"。
#   上游修复：platform_do_upgrade 改用 fit_do_upgrade（fitblk 包自带，
#   会按 DTS chosen/rootdisk 自动定位 UBI 卷，并先 `fitblk /dev/fit0`
#   释放块设备再升级），同时把 fitblk 工具复制进 sysupgrade 的 ramfs。
if grep -q 'fit_do_upgrade "$1"' "$PLATFORM"; then
  echo "platform.sh already uses fit_do_upgrade, skip"
else
  python3 - "$PLATFORM" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
old_bin = "RAMFS_COPY_BIN='fw_printenv fw_setenv'\n"
new_bin = "RAMFS_COPY_BIN='fw_printenv fw_setenv fitblk'\n"
old_do = (
    "platform_do_upgrade() {\n"
    "\tCI_KERNPART=fit\n"
    "\tCI_UBIPART=ubi_device\n"
    "\tnand_do_upgrade \"$1\"\n"
    "}\n"
)
new_do = (
    "platform_do_upgrade() {\n"
    "\tfit_do_upgrade \"$1\"\n"
    "}\n"
)
for name, old, new in (("RAMFS_COPY_BIN", old_bin, new_bin),
                       ("platform_do_upgrade", old_do, new_do)):
    n = text.count(old)
    if n != 1:
        raise SystemExit(
            f"ERROR: platform.sh 的 {name} 旧片段命中 {n} 次（应为 1）；"
            "上游 20b4cf4 布局变了？请对照 8c91b228b4 手工核对")
    text = text.replace(old, new, 1)
p.write_text(text, encoding='utf-8')
print('platform.sh upgraded to fit_do_upgrade flow')
PY
fi

# ---- 3c. 挡住 H10 的升级钩子覆盖（网页升级报 "this image is for youhua,pt1500-h10"）----
# 2026-11-16 真机实证：/sbin/sysupgrade 启动时 `ls /lib/upgrade/*.sh` 逐个 source。
# pt1500-fip.sh 字母序在 platform.sh 之后，它无条件定义的
#   platform_check_image / platform_do_upgrade / platform_copy_config
# 会把 R10 的钩子整个覆盖掉：
#   - check：只允许 youhua,pt1500-h10，R10 上传固件第一句就被判死
#            （"this image is for youhua,pt1500-h10, not youhua,pt1570-r10"）
#   - do：写 fip 卷，而 R10 上没有这个卷 → 即便 -F 强刷也写不进去
# 所以 3b 修的 fit_do_upgrade 根本没机会执行。把这三个定义用机型 case 包起来，
# 让 H10 机型仍然走 fip 路径、其它机型回落到 platform.sh。
FIP_SH="$WRT/target/linux/rtl9617c/base-files/lib/upgrade/pt1500-fip.sh"
if [ ! -f "$FIP_SH" ]; then
  echo "pt1500-fip.sh 不存在，跳过（该树没有 H10 升级路径）"
elif grep -q 'PT1570_R10_UPGRADE_HOOK_GUARD' "$FIP_SH"; then
  echo "pt1500-fip.sh already guarded, skip"
else
  python3 - "$FIP_SH" <<'PY'
import sys, pathlib
p = pathlib.Path(sys.argv[1])
lines = p.read_text(encoding='utf-8').splitlines()
try:
    start = next(i for i, l in enumerate(lines)
                 if l.startswith('platform_check_image()'))
except StopIteration:
    raise SystemExit('ERROR: pt1500-fip.sh 里找不到 platform_check_image()，上游结构变了？')
head, body = lines[:start], lines[start:]
guard = [
    '',
    '# PT1570_R10_UPGRADE_HOOK_GUARD（PT1570-R10-CI 注入，勿手改）',
    '# sysupgrade 会 source /lib/upgrade/*.sh 全部脚本，本文件字母序排在',
    '# platform.sh 之后；不守护就会把 R10 的 platform_check_image /',
    '# platform_do_upgrade 覆盖成 H10 的 fip 路径。仅在 H10 机型上生效。',
    'case "$(board_name 2>/dev/null)" in',
    'youhua,pt1500-h10|youhua,pt1500-h10-2p5g)',
]
out = head + guard + body + [';;', 'esac']
p.write_text('\n'.join(out) + '\n', encoding='utf-8')
print('pt1500-fip.sh 已加机型守护（%d 行函数体）' % len(body))
PY
fi

# ---- 结果校验 ----
grep -q "SUPPORTED_DEVICES += ${BOARD_NAME}" "$IMG_MK" \
  || { echo "ERROR: SUPPORTED_DEVICES missing" >&2; exit 1; }
grep -q "$BOARD_NAME" "$PLATFORM" \
  || { echo "ERROR: platform.sh whitelist missing" >&2; exit 1; }
# 升级流程必须是 fit_do_upgrade（否则系统内升级"成功"却写不进 UBI 卷）
grep -q 'fit_do_upgrade "$1"' "$PLATFORM" \
  || { echo "ERROR: platform.sh 未启用 fit_do_upgrade（系统内升级会静默失败）" >&2; exit 1; }
grep -q "fw_setenv fitblk" "$PLATFORM" \
  || { echo "ERROR: platform.sh RAMFS_COPY_BIN 缺 fitblk" >&2; exit 1; }
# H10 的 fip 钩子必须被机型 case 守护，否则会盖掉上面这套（网页升级必失败）
if [ -f "$FIP_SH" ]; then
  grep -q 'PT1570_R10_UPGRADE_HOOK_GUARD' "$FIP_SH" \
    || { echo "ERROR: pt1500-fip.sh 未加机型守护（会覆盖 platform_check_image）" >&2; exit 1; }
  sh -n "$FIP_SH" \
    || { echo "ERROR: pt1500-fip.sh 加了守护后语法不通过" >&2; exit 1; }
  echo "H10 fip 钩子已按机型守护 OK"
fi
grep -q 'rootdisk' "$WRT/target/linux/rtl9617c/dts/rtl9617c-tyfza1.dtsi" \
  || { echo "ERROR: 上游 dtsi 没有 chosen.rootdisk，FIT ABI 不成立" >&2; exit 1; }
grep -q 'volname = "fit"' "$WRT/target/linux/rtl9617c/dts/rtl9617c-tyfza1.dtsi" \
  || { echo "ERROR: 上游 dtsi 没有 fit 卷" >&2; exit 1; }

# R10 真机是 4×GE，DTS 必须基于上游 4GE 板定义；上游改名时提前失败而不是等到编译。
if [ "$BOARD" = "r10" ]; then
  DTS_DIR="$WRT/target/linux/rtl9617c/dts"
  test -f "$DTS_DIR/rtl9617c-tyfza1-4ge.dts" \
    || { echo "ERROR: 上游缺少 rtl9617c-tyfza1-4ge.dts（R10 的 4×GE 基线）" >&2; exit 1; }
  grep -q 'rtl9617c-tyfza1-4ge.dts' "$DTS_DIR/$DTS.dts" \
    || { echo "ERROR: R10 DTS 未 include 4GE 板定义" >&2; exit 1; }
  ! grep -q 'rtl9617c-tyfza1-2p5g.dts' "$DTS_DIR/$DTS.dts" \
    || { echo "ERROR: R10 DTS 误用 2.5G 板定义，4×GE 会不通" >&2; exit 1; }
  echo "R10 4GE baseline OK"
fi

echo "apply-board OK: board=$BOARD profile=$PROFILE dts=$DTS status=$STATUS"

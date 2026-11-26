#!/bin/bash
# 修补纯 refactor (Taurus) 源码树里与 FIT 启动相关的缺陷（幂等）。
#
# 用法：ASSETS=<资产目录> WRT=<源码树> bash scripts/patch-upstream.sh
#
# 2026-11-25 精简：新树里 tyfza1-factory（外部 feed 的 PON 包提供，不含
# 284 字节逻辑）与 rtl9617c-xram.c（Taurus NI 驱动改为读 DTS label）都不存在，
# 原先这两处修补不再适用；WiFi AP 固件改由 rtl*-ap-firmware 包提供（不再靠
# files/ 手工塞）。本脚本现在只做一件事：
#   放开 generic/510 fitblk 的 4 MiB FIT 上限 + kmalloc -> kvmalloc，
#   否则 /dev/fit0 建不出来，刷入态启动直接灯全灭。

set -euo pipefail

trap 'rc=$?; [ "$rc" -eq 0 ] || echo "::error::patch-upstream 第 $LINENO 行失败 rc=$rc：$BASH_COMMAND" >&2' ERR

ASSETS="${ASSETS:-$(cd "$(dirname "$0")/.." && pwd)}"
WRT="${WRT:-$ASSETS/wrt}"

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------- fitblk：解除 4MiB FIT 上限（刷入态起不来的根因） ----------
# target/linux/generic/pending-6.18/510-block-add-uImage.FIT-subimage-block-driver.patch:
#   #define FIT_MAX_PAGES  1024        -> 4 KiB 页时上限 4 MiB
#   if (size > PAGE_SIZE * FIT_MAX_PAGES) ret = -EOPNOTSUPP;
#   fit = kmalloc(size, GFP_KERNEL);
# 本机型 sysupgrade FIT ~20 MB，超过 4 MiB 时 probe 返回 -95，/dev/fit0 不出现，
# 内核按 root=/dev/fit0 挂根失败 -> 灯全灭（"内存能起、刷入起不来"的唯一原因）。
# 修法：上限提到 16384 页（64 MiB），kmalloc 改 kvmalloc（20MB kmalloc 会
# 因 MAX_ORDER -ENOMEM，vmap 区才拿得到）。
FITBLK_PATCH="$WRT/target/linux/generic/pending-6.18/510-block-add-uImage.FIT-subimage-block-driver.patch"
[ -f "$FITBLK_PATCH" ] || fail "找不到 $FITBLK_PATCH（上游 pending 目录结构变了？）"

if grep -qE '#define[[:space:]]+FIT_MAX_PAGES[[:space:]]+16384' "$FITBLK_PATCH"; then
  echo "fitblk 补丁已放开上限，跳过"
else
python3 - "$FITBLK_PATCH" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')
subs = [
    (r'#define\s+FIT_MAX_PAGES\s+1024\b', '#define FIT_MAX_PAGES\t\t16384'),
    (r'fit = kmalloc\(size, GFP_KERNEL\);', 'fit = kvmalloc(size, GFP_KERNEL);'),
    (r'\bkfree\(fit\);', 'kvfree(fit);'),
]
for old, new in subs:
    hits = re.findall(old, text)
    if len(hits) != 1:
        raise SystemExit('ERROR: fitblk 补丁里 %r 出现 %d 次（期望 1 次，上游改动？）'
                         % (old, len(hits)))
    text = re.sub(old, new, text, count=1)
# kvmalloc 声明在 <linux/slab.h>、kvfree 在 <linux/vmalloc.h>；新建的 fitblk.c
# 没有显式包含它们，补上避免隐性依赖。注意同步把 @@ -0,0 +1,N @@ 的 N 加 2。
if '<linux/slab.h>' not in text:
    anchor = '+#include <linux/refcount.h>\n'
    if text.count(anchor) != 1:
        raise SystemExit('ERROR: fitblk 补丁里 %r 出现 %d 次，无法插入 slab.h'
                         % (anchor, text.count(anchor)))
    text = text.replace(anchor,
        anchor + '+#include <linux/slab.h>\n+#include <linux/vmalloc.h>\n', 1)
    ins = text.find('+#include <linux/slab.h>\n')
    hstart = text.rfind('\n@@', 0, ins) + 1
    hend = text.find('\n', hstart)
    hline = text[hstart:hend]
    m = re.match(r'@@ -(\d+(?:,\d+)?) \+(\d+(?:,\d+)?) @@$', hline)
    if not m:
        raise SystemExit('ERROR: 无法解析插入点所在 hunk 头：%r' % hline)
    add, newc = m.group(2).split(',')
    hline2 = hline.replace(' +%s,%s @@' % (add, newc),
                           ' +%s,%d @@' % (add, int(newc) + 2), 1)
    text = text[:hstart] + hline2 + text[hend:]
    lines = text.split('\n')
    hidx = text[:hstart].count('\n')
    n = int(newc) + 2
    for ln in lines[hidx + 1 : hidx + 1 + n]:
        if ln and ln[0] not in '+-\\ ':
            raise SystemExit('ERROR: hunk 正文混入非补丁行：%r' % ln[:60])
    if len(lines) > hidx + 1 + n:
        after = lines[hidx + 1 + n]
        if after and not after.startswith(('diff ', '--- ', '+++ ', '@@ ')):
            raise SystemExit('ERROR: hunk 行数与声明不符，第 %d 行是 %r'
                             % (hidx + 2 + n, after[:60]))
p.write_text(text, encoding='utf-8', newline='\n')
print('patched fitblk: FIT_MAX_PAGES 1024 -> 16384, kmalloc -> kvmalloc, +slab/vmalloc.h')
PY

grep -qE '#define[[:space:]]+FIT_MAX_PAGES[[:space:]]+16384' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁未被修改（FIT_MAX_PAGES）'
grep -q 'fit = kvmalloc(size, GFP_KERNEL);' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁未被修改（kvmalloc）'
grep -q 'kvfree(fit);' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁未被修改（kvfree）'
grep -q '#include <linux/slab.h>' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁缺少 slab.h（kvmalloc 声明）'
grep -q '#include <linux/vmalloc.h>' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁缺少 vmalloc.h（kvfree 声明）'
! grep -q 'fit = kmalloc(size, GFP_KERNEL);' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁仍残留 kmalloc(size)'
! grep -qE '#define[[:space:]]+FIT_MAX_PAGES[[:space:]]+1024' "$FITBLK_PATCH" \
  || fail 'fitblk 补丁仍残留 1024 上限'
echo "FITBLK_LIMIT_OK=True (16384 pages = 64 MiB, kvmalloc)"
fi

# ---------- RTL9617C NI：关闭 EEE/LPI（四口循环 Link Down/Up） ----------
# 2026-11-26 真机：四个 GE 口在运行数分钟后开始反复 Link Down/Up，间隔逐渐
# 缩短。refactor 的 NI 驱动在 phylink 能力里新增了：
#   config->lpi_capabilities = MAC_100FD | MAC_1000FD;
#   __set_bit(PHY_INTERFACE_MODE_INTERNAL/GMII, config->lpi_interfaces);
#   config->lpi_timer_default = 250000;
# GPHY 驱动同时用 vendor MMD 寄存器模拟 EEE ability/adv/LPABLE，于是 phylink
# 判定双方支持 EEE 并打开 MAC TX LPI；与对端节能状态机不同步时会反复重新
# 训练链路。这里从 MAC 能力声明层关掉 EEE，四个口全生效，不依赖 ethtool 包，
# 也不用开机脚本去改运行时状态（那样时序很难卡在 phylink 之前）。
# 只去掉能力声明，不碰 TX LPI 的 ethtool 接口，保留用户手动打开的余地。
NI_PORT="$WRT/target/linux/rtl9617c/files-6.18/drivers/net/ethernet/realtek/rtl9617c/ni/ni_port.c"
[ -f "$NI_PORT" ] || fail "找不到 $NI_PORT（上游 NI 驱动路径变了？）"

if grep -q 'PT1570-R10.*EEE' "$NI_PORT"; then
  echo "NI EEE/LPI 已禁用，跳过"
else
python3 - "$NI_PORT" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
text = p.read_text(encoding='utf-8')

blocks = [
    '\t\tconfig->lpi_capabilities = MAC_100FD | MAC_1000FD;\n',
    '\t\t__set_bit(PHY_INTERFACE_MODE_INTERNAL, config->lpi_interfaces);\n',
    '\t\t__set_bit(PHY_INTERFACE_MODE_GMII, config->lpi_interfaces);\n',
    '\t\tconfig->lpi_timer_default = 250000;\n',
]
for b in blocks:
    n = text.count(b)
    if n != 1:
        raise SystemExit('ERROR: ni_port.c 里 %r 出现 %d 次（期望 1 次，上游改动？）'
                         % (b.strip(), n))

replacement = (
    '\t\t/* PT1570-R10: EEE/LPI disabled - 4xGE link flapping on refactor. */\n'
    '\t\t/* lpi_capabilities / lpi_interfaces / lpi_timer_default removed. */\n'
)
# blocks[0] 原位换成注释，其余三行直接删掉。
text = text.replace(blocks[0], replacement, 1)
for b in blocks[1:]:
    text = text.replace(b, '', 1)
p.write_text(text, encoding='utf-8', newline='\n')
print('patched ni_port.c: EEE/LPI capabilities removed (4xGE link flap)')
PY
fi

! grep -q 'config->lpi_capabilities = MAC_100FD' "$NI_PORT" \
  || fail 'ni_port.c 仍声明 lpi_capabilities（EEE 未关闭）'
! grep -q 'config->lpi_interfaces' "$NI_PORT" \
  || fail 'ni_port.c 仍声明 lpi_interfaces（EEE 未关闭）'
grep -q 'PT1570-R10: EEE/LPI disabled' "$NI_PORT" \
  || fail 'ni_port.c 缺少 EEE 禁用标记'
echo "NI_EEE_DISABLED=True"

echo "patch-upstream OK: fitblk 上限已放开, NI EEE/LPI 已关闭"

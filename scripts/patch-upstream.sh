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

echo "patch-upstream OK: fitblk 上限已放开"

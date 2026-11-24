#!/bin/bash
# ================================================================
# overlay-theme.sh —— 主题切换：argon -> design（用 kenzok8 feed 自带的 design 包）
# 运行目录：OpenWrt 源码根（$BUILD_ROOT/openwrt）
# 调用时机：diy-part1.sh 第 1 节（feeds 安装之后、加载 .config 之前）
#
# design 主题来自 feeds.conf.default 里的 kenzok8 feed：
#   src-git kenzok8 https://github.com/kenzok8/openwrt-packages.git^1c66098...
#   该 feed 自带 luci-theme-design（与 0x676e67/luci-theme-design 同源同版本），
#   scripts/feeds install -a 会软链到 package/feeds/kenzok8/luci-theme-design。
#   包自带 root/etc/uci-defaults/30_luci-theme-design，会把
#   luci.main.mediaurlbase 设成 /luci-static/design。
#   不再另外 git 拉库 —— 直接用 feed 包，少一次网络拉取。
#
# "去掉 argon 主题设置"的两处来源（厂商硬件层 20b4cf4）：
#   1) workflow Clone 步骤原本 checkout 的 package/luci-theme-argon
#      —— 已改为不 checkout，本脚本再做一次 rm -rf 兜底。
#   2) luci-app-tyfza1-pon 包里的两个 uci-defaults 脚本：
#        95-tyfza1-argon          迁移脚本：首次开机写 mediaurlbase=argon
#        97-tyfza1-argon-default  每次开机强制写回 argon（序号 97 > 30，会抢主题）
#      两个都必须删，否则 design 被 argon 抢回默认主题。
#
# kenzok8 版 design 的 PKG_VERSION=5.8.0-20240106（'-' 分隔日期），拼上
# PKG_RELEASE 后是 5.8.0-20240106-r1（两个 '-'）。新版 apk 只允许一个 '-rN'
# 作 revision，报 "package version is invalid" 并 Error 99。这里把日期
# 分隔符改成 '.'：5.8.0.20240106-r1 —— apk 合法，版本号语义不变。
# ================================================================
set -euo pipefail

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$PWD}"

echo "=========================================="
echo "overlay-theme: argon -> design（kenzok8 feed 包）"
echo "  wrt = $WRT"
echo "=========================================="

test -f "$WRT/package/base-files/files/bin/config_generate" \
  || { echo "ERROR: $WRT 不是 OpenWrt 源码根" >&2; exit 1; }

# ---- 1. 去掉 argon 包本体（workflow 已不 checkout，这里兜底）----
rm -rf "$WRT/package/luci-theme-argon" \
       "$WRT/package/feeds/luci/luci-theme-argon" 2>/dev/null || true
# feeds 软链可能指向外部（packages/luci feed 不含 argon，但保险起见清软链本身）
find "$WRT/package/feeds" -maxdepth 2 -type l -name 'luci-theme-argon' -delete 2>/dev/null || true
echo "  OK   argon 包本体已移除"

# ---- 2. 去掉厂商 argon 默认主题设置（uci-defaults）----
PON_UCID="$WRT/package/luci-app-tyfza1-pon/root/etc/uci-defaults"
n_rm=0
for s in 95-tyfza1-argon 97-tyfza1-argon-default; do
  if [ -f "$PON_UCID/$s" ]; then
    rm -f "$PON_UCID/$s"
    n_rm=$((n_rm+1))
    echo "  OK   已删除 $s"
  fi
done
# 收尾断言：源码树任何 uci-defaults 里都不允许再出现 argon 主题设置
if grep -rqs -e '/luci-static/argon' -e 'luci\.themes\.Argon' \
     "$WRT/package/luci-app-tyfza1-pon" 2>/dev/null; then
  echo "ERROR: PON 包仍有 argon 默认主题设置（会抢走 design）" >&2
  exit 1
fi
echo "  OK   厂商 argon 默认主题设置已清除（删除 $n_rm 个脚本）"

# ---- 2b. 去掉 PON 应用 Makefile 里的 argon 依赖 ----
# 上游 package/luci-app-tyfza1-pon/Makefile 的 LUCI_DEPENDS 写死了：
#   +luci-theme-argon +luci-i18n-argon-config-zh-cn
# 本仓库已删 argon 包本体，apk 在 package/install 阶段解析依赖会报：
#   luci-i18n-argon-config-zh-cn (no such package) / luci-theme-argon (no such package)
#   required by: luci-app-tyfza1-pon-0.8.2_beta[...]
# 这里把这两项从依赖串里摘掉（其余依赖原样保留），否则编译必挂在 install 阶段。
PON_MK="$WRT/package/luci-app-tyfza1-pon/Makefile"
test -f "$PON_MK" \
  || { echo "ERROR: 缺 $PON_MK（workflow 未 checkout 硬件层 PON 包？）" >&2; exit 1; }
if grep -qE '\+luci-theme-argon|\+luci-i18n-argon-config-zh-cn' "$PON_MK"; then
  sed -i -E \
    -e 's/[[:space:]]*\+luci-theme-argon//g' \
    -e 's/[[:space:]]*\+luci-i18n-argon-config-zh-cn//g' \
    "$PON_MK"
  echo "  OK   PON Makefile 已去掉 argon 依赖：$(grep -E '^LUCI_DEPENDS:=' "$PON_MK" | head -1)"
fi
# 断言：PON 应用依赖里已无 argon（这是本次 apk install 失败的确切来源）
if grep -qE '\+luci-theme-argon|\+luci-i18n-argon-config-zh-cn' "$PON_MK"; then
  echo "ERROR: $PON_MK 仍依赖已删除的 argon 包，apk install 必失败" >&2
  exit 1
fi
# 全树只做提示（不 fail）：feed 里可能有未被选中的 argon 相关包，属正常残留
stale=$(grep -rlsE '(^|[[:space:]])[+?]?(luci-theme-argon|luci-i18n-argon-config-zh-cn)([[:space:]]|$)' \
          --include='Makefile' "$WRT/package" 2>/dev/null | grep -vF "$PON_MK" | head -5 || true)
if [ -n "$stale" ]; then
  echo "  note 其余 Makefile 仍提到 argon（未被选中则无碍）：$(echo "$stale" | tr '\n' ' ')"
fi
echo "  OK   PON 应用 argon 依赖已清除"

# ---- 3. 用 kenzok8 feed 的 design 包 ----
# 防止 package/ 顶层残留同名包（旧版拉库遗留）顶掉 feed 那份
rm -rf "$WRT/package/luci-theme-design" 2>/dev/null || true

DST="$WRT/feeds/kenzok8/luci-theme-design"
test -f "$DST/Makefile" \
  || { echo "ERROR: kenzok8 feed 缺 luci-theme-design（feeds install 未装？）" >&2; exit 1; }

# 软链必须存在，否则 defconfig 扫不到这个包
LINK="$WRT/package/feeds/kenzok8/luci-theme-design"
if [ ! -e "$LINK" ] && [ ! -L "$LINK" ]; then
  mkdir -p "$(dirname "$LINK")"
  # 用相对软链，和 feeds install 生成的形态一致（避免绝对路径在 CI 失效）
  ( cd "$(dirname "$LINK")" && ln -s "../../../feeds/kenzok8/luci-theme-design" luci-theme-design ) 2>/dev/null || true
fi
test -e "$LINK" \
  || { echo "ERROR: package/feeds/kenzok8/luci-theme-design 软链缺失" >&2; exit 1; }

# ---- 4. 修 PKG_VERSION：日期 '-' -> '.'（apk 版本号合法性）----
if grep -qE '^PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' "$DST/Makefile"; then
  sed -i -E 's/^(PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)$/\1.\2/' "$DST/Makefile"
  echo "  OK   PKG_VERSION 已改为 apk 合法格式：$(grep -E '^PKG_VERSION:=' "$DST/Makefile" | head -1)"
elif grep -qE '^PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' "$DST/Makefile"; then
  echo "  OK   PKG_VERSION 已是 apk 合法格式：$(grep -E '^PKG_VERSION:=' "$DST/Makefile" | head -1)"
else
  echo "::warning::design 主题 PKG_VERSION 非预期格式，请人工确认"
  grep -E '^PKG_VERSION:=' "$DST/Makefile" | head -1 || true
fi

# ---- 5. 断言：包结构 + 默认主题脚本在位 ----
grep -q 'luci.mk' "$DST/Makefile" \
  || { echo "ERROR: design 主题 Makefile 未 include luci.mk" >&2; exit 1; }
test -d "$DST/htdocs/luci-static/design" \
  || { echo "ERROR: design 主题静态目录缺失" >&2; exit 1; }
test -f "$DST/root/etc/uci-defaults/30_luci-theme-design" \
  || { echo "ERROR: design 主题缺默认主题脚本 30_luci-theme-design" >&2; exit 1; }
grep -q '/luci-static/design' "$DST/root/etc/uci-defaults/30_luci-theme-design" \
  || { echo "ERROR: 30_luci-theme-design 未设置 mediaurlbase=/luci-static/design" >&2; exit 1; }
echo "  OK   design 包结构 + 默认主题脚本就位（kenzok8 feed）"

echo "🎉 overlay-theme.sh 完成"

#!/bin/bash
# ================================================================
# overlay-theme.sh —— 主题切换：argon -> design（拉库 ucode 版）
# 运行目录：OpenWrt 源码根（$BUILD_ROOT/openwrt）
# 调用时机：diy-part1.sh 第 1 节（feeds 安装之后、加载 .config 之前）
#
# design 主题来自 felixmm0606/luci-theme-design 的 ucode 分支（浅克隆到
# package/luci-theme-design）。必须用 ucode 版：主线 luci feed 已把主题模板
# 从 Lua（luasrc/view/themes/design/header.htm，靠 disp.node()）迁到 ucode
# （ucode/template/themes/design/header.ut）；老式 Lua 主题在 ucode LuCI 下
# 运行时报 dispatcher.lua:69 __entries is nil → 页面 500。
# 该 fork 专为 ucode LuCI 移植，Makefile 且已修 apk 版本号 + postinst 主题注册。
# 包自带 root/etc/uci-defaults/30_luci-theme-design，把
# luci.main.mediaurlbase 设成 /luci-static/design。
#
# "去掉 argon 主题设置"的两处来源（厂商硬件层 20b4cf4）：
#   1) workflow Clone 步骤原本 checkout 的 package/luci-theme-argon
#      —— 已改为不 checkout，本脚本再做一次 rm -rf 兜底。
#   2) luci-app-tyfza1-pon 包里的两个 uci-defaults 脚本：
#        95-tyfza1-argon          迁移脚本：首次开机写 mediaurlbase=argon
#        97-tyfza1-argon-default  每次开机强制写回 argon（序号 97 > 30，会抢主题）
#      两个都必须删，否则 design 被 argon 抢回默认主题。
#
# apk 版本号只认一个 '-rN' 作 revision；若 PKG_VERSION 里日期用 '-' 分隔
# （5.8.0-20240106），拼上 -rN 会有两个 '-' 而报 version is invalid。
# 拉库的 ucode fork 已是点分格式（5.8.0.20240106-r2），这里兜底 sed 成 '.'。
# ================================================================
set -euo pipefail

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$PWD}"

echo "=========================================="
echo "overlay-theme: argon -> design（拉库 ucode 版）"
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

# ---- 3. 拉库：适配 ucode LuCI 的 design 主题 ----
# 为什么不再用 kenzok8 feed 那份：主线 luci feed 已把主题模板从 Lua 迁到
# ucode（.ut）。kenzok8 / 0x676e67 / gngpp 的 design 都还是老式
# luasrc/view/themes/design/header.htm，靠 disp.node() 遍历菜单；新版 LuCI
# 用 ucode dispatcher，老 Lua dispatcher 的 __entries 未初始化，运行时报
#   dispatcher.lua:69: attempt to index global '__entries' (a nil value)
# 页面 500。felixmm0606/luci-theme-design 的 ucode 分支专为 ucode LuCI 移植，
# 提供 ucode/template/themes/design/{header,footer,sysauth}.ut，且 Makefile
# 已修 apk 版本号（点分日期）和 postinst 主题注册。
DESIGN_REPO="https://github.com/felixmm0606/luci-theme-design.git"
DESIGN_REF="ucode"                 # 默认分支即 ucode；锁分支名即可（该 fork 小而稳定）
DESIGN_SHA=""                      # 留空=跟分支 HEAD；需要字节级锁定时填 40 位 SHA
DST="$WRT/package/luci-theme-design"

# 3a. 先清掉所有可能顶替的旧 design：顶层残留 + kenzok8 feed 实体 + 软链
rm -rf "$DST" \
       "$WRT/feeds/kenzok8/luci-theme-design" \
       "$WRT/package/feeds/kenzok8/luci-theme-design" 2>/dev/null || true

# 3b. 浅克隆 ucode 分支
git clone --depth=1 --branch "$DESIGN_REF" "$DESIGN_REPO" "$DST"
if [ -n "$DESIGN_SHA" ]; then
  ( cd "$DST" && git fetch -q --depth=1 origin "$DESIGN_SHA" && git checkout -q FETCH_HEAD )
fi
test -f "$DST/Makefile" \
  || { echo "ERROR: design 拉库后无 Makefile" >&2; exit 1; }
rm -rf "$DST/.git"   # 不带 .git 进包目录，避免打包/扫描误判
echo "  OK   design 主题已拉库（$DESIGN_REPO @ $DESIGN_REF，ucode 模板）"

# ---- 4. PKG_VERSION 校验：fork 已是点分格式（5.8.0.20240106-r2），apk 合法 ----
# 兜底：若上游回滚成 '-' 分隔日期，仍 sed 成 '.'，否则 apk 报 version is invalid。
if grep -qE '^PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' "$DST/Makefile"; then
  sed -i -E 's/^(PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)$/\1.\2/' "$DST/Makefile"
  echo "  OK   PKG_VERSION 已改为 apk 合法格式：$(grep -E '^PKG_VERSION:=' "$DST/Makefile" | head -1)"
else
  echo "  OK   PKG_VERSION 已是 apk 合法格式：$(grep -E '^PKG_VERSION:=' "$DST/Makefile" | head -1)"
fi

# ---- 5. 断言：ucode 模板 + 静态资源 + 默认主题脚本在位 ----
grep -q 'luci.mk' "$DST/Makefile" \
  || { echo "ERROR: design 主题 Makefile 未 include luci.mk" >&2; exit 1; }
# 关键：必须有 ucode .ut 模板，否则又是 __entries nil（这次报错的根因）
test -f "$DST/ucode/template/themes/design/header.ut" \
  || { echo "ERROR: design 主题缺 ucode header.ut（不是 ucode 版，会 500）" >&2; exit 1; }
test -f "$DST/ucode/template/themes/design/footer.ut" \
  || { echo "ERROR: design 主题缺 ucode footer.ut" >&2; exit 1; }
test -d "$DST/htdocs/luci-static/design" \
  || { echo "ERROR: design 主题静态目录缺失" >&2; exit 1; }
test -f "$DST/root/etc/uci-defaults/30_luci-theme-design" \
  || { echo "ERROR: design 主题缺默认主题脚本 30_luci-theme-design" >&2; exit 1; }
grep -q '/luci-static/design' "$DST/root/etc/uci-defaults/30_luci-theme-design" \
  || { echo "ERROR: 30_luci-theme-design 未设置 mediaurlbase=/luci-static/design" >&2; exit 1; }
echo "  OK   design 包结构就位（ucode .ut 模板 + 静态资源 + 默认主题脚本）"

echo "🎉 overlay-theme.sh 完成"

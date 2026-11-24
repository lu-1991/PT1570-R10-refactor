#!/bin/bash
# ================================================================
# overlay-theme.sh —— 主题切换：argon -> design（直接拉库编译）
# 运行目录：OpenWrt 源码根（$BUILD_ROOT/openwrt）
# 调用时机：diy-part1.sh 第 1 节（feeds 安装之后、加载 .config 之前）
#
# design 主题：https://github.com/0x676e67/luci-theme-design
#   * main 分支 = lede/lua 版 LuCI（本仓库 luci feed 为 openwrt/luci，
#     仍兼容 luasrc/ + htdocs/ 布局）；js 分支不拉。
#   * 锁 commit 5cea733806ccaf17fd63790d171bb2b65f29f8bd，字节级可复现。
#   * 包自带 root/etc/uci-defaults/30_luci-theme-design，会把
#     luci.main.mediaurlbase 设成 /luci-static/design。
#
# "去掉 argon 主题设置"的两处来源（厂商硬件层 20b4cf4）：
#   1) workflow Clone 步骤原本 checkout 的 package/luci-theme-argon
#      —— 已改为不 checkout，本脚本再做一次 rm -rf 兜底。
#   2) luci-app-tyfza1-pon 包里的两个 uci-defaults 脚本：
#        95-tyfza1-argon          迁移脚本：首次开机写 mediaurlbase=argon
#        97-tyfza1-argon-default  每次开机强制写回 argon（序号 97 > 30，会抢主题）
#      两个都必须删，否则 design 被 argon 抢回默认主题。
# ================================================================
set -euo pipefail

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$PWD}"
THEME_URL="${THEME_URL:-https://github.com/0x676e67/luci-theme-design}"
THEME_REF="${THEME_REF:-5cea733806ccaf17fd63790d171bb2b65f29f8bd}"

echo "=========================================="
echo "overlay-theme: argon -> design（拉库编译）"
echo "  url = $THEME_URL"
echo "  ref = $THEME_REF"
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

# ---- 3. 直接拉库 design 主题（锁 SHA，字节级可复现）----
DST="$WRT/package/luci-theme-design"
rm -rf "$DST"
mkdir -p "$DST"
git init -q "$DST"
git -C "$DST" remote add origin "$THEME_URL"
if ! git -C "$DST" fetch -q --depth=1 origin "$THEME_REF"; then
  echo "::warning::按 SHA 拉取失败，回退 main 分支"
  git -C "$DST" fetch -q --depth=1 origin main
fi
git -C "$DST" checkout -q FETCH_HEAD
GOT="$(git -C "$DST" rev-parse HEAD)"
echo "  OK   design 主题已拉到 package/luci-theme-design @ ${GOT:0:12}"

# ---- 3.5 消除 kenzok8 feed 的同名 design 包 + 修 apk 版本号 ----
# kenzok8 feed（feeds.conf.default 里 src-git kenzok8）也收录了同一份
# 0x676e67/luci-theme-design（版本同样是 5.8.0-20240106）。feeds install -a
# 会把它软链到 package/feeds/kenzok8/luci-theme-design，实测 CI 编译走的正是
# 那份 feeds 包而非上面拉库的 package/ 那份。删掉软链 + feed 实体，确保
# 唯一生效的是本脚本拉库的包（用户要求"直接拉库编译"）。
rm -rf "$WRT/package/feeds/kenzok8/luci-theme-design" 2>/dev/null || true
rm -rf "$WRT/feeds/kenzok8/luci-theme-design" 2>/dev/null || true
echo "  OK   kenzok8 feed 同名 design 包已移除（避免顶掉拉库那份）"

# 上游 PKG_VERSION=5.8.0-20240106 用 '-' 分隔日期，拼上 PKG_RELEASE 后是
# 5.8.0-20240106-r1（两个 '-'）。新版 apk 只允许一个 '-rN' 作 revision，
# 于是报 "package version is invalid" 并 Error 99 中断整个 build。
# 把日期分隔符改成 '.'：5.8.0.20240106-r1 —— apk 合法，版本号语义不变。
if grep -qE '^PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' "$DST/Makefile"; then
  sed -i -E 's/^(PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)$/\1.\2/' "$DST/Makefile"
  echo "  OK   PKG_VERSION 已改为 apk 合法格式：$(grep -E '^PKG_VERSION:=' "$DST/Makefile" | head -1)"
else
  echo "::warning::design 主题 PKG_VERSION 非预期格式，跳过修正（上游可能已更新）"
  grep -E '^PKG_VERSION:=' "$DST/Makefile" | head -1 || true
fi

# ---- 4. 断言：包结构 + 默认主题脚本在位 ----
test -f "$DST/Makefile" \
  || { echo "ERROR: design 主题 Makefile 缺失" >&2; exit 1; }
grep -q 'luci.mk' "$DST/Makefile" \
  || { echo "ERROR: design 主题 Makefile 未 include luci.mk" >&2; exit 1; }
test -d "$DST/htdocs/luci-static/design" \
  || { echo "ERROR: design 主题静态目录缺失" >&2; exit 1; }
test -f "$DST/root/etc/uci-defaults/30_luci-theme-design" \
  || { echo "ERROR: design 主题缺默认主题脚本 30_luci-theme-design" >&2; exit 1; }
grep -q '/luci-static/design' "$DST/root/etc/uci-defaults/30_luci-theme-design" \
  || { echo "ERROR: 30_luci-theme-design 未设置 mediaurlbase=/luci-static/design" >&2; exit 1; }
echo "  OK   design 包结构 + 默认主题脚本就位"

echo "🎉 overlay-theme.sh 完成"

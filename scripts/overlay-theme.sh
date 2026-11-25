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
# 主题设置页 felixmm0606/luci-app-design-config 的 ucode 分支也一起拉库编译：
# 它读写 design.global.{mode,navbar,navbar_proxy}，与上面主题的 header.ut 读取
# 同一组 UCI 选项（系统 → Design Config）。kenzok8 feed 里的同名包是老 Lua CBI
# （luasrc/ + luci-compat），必须清掉，否则顶替拉库版导致菜单/ACL 不生效。
#
# 2026-11-25 适配纯 refactor：PON 包换成外部 feed 的 luci-app-rtl9617c-pon，
# 新包已解耦 argon（不再硬依赖 luci-theme-argon / argon 中文包，仅"若安装则
# 自动套用"）。本仓库 Device 定义与 config 都不选 luci-theme-argon，所以它不会
# 进固件。这里仍做两道兜底：清可能抢默认主题的 argon uci-defaults 脚本 + 清
# package 顶层的 argon 包本体（feeds install 已跑完，只删包目录不影响其它包）。
#
# apk 版本号只认一个 '-rN' 作 revision；若 PKG_VERSION 里日期用 '-' 分隔
# （5.8.0-20240106），拼上 -rN 会有两个 '-' 而报 version is invalid。
# 拉库的 ucode fork 已是点分格式（5.8.0.20240106-r2），这里兜底 sed 成 '.'。
# ================================================================
set -euo pipefail

# 失败时给 GitHub 注解，避免静默 exit（pipefail + grep 那类坑看不见原因）
trap 'rc=$?; [ "$rc" -eq 0 ] || echo "::error::overlay-theme 第 $LINENO 行失败 rc=$rc：$BASH_COMMAND" >&2' ERR

ASSETS="${ASSETS:-$GITHUB_WORKSPACE}"
WRT="${WRT:-$PWD}"

echo "=========================================="
echo "overlay-theme: argon -> design（拉库 ucode 版）"
echo "  wrt = $WRT"
echo "=========================================="

test -f "$WRT/package/base-files/files/bin/config_generate" \
  || { echo "ERROR: $WRT 不是 OpenWrt 源码根" >&2; exit 1; }

# ---- 1. 去掉 argon 包本体（兜底；本仓库 config/Device 都不选它）----
rm -rf "$WRT/package/luci-theme-argon" \
       "$WRT/package/feeds/luci/luci-theme-argon" 2>/dev/null || true
find "$WRT/package/feeds" -maxdepth 2 -type l -name 'luci-theme-argon' -delete 2>/dev/null || true
echo "  OK   argon 包本体已移除（兜底）"

# ---- 2. 清 PON 包里可能抢默认主题的 argon uci-defaults ----
# 新包 luci-app-rtl9617c-pon 已解耦 argon，理论上没有这些脚本；这里按目录存在
# 与否做兜底清理（外部 feed 路径 feeds/rtl9617c/luci-app-rtl9617c-pon）。
PON_ROOT=""
for d in "$WRT/feeds/rtl9617c/luci-app-rtl9617c-pon" \
         "$WRT/package/feeds/rtl9617c/luci-app-rtl9617c-pon" \
         "$WRT/package/luci-app-rtl9617c-pon"; do
  [ -d "$d" ] && { PON_ROOT="$d"; break; }
done
n_rm=0
if [ -n "$PON_ROOT" ]; then
  for s in 95-rtl9617c-argon 97-rtl9617c-argon-default \
           95-tyfza1-argon 97-tyfza1-argon-default; do
    f=$(find "$PON_ROOT" -type f -name "$s" 2>/dev/null | head -1)
    if [ -n "$f" ]; then
      rm -f "$f"
      n_rm=$((n_rm+1))
      echo "  OK   已删除 $(basename "$f")"
    fi
  done
  # 若仍有脚本硬写 argon 默认主题，清掉（新包应无；纯兜底）
  # !! 这里必须用「进程替换 + || true」吞掉 grep 的退出码，不能写成
  #    grep ... | while read：脚本开了 pipefail，"一个都没匹配到"时 grep 返回 1
  #    -> 管道整体失败 -> set -e 当场终止脚本，日志里没有任何报错文本。
  #    2026-11-25 run #25（job 139105043712）就是死在这一行：diy-part1 在
  #    0 秒内静默 exit 1，run 页面只有一句 "Process completed with exit code 1"。
  #    本地之所以复现不出来，是因为没装 feeds -> PON_ROOT 为空 -> 整段被跳过。
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rm -f "$f"; echo "  OK   已删除抢 argon 主题脚本 $f"
  done < <(grep -rls -e '/luci-static/argon' -e 'luci\.themes\.Argon' \
             "$PON_ROOT/root/etc/uci-defaults" 2>/dev/null || true)
else
  echo "  note 外部 feed PON 包目录未找到（feeds install 可能未装，通常无碍）"
fi
echo "  OK   PON 包 argon 默认主题兜底清理完成（删除 $n_rm 个）"

# ---- 2b. 去掉 PON 应用 Makefile 里的 argon 依赖（新包已解耦，兜底）----
if [ -n "$PON_ROOT" ]; then
  PON_MK="$PON_ROOT/Makefile"
  if [ -f "$PON_MK" ] && grep -qE '\+luci-theme-argon|\+luci-i18n-argon-config-zh-cn' "$PON_MK"; then
    sed -i -E \
      -e 's/[[:space:]]*\+luci-theme-argon//g' \
      -e 's/[[:space:]]*\+luci-i18n-argon-config-zh-cn//g' \
      "$PON_MK"
    echo "  OK   PON Makefile 兜底去掉 argon 依赖"
  else
    echo "  OK   PON Makefile 无 argon 依赖（新包已解耦）"
  fi
fi

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

# ---- 6. 拉库：design 主题设置页（luci-app-design-config，ucode 版）----
# 设置页读写 design.global.{mode,navbar,navbar_proxy}，与 ucode 主题 header.ut
# 读取的是同一组 UCI 选项；入口在系统 → Design Config。
# 必须拉 ucode 分支：master 是 Lua CBI（依赖 luci-compat + luci-lua-runtime），
# 且 kenzok8 feed 有同名老 Lua 包（luasrc/），会顶替拉库版导致菜单/ACL 失效。
CFG_REPO="https://github.com/felixmm0606/luci-app-design-config.git"
CFG_REF="ucode"
CFG_SHA=""                         # 留空=跟分支 HEAD；需要字节级锁定时填 40 位 SHA
CFG_DST="$WRT/package/luci-app-design-config"

# 6a. 清旧：顶层残留 + kenzok8 feed 同名老 Lua 包实体 + 软链
rm -rf "$CFG_DST" \
       "$WRT/feeds/kenzok8/luci-app-design-config" \
       "$WRT/package/feeds/kenzok8/luci-app-design-config" 2>/dev/null || true

# 6b. 浅克隆 ucode 分支
git clone --depth=1 --branch "$CFG_REF" "$CFG_REPO" "$CFG_DST"
if [ -n "$CFG_SHA" ]; then
  ( cd "$CFG_DST" && git fetch -q --depth=1 origin "$CFG_SHA" && git checkout -q FETCH_HEAD )
fi
test -f "$CFG_DST/Makefile" \
  || { echo "ERROR: design-config 拉库后无 Makefile" >&2; exit 1; }
rm -rf "$CFG_DST/.git"   # 不带 .git 进包目录
echo "  OK   design 主题设置页已拉库（$CFG_REPO @ $CFG_REF，ucode JS 视图）"

# 6b-2. 权限收敛：workflow 只对 feeds/luci 下的 ACL 做 0644，本包在 package/ 顶层
# 不受那段影响；rpcd 会拒绝 world-writable 的 ACL，设置页读写 UCI 就会失败。
chmod 0644 "$CFG_DST/root/usr/share/rpcd/acl.d/luci-app-design-config.json" \
           "$CFG_DST/root/usr/share/luci/menu.d/luci-app-design-config.json" 2>/dev/null || true

# 6c. 版本号兜底：PKG_VERSION 若用 '-' 分隔日期，拼 -rN 会两个 '-' → apk invalid
if grep -qE '^PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+-[0-9]+$' "$CFG_DST/Makefile"; then
  sed -i -E 's/^(PKG_VERSION:=[0-9]+\.[0-9]+\.[0-9]+)-([0-9]+)$/\1.\2/' "$CFG_DST/Makefile"
  echo "  OK   design-config PKG_VERSION 已改 apk 合法格式：$(grep -E '^PKG_VERSION:=' "$CFG_DST/Makefile" | head -1)"
else
  echo "  OK   design-config PKG_VERSION 合法：$(grep -E '^PKG_VERSION:=' "$CFG_DST/Makefile" | head -1)"
fi

# 6d. 断言：必须是纯 ucode 包（JS 视图 + menu.d + ACL + UCI 配置），无老 Lua 残留
grep -q 'luci.mk' "$CFG_DST/Makefile" \
  || { echo "ERROR: design-config Makefile 未 include luci.mk" >&2; exit 1; }
test -f "$CFG_DST/htdocs/luci-static/resources/view/design-config.js" \
  || { echo "ERROR: design-config 缺 ucode JS 视图" >&2; exit 1; }
grep -q "form.Map('design'" "$CFG_DST/htdocs/luci-static/resources/view/design-config.js" \
  || { echo "ERROR: design-config JS 未操作 UCI design 包" >&2; exit 1; }
test -f "$CFG_DST/root/usr/share/luci/menu.d/luci-app-design-config.json" \
  || { echo "ERROR: design-config 缺 ucode menu.d 入口" >&2; exit 1; }
test -f "$CFG_DST/root/usr/share/rpcd/acl.d/luci-app-design-config.json" \
  || { echo "ERROR: design-config 缺 rpcd ACL" >&2; exit 1; }
test -f "$CFG_DST/root/etc/config/design" \
  || { echo "ERROR: design-config 缺 /etc/config/design" >&2; exit 1; }
if grep -qE 'luci-compat|luci-lua-runtime' "$CFG_DST/Makefile"; then
  echo "ERROR: design-config 拉到了 Lua CBI 老版（依赖 luci-compat/luci-lua-runtime）" >&2
  exit 1
fi
test ! -d "$CFG_DST/luasrc" \
  || { echo "ERROR: design-config 含 luasrc/（老 Lua 版，不是 ucode）" >&2; exit 1; }
echo "  OK   design-config 包结构就位（ucode JS 视图 + menu.d + ACL + UCI 配置）"

echo "🎉 overlay-theme.sh 完成"

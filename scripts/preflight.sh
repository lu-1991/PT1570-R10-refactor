#!/bin/bash
# ================================================================
# preflight.sh —— PT1570-R10-CI 静态自检
# 在仓库根目录运行；可选 env WRT=已注入的源码树 做第 8 节深度校验。
# 任何 FAIL 都会让 CI 在编译前终止（workflow 第 12 步调用）。
# ================================================================
set -uo pipefail
cd "$(dirname "$0")/.."

FAILS=0
FAILED_MSGS=()
ok()   { echo "  OK   $*"; }
bad()  { echo "  FAIL $*"; FAILS=$((FAILS+1)); FAILED_MSGS+=("$*"); }
warn() { echo "  WARN $*"; }
sec()  { echo "=== $* ==="; }

# ---------------------------------------------------------------
sec "1. 项目结构完整性"
# workflow 文件名不写死：用户可能在网页上传时改名（如 "Build PT1570-R10.yml"），
# GitHub 不在乎文件名，只要内容对即可 —— 按"目录里至少一个 yml"检查。
WF=$(find .github/workflows -maxdepth 1 -name '*.yml' -o -maxdepth 1 -name '*.yaml' 2>/dev/null | head -1)
for f in diy-part1.sh diy-part2.sh \
         configs/youhua_pt1570-r10.config \
         scripts/apply-board.sh scripts/overlay-theme.sh \
         scripts/patch-upstream.sh scripts/verify-fit-boot.py \
         board/dts/rtl9617c-pt1570-r10.dts board/devices/pt1570-r10.mk.inc \
         files/etc/uci-defaults/96-pt1570-r10-leds \
         files/etc/uci-defaults/97-pt1570-r10-wifi24 \
         files/etc/uci-defaults/98-pt1570-r10-wifi-stability \
         files/etc/uci-defaults/99-pt1570-fit \
         files/lib/firmware/regulatory.db \
         files/lib/firmware/regulatory.db.p7s \
         files/etc/hotplug.d/ieee80211/10-wifi-detect \
         files/etc/uci-defaults/92-pt1570-r10-wifi-default \
         files/etc/uci-defaults/92-pt1570-r10-wireless-country \
         files/etc/init.d/tyfza1-factory; do
  [ -f "$f" ] && ok "$f" || bad "缺 $f"
done
[ -n "$WF" ] && ok "workflow 文件: $WF" || bad "缺 .github/workflows/*.yml"

# ---------------------------------------------------------------
sec "2. 换行符（CRLF 曾让 CI 秒挂）"
python3 - <<'PY' && ok "所有文本文件均为 LF" || bad "存在 CRLF 文件"
import pathlib, sys
bad = [str(p) for p in pathlib.Path('.').rglob('*')
       if p.is_file()
       and '.git' not in p.parts          # .git 二进制对象天然含 \r，跳过
       and p.suffix.lower() not in ('.bin', '.db', '.p7s')  # 二进制资产
       and b'\r' in p.read_bytes()]
for b in bad[:5]: print("    CR:", b)
sys.exit(1 if bad else 0)
PY

# .gitattributes 是给本地 git 用的护栏（Windows 上 core.autocrlf=true 会把
# 脚本写成 CRLF 再提交）。但网页上传会静默丢掉点开头的文件 —— 2026-11-14
# 的 run 就是因此失败：仓库里没有 .gitattributes，这里硬 fail，编译被拦住。
# 所以：有它就必须写好 eol=lf；没有它只警告，但要求 workflow 里确实有
# 运行时 CRLF 归一化步骤兜底（那才是最后一道防线）。
if [ -f .gitattributes ]; then
  grep -q 'eol=lf' .gitattributes \
    && ok ".gitattributes 锁定 LF" \
    || bad ".gitattributes 存在但没写 eol=lf（本地 git 仍可能写入 CRLF）"
else
  if [ -n "$WF" ] && grep -q 'Normalize line endings' "$WF"; then
    warn "缺 .gitattributes（网页上传会丢点文件）；已有 workflow 归一化兜底，不影响编译"
  else
    bad "缺 .gitattributes，且 workflow 没有 CRLF 归一化步骤（CRLF 脚本在路由器上必挂）"
  fi
fi

# ---------------------------------------------------------------
sec "3. 旧 rtl_ax_ap WiFi 资产已清除（纯 refactor 口径）"
# 2026-11-26 清理：切上游 rtw89 mac80211 backport + AP 固件包后，旧 rtl_ax_ap
# 方案的整套射频表/固件 bin 都不再被读取（新驱动把 PHY_REG/RadioA/TXPWR 表
# 编译进 C 数组，校准走 DTS nvmem cell，固件由 rtl*-ap-firmware 包提供）。
# 真机日志证实加载的是 rtw89/rtw8xxx_ap_fw.bin，非 tyfza1/ 下的旧资产。
[ ! -d files/lib/firmware/realtek/tyfza1 ] \
  && ok "旧 tyfza1/ 射频表与固件目录已删除" \
  || bad "仍残留 files/lib/firmware/realtek/tyfza1/（旧 rtl_ax_ap 死资产）"
[ ! -f scripts/verify-rf-tables.py ] \
  && ok "旧 verify-rf-tables.py（rtl_ax_ap 解析器模拟）已删除" \
  || bad "verify-rf-tables.py 仍在（旧方案校验已失效）"
[ ! -e files/lib/firmware/rtw89/rtw8192xb_fw.bin ] \
  && [ ! -e files/lib/firmware/rtw89/rtw8852c_fw.bin ] \
  && ok "非 AP 版 rtw89 固件已删除（AP 版由固件包提供）" \
  || bad "仍残留非 AP 版 rtw89 固件（真机不用，白占固件体积）"

# ---------------------------------------------------------------
sec "4. 机型配置关键符号"
CFG=configs/youhua_pt1570-r10.config
for sym in CONFIG_TARGET_rtl9617c=y CONFIG_PACKAGE_fitblk=y \
           CONFIG_PACKAGE_rtl9617c-pon-control=y CONFIG_PACKAGE_luci-ssl=y \
           CONFIG_PACKAGE_uhttpd=y CONFIG_PACKAGE_luci=y \
           CONFIG_PACKAGE_wpad-basic-mbedtls=y CONFIG_LUCI_LANG_zh_Hans=y; do
  grep -q "^${sym}$" "$CFG" && ok "$sym" || bad "$CFG 缺 $sym"
done
! grep -q '^CONFIG_PACKAGE_uboot-envtools=y$' "$CFG" \
  && ok "uboot-envtools 未启用" || bad "uboot-envtools 必须关闭"
# 机型选择已移交 diy-part2（target_model 输入）：配置文件不得再写死任何 DEVICE
grep -qE '^CONFIG_TARGET_rtl9617c_generic_DEVICE_.+=y$' "$CFG" \
  && bad "$CFG 仍写死机型（应由 diy-part2 按 TARGET_MODEL 选择）" \
  || ok "配置文件机型无关（机型选择在 diy-part2）"
grep -q 'PROFILE="\${TARGET_MODEL' diy-part2.sh \
  && grep -q 'ALL_DEVICES=' diy-part2.sh \
  && ok "diy-part2 机型选择逻辑在位" || bad "diy-part2 缺机型选择逻辑"

# 主题与软件包口径：design 主题 + 设置页（拉库 ucode 版），不含 argon/Fluent/tailscale/samba/upnp/wol
grep -q '^CONFIG_PACKAGE_luci-theme-design=y$' "$CFG" \
  && ok "luci-theme-design=y（用户配置口径：默认主题 design）" \
  || bad "$CFG 缺 luci-theme-design"
grep -q '^CONFIG_PACKAGE_luci-app-design-config=y$' "$CFG" \
  && ok "luci-app-design-config=y（design 主题设置页编进固件）" \
  || bad "$CFG 缺 luci-app-design-config（主题设置页不会编进固件）"
! grep -q '^CONFIG_PACKAGE_luci-theme-argon=y$' "$CFG" \
  && ok "argon 未启用（主题已换成 design）" \
  || bad "$CFG 仍启用 luci-theme-argon（与 design 抢默认主题）"
! grep -q '^CONFIG_PACKAGE_luci-theme-fluent=y$' "$CFG" \
  && ok "未启用 Fluent（按用户要求移除）" \
  || bad "$CFG 仍启用 luci-theme-fluent（应移除）"
! grep -qE '^CONFIG_PACKAGE_(tailscale|luci-app-samba4|vsftpd|luci-app-upnp|luci-app-wol)=y$' "$CFG" \
  && ok "未含 tailscale/samba/vsftpd/upnp/wol（用户配置口径）" \
  || bad "$CFG 含未约定的服务包（tailscale/samba/vsftpd/upnp/wol）"
# 双频 WiFi / USB / LuCI 中文核心包断言（纯 refactor 配置口径）
# 2026-11-25：rtw89 改为 kmod 包 + AP 固件（上游 299da19）；wpad 用 basic-mbedtls。
for sym in CONFIG_PACKAGE_wpad-basic-mbedtls=y CONFIG_PACKAGE_iw=y \
           CONFIG_PACKAGE_kmod-rtw89-8852ce=y CONFIG_PACKAGE_kmod-rtw89-8192xbe=y \
           CONFIG_PACKAGE_kmod-usb-storage=y CONFIG_PACKAGE_ucode-mod-math=y \
           CONFIG_PACKAGE_luci-i18n-base-zh-cn=y; do
  grep -q "^${sym}$" "$CFG" && ok "$sym" || bad "$CFG 缺 $sym"
done
! grep -q '^CONFIG_PACKAGE_kmod-rtl-ax-ap=y$' "$CFG" \
  && ok "逆向 kmod-rtl-ax-ap 已移除" \
  || bad "$CFG 仍有 kmod-rtl-ax-ap（与 rtw89 抢 PCI 设备）"
# 默认主题：design 由包自带 30_luci-theme-design 设定；argon/Fluent 抢主题脚本都不应有
[ ! -f files/etc/uci-defaults/98-pt1570-fluent-default ] \
  && ok "无 Fluent 默认主题脚本（design 由包自带脚本设定）" \
  || bad "存在 98-pt1570-fluent-default，会抢走默认主题"
! grep -rqs -e '/luci-static/argon' -e 'luci\.themes\.Argon' files/ 2>/dev/null \
  && ok "files/ 无 argon 默认主题设置" \
  || bad "files/ 仍有 argon 主题设置（会抢走 design）"
# 静态主题文件（htdocs 等）不许出现在 files/（design 走包构建，不注入静态文件）
! find files \( -iname '*vantage*' -o -iname '*fluent*' -o -iname '*argon*' \
                -o -iname '*design*' \) \
    ! -path '*/etc/uci-defaults/*' -print -quit 2>/dev/null | grep -q . \
  && ok "files/ 无静态主题残留" || bad "files/ 残留主题注入文件（应删除）"

# 主题链路（diy-part1 -> overlay-theme.sh）：拉库 ucode 版 design
# 老式 Lua 模板（header.htm + disp.node）在 ucode LuCI 下报 __entries nil → 500，
# 必须是带 ucode .ut 模板的 fork（felixmm0606/luci-theme-design@ucode）。
grep -q 'scripts/overlay-theme.sh' diy-part1.sh \
  && ok "diy-part1 接入 overlay-theme.sh" || bad "diy-part1 未调用 overlay-theme.sh"
grep -q 'felixmm0606/luci-theme-design' scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 拉库 ucode 版 design（felixmm0606）" \
  || bad "overlay-theme.sh 未用 ucode 版 design（老 Lua 模板会 500）"
grep -q 'git clone' scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 有 design 拉库逻辑" \
  || bad "overlay-theme.sh 缺 design 拉库逻辑"
grep -q 'ucode/template/themes/design/header.ut' scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 断言 ucode header.ut（防退回老 Lua 模板）" \
  || bad "overlay-theme.sh 未断言 ucode .ut 模板（会踩 __entries nil）"
! grep -q 'DST=.*kenzok8/luci-theme-design' scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 不以 kenzok8 feed 作为 design 来源" \
  || bad "overlay-theme.sh 仍从 kenzok8 feed 取 design（老 Lua 模板会 500）"
# design 主题设置页：同作者 ucode 版；kenzok8 feed 有同名老 Lua 包，必须清掉
grep -q 'CFG_REPO="https://github.com/felixmm0606/luci-app-design-config.git"' scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 拉库 ucode 版 design-config 设置页" \
  || bad "overlay-theme.sh 未拉库 design-config 设置页"
grep -q 'design-config.js' scripts/overlay-theme.sh \
  && grep -q "form.Map('design'" scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 断言 design-config ucode JS 视图" \
  || bad "overlay-theme.sh 未断言 design-config ucode 视图"
grep -q 'feeds/kenzok8/luci-app-design-config' scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 清理 kenzok8 同名老 Lua 包" \
  || bad "overlay-theme.sh 未清理 kenzok8 同名 design-config（会顶替拉库版）"
grep -q 'luci-compat|luci-lua-runtime' scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 拒绝 design-config 老 Lua CBI 版" \
  || bad "overlay-theme.sh 未拒绝 design-config 老 Lua CBI 版"
for s in 95-tyfza1-argon 97-tyfza1-argon-default; do
  grep -q "$s" scripts/overlay-theme.sh \
    && ok "overlay-theme.sh 删除厂商 $s" || bad "overlay-theme.sh 未删除 $s"
done
# 2026-11-25 纯 refactor：PON 包换成外部 feed 的 luci-app-rtl9617c-pon，新包已
# 解耦 argon；overlay-theme.sh 只做兜底清理（argon 包本体 + 抢主题脚本 + 依赖）。
grep -q 'luci-app-rtl9617c-pon' scripts/overlay-theme.sh \
  && grep -q 'rtl9617c-argon' scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 适配外部 feed PON 包（rtl9617c-pon + argon 兜底清理）" \
  || bad "overlay-theme.sh 未适配 luci-app-rtl9617c-pon / argon 兜底"
grep -q '/luci-static/design' scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 断言 design 默认主题脚本" \
  || bad "overlay-theme.sh 缺 design 默认主题断言"
# PKG_VERSION 日期里的 '-' 会让 apk 报 package version is invalid（Error 99）
grep -q 'PKG_VERSION:=' scripts/overlay-theme.sh \
  && grep -qE "s/\^\(PKG_VERSION" scripts/overlay-theme.sh \
  && ok "overlay-theme.sh 修正 PKG_VERSION 为 apk 合法格式" \
  || bad "overlay-theme.sh 未修正 PKG_VERSION（apk 会判非法版本 Error 99）"

# ---------------------------------------------------------------
sec "5. workflow 结构与防回归"
if [ -z "$WF" ]; then
  bad "没有 workflow 文件可检查"
else
grep -q 'configs/youhua_pt1570-r10.config' "$WF" \
  && ok "引用机型配置" || bad "未引用机型配置"
grep -q 'diy-part1.sh' "$WF" && grep -q 'diy-part2.sh' "$WF" \
  && ok "diy 两段式已接入" || bad "workflow 未调用 diy 脚本"
! grep -q 'package/luci-theme-argon' "$WF" \
  && ok "workflow 不再 checkout argon 包（主题走 design 拉库）" \
  || bad "workflow 仍 checkout package/luci-theme-argon（会与 design 抢主题）"
! grep -qi 'wifi_diag\|CONFIG_DEVMEM' "$WF" \
  && ok "无诊断模式残留" || bad "workflow 仍有 wifi_diag/DEVMEM"
! grep -q 'matrix:' "$WF" \
  && ok "无 matrix（R10-only 固化）" || bad "不应再有 matrix"
grep -q 'Build PE firmware' "$WF" \
  && bad "仍有现场 PE 编译步骤（应由 overlay 的 pe-tx-code.h 提供）" \
  || ok "已删除现场 PE 编译（md5 校验在 diy-part2）"
grep -q 'target_model:' "$WF" \
  && ok "机型可选输入（target_model）" || bad "缺机型选择输入"
grep -q 'release_tag=$RELEASE_TAG' "$WF" \
  && ok "按机型固定 tag 滚动 Release" || bad "Release tag 不是按机型固定"
grep -q 'Restore dl cache' "$WF" \
  && ok "dl 缓存已启用" || bad "缺 dl 缓存（编译会慢很多）"
grep -q 'verify-fit-boot.py' "$WF" \
  && ok "产物可启动性校验已接入" || bad "缺 verify-fit-boot 校验"
fi

# ---------------------------------------------------------------
sec "5b. 打包链（改名后的路径 / rootfs 脚本执行权限）"
if [ -n "$WF" ] && [ -f "$WF" ]; then
  # init.d 脚本必须补 +x：Git 不保存 Unix mode，网页上传一律 100644，
  # 丢了 +x 的 init 脚本首启根本不执行 -> 校准文件不生成 -> 无线全无（真机定位）。
  grep -q 'files/etc/init.d' "$WF" \
    && ok "workflow 给 files/etc/init.d 补执行权限" \
    || bad "workflow 未 chmod files/etc/init.d（校准脚本不跑，无线全无）"
  grep -q 'ROOTFS_EXEC_OK' "$WF" \
    && ok "镜像内脚本权限断言在位" || bad "缺 ROOTFS_EXEC_OK 权限断言"
  # Stamp 会把 -squashfs-sysupgrade 与 .itb 之间插入时间戳，
  # 单固件 artifact 的 glob 必须以 * 收尾，写死 .itb 会永远匹配不到。
  grep -q 'squashfs-sysupgrade\*\.itb' "$WF" \
    && ok "单固件 artifact 路径兼容时间戳改名" \
    || bad "单固件 artifact 路径写死 .itb（改名后匹配不到）"
  # 文件名里不能有冒号：Windows 解压 zip / 保存 Release 附件会失败。
  grep -q "date '+%Y%m%d-%H%M'" "$WF" \
    && ok "文件名时间戳 Windows 安全（无冒号/括号）" \
    || bad "文件名时间戳含冒号，Windows 上解压会失败"
else
  bad "没有 workflow 可检查"
fi

# ---------------------------------------------------------------
sec "5c. 无线默认值（2026-11-16 起对齐原厂：协议/信道交还驱动推导）"
# 回归点（都真实发生过）：
#   * 加密改回 psk2 / SSID 不分频段 -> 首启分不清哪个是 2.4G；
#   * 生成器把 wifi-iface 写 disabled=1 -> 刷完看不到任何 SSID。
# 2026-11-16 决定：htmode / 信道不再钉死（原厂 rootfs 的 mac80211.uc 与上游
# 逐行相同，全靠驱动能力推导：2G=HE20、5G=HE80、信道 auto）。
# 历史：2026-11-14 曾钉 2G HT20 修"手机搜不到 2.4G"，未经真机复验即回退。
D2=diy-part2.sh
if [ -f "$D2" ]; then
  ! grep -qF 'htmode = "HT20"' "$D2" \
    && ok "生成器不钉 htmode（协议交还驱动推导，与原厂一致）" \
    || bad "diy-part2 仍存在 HT20 钉死（应交还驱动推导）"
  grep -qF "band_name == '2g' ?" "$D2" \
    && ok "SSID 按频段区分（-2.4G / -5G）" \
    || bad "diy-part2 未按频段区分 SSID"
  grep -qF "', 'none')," "$D2" \
    && ok "无线默认开放（encryption=none）" \
    || bad "diy-part2 未把默认加密设为 none"
  grep -q 'command -v python3' "$D2" \
    && ok "改写前检查 python3（缺了会明确报错）" \
    || bad "diy-part2 未检查 python3"
  W24=files/etc/uci-defaults/97-pt1570-r10-wifi24
  [ -f "$W24" ] \
    && ok "2.4G 开机兜底脚本在位" || bad "缺 $W24"
  grep -qE "country='?CN" "$W24" 2>/dev/null \
    && ok "兜底脚本统一 country=CN（与原厂 92 号一致）" || bad "兜底脚本未设 country=CN"
  ! grep -qE "htmode='?[A-Z]+[0-9]+|channel='?[0-9]+" "$W24" 2>/dev/null \
    && ok "兜底脚本不钉 htmode / 信道" || bad "兜底脚本钉死了 htmode / 信道"
  # 只碰 2.4G：脚本里出现 radio0 的直写就说明会连 5G 一起改，属于越界
  ! grep -q 'radio0' "$W24" 2>/dev/null \
    && ok "兜底脚本不碰 5G（无 radio0 直写）" || bad "兜底脚本出现 radio0 直写"
  # 断流缓解脚本（2026-11-16）：不踢空闲终端 + 统一 country=CN
  W98=files/etc/uci-defaults/98-pt1570-r10-wifi-stability
  [ -f "$W98" ] \
    && ok "断流缓解脚本在位" || bad "缺 $W98"
  grep -q 'skip_inactivity_poll' "$W98" 2>/dev/null \
    && grep -q 'disassoc_low_ack' "$W98" 2>/dev/null \
    && ok "断流缓解：不踢空闲终端（skip_inactivity_poll + disassoc_low_ack）" \
    || bad "断流缓解脚本缺 skip_inactivity_poll / disassoc_low_ack"
  ! grep -qE "htmode='?[A-Z]+[0-9]+|channel='?[0-9]+" "$W98" 2>/dev/null \
    && ok "断流缓解脚本不钉 htmode / 信道" || bad "断流缓解脚本钉死了 htmode / 信道"
  ! grep -q 'radio0' "$W98" 2>/dev/null \
    && ok "断流缓解脚本按 band/hwmode 判定（无 radio0 直写）" \
    || bad "断流缓解脚本出现 radio0 直写"
fi

# ---------------------------------------------------------------
sec "5d. 编译加速（缓存 / ccache / 并发）"
if [ -n "$WF" ] && [ -f "$WF" ]; then
  grep -q 'pt1570-tc-\${{ env.SOURCE_HASH }}' "$WF" \
    && ok "工具链缓存按源码 hash 分 key" \
    || bad "缺工具链缓存（每次都要重编 10 分钟）"
  grep -q 'staging_dir/toolchain-\*' "$WF" \
    && ok "工具链缓存路径覆盖 staging_dir/toolchain-*" \
    || bad "工具链缓存路径不对"
  grep -q 'pt1570-ccache-' "$WF" \
    && ok "ccache 缓存已接入" || bad "缺 ccache 缓存"
  grep -q 'pt1570-feeds-' "$WF" \
    && ok "feeds 目录缓存已接入" || bad "缺 feeds 缓存"
  grep -q 'build_initramfs' "$WF" \
    && ok "initramfs 可选构建（默认省 8 分钟）" \
    || bad "缺 build_initramfs 输入"
  grep -q 'BUILD_INITRAMFS' "$WF" && grep -q 'BUILD_INITRAMFS' diy-part2.sh \
    && ok "BUILD_INITRAMFS 已传到 diy-part2" || bad "BUILD_INITRAMFS 未贯通"
  grep -q 'CONFIG_CCACHE=y' diy-part2.sh \
    && ok "diy-part2 启用 CONFIG_CCACHE" || bad "diy-part2 未启用 ccache"
  # 上游 config/Config-devel.in 里 CCACHE 是 `bool "Use ccache" if DEVEL`：
  # DEVEL=n 时该符号不可见，defconfig 会把 CCACHE 强制回 not set。
  # 2026-11-14 实测过：只写 CCACHE=y 会让第 6 节断言失败，job 25 秒退出。
  grep -q 'CONFIG_DEVEL=y' diy-part2.sh \
    && ok "diy-part2 同时打开 CONFIG_DEVEL（CCACHE 才可见）" \
    || bad "缺 CONFIG_DEVEL=y，CONFIG_CCACHE 会被 defconfig 重置"
  grep -q 'CONFIG_AUTOREBUILD is not set' diy-part2.sh \
    && ok "diy-part2 关闭 AUTOREBUILD（DEVEL 会把它默认成 y）" \
    || bad "缺 AUTOREBUILD 关闭，DEVEL=y 后 make 会反复重编"
  grep -q 'openwrt/.ccache' "$WF" \
    && ok "ccache 缓存路径含源码根 .ccache（rules.mk 的真实目录）" \
    || bad "ccache 缓存路径不对（rules.mk 用 TOPDIR/.ccache，不是 staging_dir）"
  # -F + 双引号里转义 $：匹配 diy-part2 里那条 `grep -q '^CONFIG_DEVEL=y$'` 硬断言
  grep -qF "CONFIG_DEVEL=y\$" diy-part2.sh \
    && ok "DEVEL 在硬断言里被复核" || bad "硬断言缺 DEVEL 复核（DEVEL 被丢则 CCACHE 也废）"

  # 上游锁定 SHA：inputs 默认值与 env 兜底值必须一致，且必须是完整 40 位。
  # 回归点：只改一处 -> 界面显一个值、实际编另一个，日志和镜像对不上。
  ref_input=$(grep -oE "default: '[0-9a-f]{40}'" "$WF" | head -1 | grep -oE "[0-9a-f]{40}")
  ref_env=$(grep -E "SOURCE_REF:" "$WF" | grep -oE "'[0-9a-f]{40}'" | head -1 | tr -d "'")
  if [ -n "$ref_input" ] && [ "$ref_input" = "$ref_env" ]; then
    ok "上游锁定 SHA 两处一致（$(echo "$ref_input" | cut -c1-7)…）"
  else
    bad "上游锁定 SHA 不一致（input=${ref_input:-空} env=${ref_env:-空}）"
  fi
  [ "${#ref_input}" -eq 40 ] \
    && ok "上游锁定为完整 40 位 SHA（字节级可复现）" \
    || bad "上游锁定不是完整 40 位 SHA，无法保证可复现"

  # 纯 refactor 单基线护栏（2026-11-25 起）：基线必须是 c815335，且不得再叠加
  # 20b4cf4 硬件层（Taurus 驱动已不认旧 rtl9617c-* compatible，叠加会编译失败）。
  # 2026-11-27 从 b842507 升到 c815335：后者含 flush/beacon timeout 修复、
  # txpower 下发与 rmmod 崩溃修复（79b6a45），真机 2.4G "timed out to flush
  # queues" 与 rmmod list corruption 都靠它；b842507 的 8192XB 闭环校准与
  # cd75278 的 PCIe coherent/irq-affinity 仍是 2.4G 发射链路的必要前提。
  grep -qE "default: 'c81533502df6533b273c5201f99f67abd88c62ab'" "$WF" \
    && ok "克隆基线为 refactor @ c815335（纯 refactor 单基线 + wifi flush/txpower 修复）" \
    || bad "克隆基线不是 refactor @ c815335"
  grep -q 'rtw8192xb_tssi_track' "$WF" \
    && ok "Clone 断言基线含 8192XB 闭环射频校准（b842507）" \
    || bad "Clone 未断言 b842507（回退基线会丢掉 2.4G TX 标定）"
  grep -qF 'devm_kfree(rtwdev->dev, sband)' "$WF" \
    && ok "Clone 断言基线含 rmmod 崩溃修复（79b6a45）" \
    || bad "Clone 未断言 79b6a45（回退基线会重新引入 kfree/devm 崩溃）"
  grep -qF 'B_AX_WDE_EMPTY_QUE_CMAC0_MBH' "$WF" \
    && ok "Clone 断言基线含 flush/beacon timeout 修复（c815335）" \
    || bad "Clone 未断言 c815335（回退基线会重新引入 2.4G flush 超时）"
  ! grep -q 'HARDWARE_REF:' "$WF" \
    && ! grep -q 'rm -rf target/linux/rtl9617c' "$WF" \
    && ok "已移除 20b4cf4 硬件层叠加（纯 refactor）" \
    || bad "仍残留硬件层叠加逻辑（Taurus 树会冲突）"
  grep -q 'rtk-taurus.dtsi' "$WF" \
    && ok "Clone 断言为 Taurus 树（rtk-taurus.dtsi）" \
    || bad "Clone 未断言 Taurus 树结构"
  grep -q 'SOURCE_HASH=${BASE_HASH}' "$WF" \
    && ok "缓存 key 绑定基线 SHA" \
    || bad "缓存 key 未绑定基线 SHA"
else
  bad "没有 workflow 可检查"
fi

# ---------------------------------------------------------------
sec "5e. Release 旧附件清理（滚动发布只留最新一套）"
if [ -n "$WF" ] && [ -f "$WF" ]; then
  grep -q 'prune_release:' "$WF" \
    && ok "存在 prune_release 开关（默认勾选）" || bad "缺 prune_release 输入"
  grep -q 'PRUNE_RELEASE:' "$WF" \
    && ok "PRUNE_RELEASE 已映射到 env" || bad "PRUNE_RELEASE 未进入 env"

  l_keep=$(grep -n 'name: Record release asset whitelist' "$WF" | cut -d: -f1)
  l_up=$(grep -n 'name: Upload firmware to release' "$WF" | cut -d: -f1)
  l_pru=$(grep -n 'name: Prune stale release assets' "$WF" | cut -d: -f1)
  if [ -n "$l_keep" ] && [ -n "$l_up" ] && [ -n "$l_pru" ] \
     && [ "$l_keep" -lt "$l_up" ] && [ "$l_up" -lt "$l_pru" ]; then
    ok "顺序：记清单 → 上传 → 清理（先传后删，上传失败不会留空 Release）"
  else
    bad "上传/清理顺序不对（keep=${l_keep:-无} up=${l_up:-无} prune=${l_pru:-无}）"
  fi

  # 判空护栏：清单为空时 grep 会失败，若当成"不匹配"会把附件全删光
  grep -q '本次产物清单为空，跳过清理' "$WF" \
    && ok "护栏：清单为空则跳过清理" || bad "缺『清单为空跳过』护栏"
  grep -q '零交集' "$WF" \
    && ok "护栏：清单与附件零交集则中止" || bad "缺『零交集中止』护栏"
  grep -q 'GH_TOKEN' "$WF" \
    && ok "清理步骤带 GH_TOKEN（依赖 contents: write）" || bad "清理步骤缺 GH_TOKEN"
else
  bad "没有 workflow 可检查"
fi

# ---------------------------------------------------------------
sec "6. rtw89 WiFi（纯 refactor: mac80211 backport + AP 固件包）"
# 2026-11-25：上游 299da19 把 rtw89 从"内核内置源码 + 740 补丁"改为
# mac80211 backport 补丁(100-103) + kmod 包 + rtl*-ap-firmware 包。
# 本仓库不再注入任何驱动源码/NCTL/固件内置；这里核验配置口径与 DTS 链路。
for sym in kmod-rtw89-8852ce rtl8852ce-ap-firmware \
           kmod-rtw89-8192xbe rtl8192xbe-ap-firmware wpad-basic-mbedtls; do
  grep -q "^CONFIG_PACKAGE_${sym}=y$" configs/youhua_pt1570-r10.config \
    && ok "config 启用 CONFIG_PACKAGE_${sym}=y" \
    || bad "config 缺 CONFIG_PACKAGE_${sym}=y（上游 299da19 WiFi 方案）"
done
DTS=board/dts/rtl9617c-pt1570-r10.dts
grep -q '#include "rtk-taurus.dtsi"' "$DTS" \
  && ok "R10 DTS 基于 rtk-taurus.dtsi（纯 refactor）" \
  || bad "R10 DTS 未基于 rtk-taurus.dtsi"
grep -q 'realtek,ap-firmware' "$DTS" \
  && ok "R10 DTS 5G 节点设 realtek,ap-firmware" \
  || bad "R10 DTS 缺 realtek,ap-firmware（AP 固件不会被选用）"
# 2026-11-26 真机定案：双频都用 RFE54（eFEM）。
# rtw8192xb_rfe_gpio() 只有 rfe_type > 50 才配 PAPE/TRSW/LNAON 的 GPIO 路由，
# 写 50（iFEM）时外置 FEM 的 T/R 开关停在接收侧、PA 使能悬空，实测症状是
# RX 正常（扫到 -60dBm 邻居 AP）、AP-ENABLED、txpower 20dBm、驱动 tx_packets
# 也在涨，但手机贴着天线也搜不到 SSID —— 所以 2.4G 必须是 eFEM。
# 曾经的错判依据"旧厂商固件用 RFE50/PON_2G 表"，但那份固件同时带了 RFE50 与
# RFE54 两套表（一套固件覆盖多板型），不能反推本板型号。
[ "$(grep -c 'realtek,rfe-type = <54>' "$DTS")" -eq 2 ] \
  && ok "R10 DTS 双频均为 RFE54（eFEM，PA/TRSW/LNAON GPIO 才会被路由）" \
  || bad "R10 DTS RFE54 数量 != 2（双频都必须 eFEM，2.4G 写 50 会完全不出信号）"
! grep -q 'realtek,rfe-type = <50>' "$DTS" \
  && ok "R10 DTS 无 RFE50（iFEM 不配 GPIO，2.4G TX 会全哑）" \
  || bad "R10 DTS 仍残留 rfe-type=50（2.4G 会 RX 正常但完全不发射）"
grep -q 'reset-gpios = <&gpio_bank3 5 GPIO_ACTIVE_LOW>' "$DTS" \
  && grep -q 'reset-gpios = <&gpio_bank3 6 GPIO_ACTIVE_LOW>' "$DTS" \
  && ok "R10 DTS 两路 PCIe PERST# 已配置（WiFi 卡可枚举）" \
  || bad "R10 DTS 缺 PCIe PERST# reset-gpios（wlan 不会出现）"
# 2026-11-26 上游 cd75278：pcie-taurus 读 "irq-affinity" 把父中断绑到指定 CPU。
# 不写该属性驱动记 -1 直接跳过（不会失败），但两路 WiFi 的 MSI 就都压在 CPU0
# 上和协议栈/软中断抢核。tianyi 板 DTS 也是 0/1 -> CPU1、CPU2，这里对齐。
grep -q 'irq-affinity = <1>' "$DTS" && grep -q 'irq-affinity = <2>' "$DTS" \
  && ok "R10 DTS 两路 PCIe 父中断绑核（pcie0->CPU1 / pcie1->CPU2，上游 cd75278）" \
  || bad "R10 DTS 缺 irq-affinity（WiFi 中断全压在 CPU0）"
grep -q 'wifi_cal_radio0' "$DTS" && grep -q 'wifi_cal_radio1' "$DTS" \
  && ok "R10 DTS 绑定双频 factory 校准 cell" \
  || bad "R10 DTS 未绑定 wifi_cal_radio0/1"
grep -q 'label = "lan1"' "$DTS" && grep -q 'label = "lan4"' "$DTS" \
  && ok "R10 DTS 端口按面板丝印命名（lan1..lan4）" \
  || bad "R10 DTS 缺端口 label（Taurus NI 驱动靠它命名）"
# 旧方案残留必须清干净
[ ! -e scripts/overlay-rtw89.sh ] && [ ! -d board/rtw89 ] && [ ! -d board/wifi ] \
  && ok "旧 rtw89 注入资产已移除（overlay-rtw89/board/rtw89/board/wifi）" \
  || bad "仍残留旧 rtw89 注入资产（会与上游 backport 方案冲突）"
! grep -qE 'bash .*overlay-rtw89\.sh|overlay-rtw89\.sh"' diy-part1.sh diy-part2.sh \
  && ok "diy 不再调用 overlay-rtw89.sh" \
  || bad "diy 仍调用 overlay-rtw89.sh"
! grep -qE '^[[:space:]]*CONFIG_PACKAGE_kmod-rtl-ax-ap=' configs/*.config \
  && ok "构建链无 kmod-rtl-ax-ap" \
  || bad "仍有 kmod-rtl-ax-ap（与 rtw89 抢 PCI 设备）"

# ---------------------------------------------------------------
sec "7. tyfza1-factory 仅保留在用链路（PON/MAC/BOSA）"
INIT=files/etc/init.d/tyfza1-factory
# WiFi flash-calibration 已由 DTS nvmem 直读，脚本不应再有实际调用（注释里
# 说明历史可以保留，只匹配非注释行：行首去空白后不是 #）。
! grep -qE '^[[:space:]]*[^#[:space:]].*flash-calibration' "$INIT" \
  && ok "tyfza1-factory 已移除 WiFi flash-calibration 死代码" \
  || bad "tyfza1-factory 仍调用已删除的 flash-calibration"
! grep -qE '^[[:space:]]*[^#[:space:]]*(factory_fallback|\. factory_fallback)' "$INIT" \
  && ok "tyfza1-factory 已移除 factory_fallback 死代码" \
  || bad "tyfza1-factory 仍调用 factory_fallback（fallback bin 已删）"
# 仍在用的三件事必须保留
grep -q 'pon_factory' "$INIT" && grep -q 'bosa-calibration.bin' "$INIT" \
  && grep -q 'lan_mac' "$INIT" \
  && ok "tyfza1-factory 保留 PON/MAC/BOSA 在用链路" \
  || bad "tyfza1-factory 误删了仍在用的 PON/MAC/BOSA 链路"
sh -n "$INIT" && ok "tyfza1-factory 语法检查通过" || bad "tyfza1-factory 语法错误"

# ---------------------------------------------------------------
sec "7b. R10 端口命名与面板灯（2026-11-14 真机逐口验证的接线修正）"
# 2026-11-25 纯 refactor：Taurus NI 驱动直接读 DTS 的 label 属性命名端口，
# 不再需要旧的 xram "index = 4 - port" 内核补丁（上游已删该文件）。
grep -q 'label = "lan1"' board/dts/rtl9617c-pt1570-r10.dts \
  && grep -q 'label = "lan4"' board/dts/rtl9617c-pt1570-r10.dts \
  && ok "R10 端口按 DTS label 命名（lan1..lan4=面板 LAN1..LAN4）" \
  || bad "R10 DTS 缺端口 label（Taurus NI 驱动靠它命名）"
test -f files/etc/uci-defaults/96-pt1570-r10-leds \
  && ok "R10 面板灯纠正脚本在位" || bad "缺 96-pt1570-r10-leds"
# 默认 WAN 已按用户要求彻底去掉（pon0.1101 + PPPoE + PON FE 三项全无）：
# 本机 95 脚本必须不存在，且 apply-board.sh 必须在编译时删掉上游 90 脚本，
# 否则上游 90 会在首次开机写出 pon0.3961 + PPPoE 的默认 WAN。
[ ! -e files/etc/uci-defaults/95-pt1570-wan-default ] \
  && ok "本机默认 WAN 脚本已移除（无 pon0.1101/PPPoE/PON FE）" \
  || bad "95-pt1570-wan-default 仍在：出厂会带默认 WAN，与要求不符"
grep -q '90-tyfza1-pon-wan' scripts/apply-board.sh \
  && grep -q 'rm -f "$UPSTREAM_WAN"' scripts/apply-board.sh \
  && ok "apply-board.sh 会删除上游 90 默认 WAN 脚本" \
  || bad "apply-board.sh 未删除上游 90-tyfza1-pon-wan（首次开机会冒出 PPPoE WAN）"

# ---------------------------------------------------------------
sec "7d. 系统内升级（纯 refactor：platform.sh 已自带 fit_do_upgrade）"
# 2026-11-25：refactor 的 platform.sh 已用 fit_do_upgrade + RAMFS_COPY_BIN 带
# fitblk/fit_check_sign，本仓库 apply-board.sh 只需加 R10 机型白名单，不再注入
# 升级流程，也没有 H10 pt1500-fip.sh 覆盖问题（上游已删该脚本）。
grep -q 'fit_do_upgrade "$1"' scripts/apply-board.sh \
  && ok "apply-board.sh 仍断言 platform.sh 用 fit_do_upgrade" \
  || bad "apply-board.sh 缺 fit_do_upgrade 断言（系统内升级会失败）"
grep -qF 'tianyi,tyfza1-2p5g|\\' scripts/apply-board.sh \
  && grep -qF 'youhua,pt1570-r10)' scripts/apply-board.sh \
  && ! grep -qF "out.append(f'{indent}{name} |" scripts/apply-board.sh \
  && ok "apply-board.sh 注入合法 R10 case 分支（check + upgrade）" \
  || bad "apply-board.sh 未注入合法 platform.sh 白名单（旧写法会生成伪 case 分支）"
grep -q '4xGE, UBI' board/dts/rtl9617c-pt1570-r10.dts \
  && ok "概览标记 UBI（区别于旧固件 FIT ABI，看型号即知升级是否生效）" \
  || bad "DTS model 缺 UBI 概览标记"

# ---------------------------------------------------------------
sec "7e/7f. WiFi 链路口径（旧 symlink/ITB 资产已清，保留在用项）"
# 2026-11-26：flash-calibration.bin symlink、fallback blob、ITB 射频表目录
# 随 tyfza1/ 一并删除——新 rtw89 驱动走 nvmem cell + 编译进驱动的表 + 固件包，
# 这些旧链路的断言已失效，全部移除。
# rtw89 为 kmod 包（AutoProbe），不需要 modules.d 手动加载；
# 旧的 rtl_ax_ap 加载项必须移除。
[ ! -f files/etc/modules.d/50-rtl-ax-ap ] \
  && ok "旧 rtl_ax_ap 模块加载项已移除" \
  || bad "50-rtl-ax-ap 仍在（会 modprobe 不存在的 rtl_ax_ap）"
grep -q 'PT1570-R10-5G-' files/etc/uci-defaults/92-pt1570-r10-wifi-default \
  && grep -q 'PT1570-R10-' files/etc/uci-defaults/92-pt1570-r10-wifi-default \
  && ok "首启双频 SSID 由 LAN MAC 生成" || bad "92-wifi-default 缺 SSID 派生逻辑"
for s in 92-pt1570-r10-wifi-default 92-pt1570-r10-wireless-country \
         97-pt1570-r10-wifi24 98-pt1570-r10-wifi-stability; do
  ! grep -qE 'pon0\.|pppoe|PPPoE|interface .*wan' "files/etc/uci-defaults/$s" \
    && ok "$s 无默认 WAN 注入" || bad "$s 混入了默认 WAN 配置"
done

# ---------------------------------------------------------------
sec "7g. 5G 法规域 regdb（2026-11-21：缺签名 = 5G 永远不广播）"
# 真机定位：regulatory.db 无配套 .p7s -> 内核判 regdb 无效 -> world domain(00)
# -> 5G 信道全 NO-IR -> hostapd 起 5G AP 失败。必须带正确签名的 db+p7s。
RD=files/lib/firmware/regulatory.db
RDP=files/lib/firmware/regulatory.db.p7s
[ "$(stat -c %s "$RD" 2>/dev/null)" = "6348" ] \
  && [ "$(md5sum "$RD" 2>/dev/null | cut -d' ' -f1)" = "f90f67fbb0bc2f8490c8266557630e92" ] \
  && ok "regulatory.db 含 CN 规则（6348B, md5 校验）" \
  || bad "regulatory.db 缺失/损坏（5G 会因 NO-IR 起不来）"
[ "$(stat -c %s "$RDP" 2>/dev/null)" = "1085" ] \
  && [ "$(md5sum "$RDP" 2>/dev/null | cut -d' ' -f1)" = "37d15dd7840f35213ce48f59250c8c6a" ] \
  && ok "regulatory.db.p7s 签名在位（内核验证 regdb 必需）" \
  || bad "regulatory.db.p7s 缺失/损坏（regdb 会被判 invalid）"
[ -x files/etc/init.d/wifi-regdom ] \
  && grep -q 'iw reg set CN' files/etc/init.d/wifi-regdom \
  && ok "wifi-regdom 开机脚本在位（regdomain CN 兜底）" \
  || bad "缺 wifi-regdom 开机脚本（regdomain 可能停在世界域）"
grep -q 'config_foreach _normalize_24g_radio wifi-device' files/etc/init.d/wifi-regdom \
  && grep -q 'wireless.$sec.channel=6' files/etc/init.d/wifi-regdom \
  && grep -q 'wireless.$sec.htmode=HT20' files/etc/init.d/wifi-regdom \
  && ok "wifi-regdom 含 2.4G 非法信道/带宽兜底" \
  || bad "wifi-regdom 缺 2.4G 非法配置兜底（保留旧配置时可能无 2.4G 信号）"
sh -n files/etc/init.d/wifi-regdom 2>/dev/null \
  && ok "wifi-regdom 语法检查通过" || bad "wifi-regdom 语法错误"

# ---------------------------------------------------------------
sec "8. 源码树注入深度校验（可选，WRT=源码树时执行）"
if [ -n "${WRT:-}" ] && [ -d "$WRT/target/linux/rtl9617c" ]; then
  test -f "$WRT/target/linux/rtl9617c/dts/rtl9617c-pt1570-r10.dts" \
    && ok "WRT 已注入 R10 DTS" || bad "WRT 缺 R10 DTS"
  grep -q "SUPPORTED_DEVICES += youhua,pt1570-r10" \
       "$WRT/target/linux/rtl9617c/image/Makefile" \
    && ok "image/Makefile 已注入机型" || bad "image/Makefile 未注入机型"
  n_wrt_board=$(grep -cE '^[[:space:]]*youhua,pt1570-r10\)$' \
       "$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh" || true)
  [ "$n_wrt_board" -eq 2 ] \
    && ok "sysupgrade 白名单已注入（check + upgrade 两处合法 case）" \
    || bad "platform.sh 合法 R10 case 分支 $n_wrt_board 处（应为 2）"
  ! grep -qE '^[[:space:]]*youhua,pt1570-r10[[:space:]]*\|' \
       "$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh" \
    && ok "platform.sh 无伪 case 分支" \
    || bad "platform.sh 仍有 youhua,pt1570-r10 | 伪分支（Web 升级会失败）"
  grep -q 'fit_do_upgrade "$1"' \
       "$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh" \
    && ok "platform.sh 已升级为 fit_do_upgrade 流程" \
    || bad "platform.sh 仍是旧 nand_do_upgrade 流程（系统内升级会静默失败）"
  # 2026-11-25 纯 refactor：上游 platform.sh 已改成
  #   RAMFS_COPY_BIN='fitblk fit_check_sign'
  # 不再有旧基线的 "fw_setenv fitblk"。两种写法都认，避免把正常的上游
  # 升级流程误判成失败（run #26 之后的下一处误报）。
  if grep -qE "RAMFS_COPY_BIN=.*fitblk" \
        "$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh" \
     || grep -q "fw_setenv fitblk" \
        "$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh"; then
    ok "RAMFS_COPY_BIN 已带 fitblk"
  else
    bad "RAMFS_COPY_BIN 缺 fitblk（sysupgrade 阶段 /dev/fit0 建不出来）"
  fi
  grep -q '^CONFIG_UIMAGE_FIT_BLK=y$' "$WRT/target/linux/rtl9617c/config-6.18" \
    && ok "UIMAGE_FIT_BLK=y" || bad "缺 UIMAGE_FIT_BLK（root=/dev/fit0 挂不上）"
  grep -q '^CONFIG_MTD_ROOTFS_ROOT_DEV=y$' "$WRT/target/linux/generic/config-6.18" \
    && ok "MTD_ROOTFS_ROOT_DEV=y" || bad "缺 MTD_ROOTFS_ROOT_DEV"
else
  echo "  SKIP 未指定 WRT（CI 中 workflow 会校验同样内容）"
fi

# ---------------------------------------------------------------
sec "8. 真机回归修复（2026-11-26：EEE 关断 + 2.4G 默认值）"
grep -q 'PT1570-R10: EEE/LPI disabled' scripts/patch-upstream.sh \
  && grep -q 'NI_EEE_DISABLED=True' scripts/patch-upstream.sh \
  && grep -q 'lpi_capabilities' scripts/patch-upstream.sh \
  && ok "patch-upstream.sh 从 MAC 能力层关闭 EEE/LPI（四口 Link flap）" \
  || bad "patch-upstream.sh 缺 EEE 关断（四口会继续 Link Down/Up）"
grep -q 'NI_EEE_DISABLED=True' scripts/patch-upstream.sh \
  && ok "patch-upstream.sh 有 EEE 关断自检断言" \
  || bad "patch-upstream.sh 缺 EEE 关断自检"
sh -n files/etc/init.d/wifi-regdom 2>/dev/null \
  && ok "wifi-regdom 语法检查通过" || bad "wifi-regdom 语法错误"
grep -q '2.4G channel .*-> 6' files/etc/init.d/wifi-regdom \
  && grep -q 'htmode=.*HT20' files/etc/init.d/wifi-regdom \
  && ok "wifi-regdom 含 2.4G channel=6 / htmode=HT20 默认值兜底" \
  || bad "wifi-regdom 缺 2.4G 默认值兜底"

# ---------------------------------------------------------------
echo
if [ "$FAILS" -eq 0 ]; then
  echo "PREFLIGHT_OK=True"
  exit 0
else
  # 只看日志末尾（CI 里被折叠/截断的地方）看不到具体哪条失败，
  # 所以在最后再汇总一遍，并用 ::error:: 让 GitHub 渲染成页面顶部注解。
  echo "---- 失败项汇总（共 $FAILS 条） ----"
  for m in "${FAILED_MSGS[@]}"; do
    echo "  FAIL $m"
    echo "::error::preflight: $m"
  done
  echo "PREFLIGHT_OK=False fails=$FAILS"
  exit 1
fi

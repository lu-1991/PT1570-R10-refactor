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
         scripts/apply-board.sh scripts/overlay-wifi-driver.sh \
         scripts/patch-upstream.sh scripts/verify-rf-tables.py \
         scripts/verify-fit-boot.py \
         board/dts/rtl9617c-pt1570-r10.dts board/devices/pt1570-r10.mk.inc \
         files/etc/uci-defaults/96-pt1570-r10-leds \
         files/etc/uci-defaults/97-pt1570-r10-wifi24 \
         files/etc/uci-defaults/98-pt1570-r10-wifi-stability \
         files/etc/uci-defaults/99-pt1570-fit \
         files/etc/modules.d/50-rtl-ax-ap \
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
       and p.suffix.lower() != '.bin'
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
sec "3. 射频表完整性（ITB 全量 ≥70 张表）"
T=files/lib/firmware/realtek/tyfza1
n=$(find "$T" -name '*.txt' | wc -l)
[ "$n" -ge 70 ] && ok "射频表 $n 张（≥70）" || bad "射频表 $n < 70"
nb=$(find "$T" -name '*.bin' | wc -l)
[ "$nb" -ge 7 ] && ok "WiFi 固件 bin ≥ 7 ($nb)" || bad "bin 仅 $nb"
python3 scripts/verify-rf-tables.py "$T" >/dev/null \
  && ok "驱动解析器逐字段模拟通过" || bad "有射频表解析不过"

# TSSI 温补表：路径与大小必须和驱动 request_firmware 的期望一致
# （xb-tssi.h: rtl8192xbe/tssi-thermal-2g.bin = curves[2][2][30] = 120B；
#   c-tssi.h:  rtl8852ce/tssi-thermal-5g.bin  = curves[3][2][2][30] = 360B）。
# 2026-11-16 踩坑：2g 表被放进 rtl8852ce/ 且 336B —— 驱动请求的是 rtl8192xbe/
# 路径，大小不符也会被 "size != , ignored" 丢弃，等于白带。
t2="$T/rtl8192xbe/tssi-thermal-2g.bin"
t5="$T/rtl8852ce/tssi-thermal-5g.bin"
[ -f "$t2" ] && [ "$(wc -c < "$t2")" = 120 ] \
  && ok "2.4G TSSI 表 120B（rtl8192xbe/，与驱动期望一致）" \
  || bad "2.4G TSSI 表缺失或大小 != 120B（$t2）"
[ -f "$t5" ] && [ "$(wc -c < "$t5")" = 360 ] \
  && ok "5G TSSI 表 360B（rtl8852ce/）" \
  || bad "5G TSSI 表缺失或大小 != 360B（$t5）"
# 2.4G 目录下不允许出现 5g 命名、5G 目录下不允许出现 2g 命名（防再次放错）
[ ! -f "$T/rtl8852ce/tssi-thermal-2g.bin" ] && [ ! -f "$T/rtl8192xbe/tssi-thermal-5g.bin" ] \
  && ok "TSSI 表未串位（2g 在 rtl8192xbe / 5g 在 rtl8852ce）" \
  || bad "TSSI 表放错目录（2g 只能 rtl8192xbe，5g 只能 rtl8852ce）"

# ---------------------------------------------------------------
sec "4. 机型配置关键符号"
CFG=configs/youhua_pt1570-r10.config
for sym in CONFIG_TARGET_rtl9617c=y CONFIG_PACKAGE_fitblk=y \
           CONFIG_PACKAGE_tyfza1-pon-control=y CONFIG_PACKAGE_luci-ssl=y \
           CONFIG_PACKAGE_uhttpd=y CONFIG_PACKAGE_luci=y \
           CONFIG_PACKAGE_wpad-mbedtls=y CONFIG_LUCI_LANG_zh_Hans=y; do
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

# 主题与软件包口径：argon 主题（用户配置），不含 Fluent/tailscale/samba/upnp/wol
grep -q '^CONFIG_PACKAGE_luci-theme-argon=y$' "$CFG" \
  && ok "luci-theme-argon=y（用户配置口径：默认主题 argon）" \
  || bad "$CFG 缺 luci-theme-argon"
! grep -q '^CONFIG_PACKAGE_luci-theme-fluent=y$' "$CFG" \
  && ok "未启用 Fluent（按用户要求移除）" \
  || bad "$CFG 仍启用 luci-theme-fluent（应移除）"
! grep -qE '^CONFIG_PACKAGE_(tailscale|luci-app-samba4|vsftpd|luci-app-upnp|luci-app-wol)=y$' "$CFG" \
  && ok "未含 tailscale/samba/vsftpd/upnp/wol（用户配置口径）" \
  || bad "$CFG 含未约定的服务包（tailscale/samba/vsftpd/upnp/wol）"
# 双频 WiFi / USB / LuCI 中文核心包断言（本仓库配置口径）
for sym in CONFIG_PACKAGE_kmod-rtl-ax-ap=y CONFIG_PACKAGE_wpad-mbedtls=y \
           CONFIG_PACKAGE_kmod-usb-storage=y CONFIG_PACKAGE_ucode-mod-math=y \
           CONFIG_PACKAGE_luci-i18n-base-zh-cn=y; do
  grep -q "^${sym}$" "$CFG" && ok "$sym" || bad "$CFG 缺 $sym"
done
# 默认主题：argon 由厂商 97-rtl9617c-argon-default 设定；本仓库不应有 fluent 抢主题脚本
[ ! -f files/etc/uci-defaults/98-pt1570-fluent-default ] \
  && ok "无 Fluent 默认主题脚本（argon 由厂商脚本设定）" \
  || bad "存在 98-pt1570-fluent-default，会抢走默认主题"
# 静态主题文件（htdocs 等）不许出现在 files/
! find files \( -iname '*vantage*' -o -iname '*fluent*' -o -iname '*argon*' \) \
    ! -path '*/etc/uci-defaults/*' -print -quit 2>/dev/null | grep -q . \
  && ok "files/ 无静态主题残留" || bad "files/ 残留主题注入文件（应删除）"

# ---------------------------------------------------------------
sec "5. workflow 结构与防回归"
if [ -z "$WF" ]; then
  bad "没有 workflow 文件可检查"
else
grep -q 'configs/youhua_pt1570-r10.config' "$WF" \
  && ok "引用机型配置" || bad "未引用机型配置"
grep -q 'diy-part1.sh' "$WF" && grep -q 'diy-part2.sh' "$WF" \
  && ok "diy 两段式已接入" || bad "workflow 未调用 diy 脚本"
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

  # 双基线护栏（用户指定）：基线必须是 refactor，且必须保留 20b4cf4 硬件层叠加。
  # 回归点：只 clone refactor 不叠加 -> 缺 WiFi/USB/LED/4GE 驱动，编出的固件残废；
  #         改回纯 20b4cf4 -> 违背用户"用 refactor"的要求。
  grep -qE "default: 'ae4aeac45a70be1bdf68af65cbbacb360f201b27'" "$WF" \
    && ok "克隆基线为 refactor @ ae4aeac（用户指定）" \
    || bad "克隆基线不是 refactor @ ae4aeac"
  grep -q "HARDWARE_REF: '20b4cf4490ca55cc406d07e391691efa8cd8a087'" "$WF" \
    && grep -q 'rm -rf target/linux/rtl9617c' "$WF" \
    && grep -q 'git checkout -q "$HW_REF" -- target/linux/rtl9617c' "$WF" \
    && grep -q 'git checkout -q "$HW_REF" -- \\' "$WF" \
    && ok "保留 20b4cf4 硬件层叠加（target 整树 + 包）" \
    || bad "缺 20b4cf4 硬件层叠加，refactor 单独编不出完整固件"
  grep -q 'SOURCE_HASH=${BASE_HASH}-${HW_HASH}' "$WF" \
    && ok "缓存 key 同时绑定基线与硬件层" \
    || bad "缓存 key 未绑定双基线，换线后可能拿旧缓存编新组合"
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
sec "6. WiFi 驱动 overlay 资产完整性"
DRV=board/wifi/rtl_ax_ap
if [ -d "$DRV" ]; then
  got=$(md5sum "$DRV/pe-tx-code.h" 2>/dev/null | cut -d' ' -f1)
  [ "$got" = "7eb49893f43b897bf03fa82ae2323984" ] \
    && ok "pe-tx-code.h = 参考 PE 版本" || bad "pe-tx-code.h md5 不符（$got）"
  grep -q 'PT1570-RF-TABLE-QUIRK' "$DRV/limits.c" \
    && ok "limits.c 含 PShape 空列兼容" || bad "limits.c 缺 PShape 兼容"
  grep -q 'state->input_ready = false;' "$DRV/c-tssi.h" \
    && grep -q 'state->input_ready = false;' "$DRV/xb-tssi.h" \
    && ok "TSSI 缺表降级分支在位" || bad "TSSI 降级分支缺失（缺表会导致 probe 失败）"
  ! grep -q 'pe-core\.o' "$DRV/Makefile" \
    && ok "Makefile 无 pe-core.o 残留" || bad "Makefile 仍引用 pe-core.o"
else
  bad "缺 $DRV（overlay 无从谈起）"
fi

# ---------------------------------------------------------------
sec "7. factory 校准 284 字节（WiFi -EINVAL 的根因修复）"
INIT=files/etc/init.d/tyfza1-factory
grep -q '284' "$INIT" \
  && ok "init 脚本含 284 字节提取" || bad "init 脚本无 284 断言"
! grep -qE 'bs=4096|count=[0-9]{2,}' "$INIT" \
  || { grep -qE 'count=1 ' "$INIT" && ok "整块提取方式正确" \
       || bad "init 脚本提取方式异常（4096 直写会 -EINVAL）"; }
grep -q '4096' scripts/patch-upstream.sh && {
  grep -qE '4096.*(284|= *284|-> 284)|284.*4096' scripts/patch-upstream.sh \
    && ok "patch-upstream 将包内 4096 改 284" || bad "patch-upstream 无 284 修补逻辑"
} || ok "patch-upstream 不含 4096（无需修补）"

# ---------------------------------------------------------------
sec "7b. R10 端口命名与面板灯（2026-11-14 真机逐口验证的接线修正）"
grep -q 'of_machine_is_compatible("youhua,pt1570-r10")' scripts/patch-upstream.sh \
  && grep -q 'index = 4 - port' scripts/patch-upstream.sh \
  && ok "xram R10 命名修补在位（lan1..lan4=面板 LAN1..LAN4）" \
  || bad "patch-upstream 缺 xram R10 命名修补"
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
sec "7d. 系统内升级修复（上游 8c91b228b4：release fitblk before sysupgrade）"
# 2026-11-16 朋友真机实证：旧流程 nand_do_upgrade 硬编码写 UBI 卷，但运行中的
# rootfs 正挂在该卷的 fitblk 上，卷被占用 -> "系统里升级成功、重启无变化"。
# 修复 = platform_do_upgrade 改 fit_do_upgrade + RAMFS 复制 fitblk 工具。
grep -q 'fit_do_upgrade "$1"' scripts/apply-board.sh \
  && grep -q "fw_setenv fitblk" scripts/apply-board.sh \
  && ok "apply-board.sh 注入 fit_do_upgrade 升级流程（含 ramfs fitblk）" \
  || bad "apply-board.sh 缺 fit_do_upgrade 升级流程注入"
# 旧流程是否清除由 apply-board.sh 的收尾断言兜底（platform.sh 缺 fit_do_upgrade 直接失败）
grep -q '4xGE, UBI' board/dts/rtl9617c-pt1570-r10.dts \
  && ok "概览标记 UBI（区别于旧固件 FIT ABI，看型号即知升级是否生效）" \
  || bad "DTS model 缺 UBI 概览标记"
# 2026-11-16 真机实证：sysupgrade 会 source /lib/upgrade/*.sh 全部脚本，
# pt1500-fip.sh 字母序在 platform.sh 之后，会把 platform_check_image /
# platform_do_upgrade 覆盖成 H10 的 fip 逻辑 -> 网页升级第一句就报
# "this image is for youhua,pt1500-h10"。必须按机型 case 守护。
grep -q 'PT1570_R10_UPGRADE_HOOK_GUARD' scripts/apply-board.sh \
  && ok "apply-board.sh 注入 pt1500-fip.sh 机型守护（挡 H10 钩子覆盖）" \
  || bad "apply-board.sh 缺 pt1500-fip.sh 机型守护注入"

# ---------------------------------------------------------------
sec "7e. WiFi 校准文件链路（2026-11-18：缺 symlink = probe -ENOENT 无线全灭）"
# 驱动 board-cal.h request_firmware 读 /lib/firmware/.../flash-calibration.bin，
# 真文件由 tyfza1-factory(START=09) 开机生成在 /tmp，rootfs 里必须是符号链接
# （原厂 rootfs 如此；GitHub 网页上传把 symlink 弄丢了才引入这个坑）。
for chip in rtl8192xbe rtl8852ce; do
  LNK="files/lib/firmware/realtek/tyfza1/$chip/flash-calibration.bin"
  MODE=$(git ls-files -s -- "$LNK" 2>/dev/null | awk '{print $1}')
  [ "$MODE" = "120000" ] \
    && ok "$LNK 是符号链接（git mode 120000）" \
    || bad "$LNK 不是符号链接（git mode=${MODE:-无}，驱动 probe 会失败）"
  FB="files/lib/firmware/realtek/tyfza1/$chip/flash-calibration.factory-fallback.bin"
  if [ "$(stat -c %s "$FB" 2>/dev/null)" = "284" ] \
     && [ "$(head -c 8 "$FB")" = "TYFC0003" ]; then
    ok "fallback blob 284B TYFC0003 ($chip，源自 mtd3 NV_CFG 备份)"
  else
    bad "$FB 不是 284B TYFC0003"
  fi
done
grep -q 'factory_fallback ' files/etc/init.d/tyfza1-factory \
  && grep -q 'flash-calibration.factory-fallback.bin' files/etc/init.d/tyfza1-factory \
  && ok "tyfza1-factory 兜底逻辑在位（factory 卷空时不至于无线全灭）" \
  || bad "tyfza1-factory 缺 factory_fallback 兜底逻辑"
sh -n files/etc/init.d/tyfza1-factory \
  && ok "tyfza1-factory 语法检查通过" || bad "tyfza1-factory 语法错误"

# ---------------------------------------------------------------
sec "7f. ITB 无线方案资产（2026-11-19 从 new-fit-4ge-20261119.itb 移植）"
# 新增的两套射频参数目录必须齐全（2.4G RFE50+PON_2G / 5G YH9570）。
for d in \
  files/lib/firmware/realtek/tyfza1/rtl8192xbe/RFE50 \
  files/lib/firmware/realtek/tyfza1/rtl8192xbe/RFE50/PON_2G \
  files/lib/firmware/realtek/tyfza1/rtl8852ce/RFE54/RTK66587_BPF_YH9570; do
  [ -d "$d" ] && ok "$(basename "$d")/ 射频目录在位" || bad "缺 $d（ITB 无线方案不完整）"
done
# 5G 平台校准 284B 必须是 ITB 原值（TYFC0003 头，修正部分机器 5G 无发射）。
FBC=files/lib/firmware/realtek/tyfza1/rtl8852ce/flash-calibration.factory-fallback.bin
[ "$(stat -c %s "$FBC" 2>/dev/null)" = "284" ] \
  && [ "$(head -c 8 "$FBC")" = "TYFC0003" ] \
  && ok "5G fallback 为 ITB 284B TYFC0003 平台校准" \
  || bad "5G fallback 非 284B TYFC0003"
# 模块加载 + 首启 SSID 配置必须在位，且不引入默认 WAN。
grep -q '^rtl_ax_ap$' files/etc/modules.d/50-rtl-ax-ap \
  && ok "rtl_ax_ap 模块自动加载在位" || bad "50-rtl-ax-ap 未加载 rtl_ax_ap"
grep -q 'PT1570-R10-5G-' files/etc/uci-defaults/92-pt1570-r10-wifi-default \
  && grep -q 'PT1570-R10-' files/etc/uci-defaults/92-pt1570-r10-wifi-default \
  && ok "首启双频 SSID 由 LAN MAC 生成" || bad "92-wifi-default 缺 SSID 派生逻辑"
for s in 92-pt1570-r10-wifi-default 92-pt1570-r10-wireless-country \
         97-pt1570-r10-wifi24 98-pt1570-r10-wifi-stability; do
  ! grep -qE 'pon0\.|pppoe|PPPoE|interface .*wan' "files/etc/uci-defaults/$s" \
    && ok "$s 无默认 WAN 注入" || bad "$s 混入了默认 WAN 配置"
done

# ---------------------------------------------------------------
sec "8. 源码树注入深度校验（可选，WRT=源码树时执行）"
if [ -n "${WRT:-}" ] && [ -d "$WRT/target/linux/rtl9617c" ]; then
  test -f "$WRT/target/linux/rtl9617c/dts/rtl9617c-pt1570-r10.dts" \
    && ok "WRT 已注入 R10 DTS" || bad "WRT 缺 R10 DTS"
  grep -q "SUPPORTED_DEVICES += youhua,pt1570-r10" \
       "$WRT/target/linux/rtl9617c/image/Makefile" \
    && ok "image/Makefile 已注入机型" || bad "image/Makefile 未注入机型"
  grep -q "youhua,pt1570-r10" \
       "$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh" \
    && ok "sysupgrade 白名单已注入" || bad "platform.sh 未注入机型"
  grep -q 'fit_do_upgrade "$1"' \
       "$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh" \
    && ok "platform.sh 已升级为 fit_do_upgrade 流程" \
    || bad "platform.sh 仍是旧 nand_do_upgrade 流程（系统内升级会静默失败）"
  grep -q "fw_setenv fitblk" \
       "$WRT/target/linux/rtl9617c/base-files/lib/upgrade/platform.sh" \
    && ok "RAMFS_COPY_BIN 已带 fitblk" || bad "RAMFS_COPY_BIN 缺 fitblk"
  grep -q '^CONFIG_UIMAGE_FIT_BLK=y$' "$WRT/target/linux/rtl9617c/config-6.18" \
    && ok "UIMAGE_FIT_BLK=y" || bad "缺 UIMAGE_FIT_BLK（root=/dev/fit0 挂不上）"
  grep -q '^CONFIG_MTD_ROOTFS_ROOT_DEV=y$' "$WRT/target/linux/generic/config-6.18" \
    && ok "MTD_ROOTFS_ROOT_DEV=y" || bad "缺 MTD_ROOTFS_ROOT_DEV"
else
  echo "  SKIP 未指定 WRT（CI 中 workflow 会校验同样内容）"
fi

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

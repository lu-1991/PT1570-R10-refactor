# PT1570-R10-CI

友华 **PT1570-R10**（Realtek **RTL9617C**）的 OpenWrt FIT 固件云编译仓库。

> **本仓库配置口径**：按用户要求，结构和编译方式沿用已真机验证的 `PT1570-R10-CI`
> 方案（两段式 diy / board+files+scripts 注入层 / 完整校验 / 缓存 / 滚动 Release），
> 软件包集合则保持核心功能口径：**PON 拨号 + 4×GE + 双频 WiFi + LuCI 中文 +
> USB/存储 + LED/按键 + UTC+8，argon 主题**；不含 tailscale / samba / vsftpd /
> upnp / wol / Fluent。需要这些服务时按第 5.2 节说明在 config 里追加即可。

采用 P3TERX `Actions-OpenWrt` 的"定制层"思路：**本仓库不存 OpenWrt 源码**，只放板级
支持、驱动 overlay、rootfs 默认值和防回归断言；GitHub Actions 在 runner 上克隆上游源码、
注入定制、编译、校验产物，最后发布到 Release。

- 上游基座：`lyq1996/rtl9617c-openwrt`，默认锁定已真机核实的 commit `20b4cf4`
  （= 分支 `feature/pt1500-h10-openwrt-fixes` 的 HEAD，2026-11-07，
   `pon: apply EPON queues per queue like stock`；写完整 40 位 SHA 才能字节级复现）
- 产物形态：**FIT ABI + squashfs + UBI**，`root=/dev/fit0`（固件自洽，不依赖 bootloader 注入）
- 验证状态：**PT1570-R10 已真机验证**（启动 / 4×GE / 双频无线 / PPPoE 拨号 / 面板灯）
  - 注：固件**不带默认 WAN**（pon0.1101 / PPPoE / PON FE 已全部去掉），首次开机需自行配置上网；上述 PPPoE 拨号指真机验证过该能力，非出厂预设。

---

## 1. 硬件规格

| 项目 | 规格 |
|---|---|
| SoC | Realtek RTL9617C，4×ARM Cortex-A55，target `rtl9617c/generic`（`aarch64_cortex-a55`） |
| 有线 | 4×GE（内部 GPHY 4 颗），面板标 LAN1–LAN4 |
| 上行 | PON（`tyfza1-pon-control` 驱动；**无默认 WAN**，自行配置 VLAN/协议） |
| 5G | RTL8852CE（PCIe0 → `phy0`），协议/信道由驱动能力推导（HE80 / auto），见 §6 |
| 2.4G | RTL8192XBE（PCIe1 → `phy1`），协议/信道由驱动能力推导（HE20 / auto），见 §6 |
| 存储 | SPI NAND + UBI 5 分区；rootfs 以 FIT 子镜像形式挂在 `/dev/fit0` |
| 按键 | reset(gpio8)、rfkill(gpio99)、lights-toggle(gpio103) |
| 灯 | 12 颗（internet / los / pon / phone / usb0 / usb1 / power / wps / lan0–3） |
| factory 卷 | `0x1000` MAC、`0x2000` 5G 校准、`0x3000` 2.4G 校准、`0x4000` BOSA、`0x5000` PON A2H |

> 面板接线（真机逐口插线确认）：芯片 NI `port0..3` **反序**对应面板 `LAN4..LAN1`。
> 驱动命名已由 patch 修正为 `lan1..lan4` 对号入座，面板灯由 `96-pt1570-r10-leds` 纠正。

---

## 2. 快速开始

1. **Fork / 新建仓库**，把本目录内容全部上传（`.github`、`board`、`configs`、`files`、`scripts`、
   `diy-part1.sh`、`diy-part2.sh` 必须在仓库根目录）。
   > 换行符不用管：workflow 开头有一道 CRLF→LF 归一化（覆盖 `*.sh` / `*.py` / `*.c` / `*.h` /
   > `*.uc` / `*.dts` / `files/etc/**`），仓库里再放一个 `.gitattributes` 只是给本地 git 加保险。
   > ⚠️ 网页上传（拖文件夹）会静默丢掉点开头的文件，`.gitattributes` / `.gitignore` 常常传不上去；
   > 要补的话用 **Add file → Create new file**，文件名直接输 `.gitattributes` 即可。
2. 打开 **Actions → Build PT1570-R10 (rtl9617c FIT) → Run workflow**：

   | 输入 | 默认 | 说明 |
   |---|---|---|
   | `source_ref` | `20b4cf4…` | 上游 commit / 分支。默认 = `feature/pt1500-h10-openwrt-fixes` @ `20b4cf4`（2026-11-07 真机核实基线）；**不要改成 `main` / `refactor`**，那是另外的代码线（详见 §11「上游基座」） |
   | `target_model` | `youhua_pt1570_r10` | **选谁编谁**，只产出所选机型的固件 |
   | `upload_release` | `true` | 发布到固定 tag 的滚动 Release |
   | `prune_release` | `true` | 发布后删除该 Release 里不属于本次产物的旧附件（只留最新一套，见 §5.4） |
   | `build_initramfs` | `false` | 是否额外构建 initramfs 恢复镜像（+约 8 分钟，仅救砖用） |

3. 编译约 **1 小时**（命中 dl 缓存会明显更快）。产物在两处：
   - **Release**：`pt1570-r10`（或按机型的 tag）下直接下载 `.itb`
   - **Artifacts**：`pt1570-fit-<model>`（全套，含 sha256sums）、`sysupgrade-itb-<model>`（只有刷机那一个）

### 支持的机型

| `target_model` | 机型 | Release tag | 状态 |
|---|---|---|---|
| `youhua_pt1570_r10` | 友华 PT1570-R10 | `pt1570-r10` | ✅ 本仓库真机验证 |
| `tianyi_tyfza1_2p5g` | 天邑 TYFZA1 2.5G | `tyfza1-2p5g` | ⚠️ 上游机型，未验证 |
| `tianyi_tyfza1_4ge` | 天邑 TYFZA1 4GE | `tyfza1-4ge` | ⚠️ 上游机型，未验证 |
| `youhua_pt1500_h10_2p5g` | 友华 PT1500-H10 2.5G | `pt1500-h10-2p5g` | ⚠️ 上游机型，未验证 |

非 R10 机型不会带本仓库的面板灯纠正等 R10 专属逻辑 —— 这些只在 R10 上验证过，
硬套会不适用，所以 `diy-part2.sh` 会主动删掉。默认 WAN 已彻底去掉，所有机型均不带。

---

## 3. 刷机

**用 `*-squashfs-sysupgrade-<时间戳>.itb`，不要用 `initramfs-recovery`**（后者跑在内存里，
重启即失、配置不保存，只适合救砖/试启动）。

```sh
# 路由器上（或 LuCI → 系统 → 备份/刷写固件）
sysupgrade -n /tmp/openwrt-...-youhua_pt1570_r10-squashfs-sysupgrade-20261114-1530.itb
```

> ⚠️ **务必 `-n` / 勾选"不保留配置"**。本仓库改的是**配置生成器**（`mac80211.uc`），
> 保留旧配置时 `/etc/config/wireless` 不会重新生成，等于没改。

文件名里的时间戳用 Windows 安全格式（`YYYYMMDD-HHMM`，无冒号/括号），下载解压不会出错；
可读时间（`YYYY-MM-DD HH:MM:SS`）写在 Release 说明里。

---

## 4. 刷完的出厂默认值

| 项目 | 默认值 |
|---|---|
| 管理地址 | `192.168.1.1`（root 无密码，首登请自行设置） |
| 主机名 | 跟随机型，如 `PT1570-R10` |
| 时区 | `Asia/Shanghai`，NTP 用国内源（aliyun / tencent / ntsc / cn.pool） |
| WAN | **无默认 WAN**（`pon0.1101`/PPPoE/PON FE 已全部去掉），首次开机需自行配置上网 |
| 5G | SSID `PT1570-R10-5G`，**开放（无密码）**，htmode/信道交还驱动推导（预期 HE80 / auto） |
| 2.4G | SSID `PT1570-R10-2.4G`，**开放（无密码）**，htmode/信道交还驱动推导（预期 HE20 / auto） |
| 面板灯 | 跟随真实网口（EPHY0..3 → LAN4..LAN1） |

所有默认值都是"仅在仍是出厂默认时才改"，用户动过的项不会被覆盖。
**想改回加密**：LuCI → 网络 → 无线 → 修改 → 加密选 WPA2-PSK 并设密码即可，不需要重新编译。

> **关于"无默认 WAN"**：本固件出厂不带任何 WAN 配置。PON 驱动（`tyfza1-pon-control`）
> 仍在，光模块/LAN/WiFi 正常工作，但 `pon0` 的 VLAN 子接口、PPPoE 协议、PON 转发引擎
> （`offload`）都不再自动设置。首次开机后请到 **网络 → 接口** 自行新建 WAN：
> 设备填 `pon0.<你的VLAN>`（Point-to-Point 协议选 PPPoE 并填账号密码），PON 页按运营商
> 填 LOID/SN。之前版本会自动写成 `pon0.1101` + PPPoE + `offload=1`，
> 现已从两处移除：本机 `files/etc/uci-defaults/95-pt1570-wan-default`（已删除），
> 以及上游 `target/.../uci-defaults/90-tyfza1-pon-wan`（由 `apply-board.sh` 在编译时删除，
> 避免首次开机又冒出一个 `pon0.3961` 的默认 PPPoE WAN）。`preflight.sh` 会校验这两点。

---

## 5. 编译流水线（32 步）

```
checkout → CRLF 归一化 → 释放磁盘/装依赖 → 克隆上游(锁 commit)
   → 恢复 4 层缓存（dl / toolchain / ccache / feeds）
   → feeds update/install → diy-part1（板级+驱动+上游修补）
   → 注入 files/（补 +x）→ 加载 .config → diy-part2（定制+两次 defconfig+硬断言）
   → 射频表逐字段校验 → preflight 静态自检 → make download → 编译
   → 存 dl / toolchain / ccache 缓存 → 镜像 payload 逐文件比对 → FIT 可启动性校验
   → 整理产物 → 打时间戳 → 上传 artifact → 生成/更新 Release
   → 记录本次产物清单 → 上传固件 → 清理 Release 里的旧附件
```

### 5.1 initramfs 恢复镜像默认不编

`CONFIG_TARGET_ROOTFS_INITRAMFS` 会让内核**再编一遍**（内嵌 rootfs 的变体），实测多花约 8 分钟。
现在默认关闭，只出 `sysupgrade.itb`；需要救砖镜像时在 Run workflow 里勾 **`build_initramfs`**。

刷入态出问题时仍有 U-Boot Web Failsafe 可以救，所以日常迭代没必要背这 8 分钟。

### 5.2 其它关键设计

- **dl 缓存**：key 为"年+周"（`pt1570-r10-dl-<2026WW>`），同一周复用，跨周 restore-keys 兜底，
  避免 10GB 配额被 run_id 刷满。
- **并发**：编译用 `-j$(nproc+2)`（4 核 runner 上 `-j4` 常在链接阶段空等），下载用 `-j$(nproc*4)`。
- **失败可读**：`make -j` 失败自动回退 `make -j1 V=s`，仍失败则把最后 120 行与
  `error:` / `No space left` / `Killed` 等关键行抓成 GitHub 注解，并上传 `build.log`。
- **只有一条 workflow**：不再有 matrix、不再现场编译 PE 固件（那一步产出的正是已知坏版本，
  会被 overlay 直接覆盖）。
- **主题与软件包口径（按用户要求）**：本仓库只保留 PT1570-R10 核心功能 ——
  PON 拨号 + 4×GE + 双频 WiFi + LuCI 中文 + USB/存储 + LED/按键 + UTC+8。
  主题沿用 **argon**（`luci-theme-argon`，来自 kenzok8 feed + 上游 profile 强选），
  默认主题由厂商 pon 包的 `97-rtl9617c-argon-default` 设定，无需额外脚本。
  未拉 Fluent、未启用 tailscale / samba / vsftpd / upnp / wol —— 这些是定制项，
  需要时在 `configs/youhua_pt1570-r10.config` 里加 `CONFIG_PACKAGE_*` 即可
  （`diy-part2` 第 5/6 节会重新断言防丢包；加 Fluent 之类的外部主题还要在
  `diy-part2.sh [1d]` 恢复拉库步骤）。主题一律走包构建，不以静态文件注入 `files/`。

> ⚠️ GitHub 单仓库缓存配额 **10 GB**（LRU 淘汰）。四层缓存全量约 7–8 GB，正常够用。
> 如果发现 dl 缓存老是被挤掉，优先调小 `CCACHE_MAXSIZE`（workflow 顶部 env，默认 1200M）。

### 5.3 ccache 为什么要连 `CONFIG_DEVEL` 一起打开（踩过的坑）

上游 `config/Config-devel.in` 里 ccache 的定义是：

```
menuconfig DEVEL
	bool "Advanced configuration options (for developers)"

	config CCACHE
		bool "Use ccache" if DEVEL      # ← 注意 "if DEVEL"
```

`if DEVEL` 限制的是 **prompt 可见性**。`DEVEL=n` 时这个符号根本不会出现在配置里，
Kconfig 会忽略 `.config` 里手写的 `CONFIG_CCACHE=y`，`make defconfig` 直接
把它改写成 `# CONFIG_CCACHE is not set`。

2026-11-14 实测后果：`diy-part2.sh` 里那条"CCACHE 不能被 defconfig 丢弃"的断言失败，
job 在第 15 步、**25 秒**就退出（连编译都没开始）。所以 `diy-part2.sh` 现在成对写入：

```
CONFIG_DEVEL=y                      # 让开发者选项可见，本身不改产物
# CONFIG_AUTOREBUILD is not set     # DEVEL 会把它默认成 y，CI 里只会反复重编
CONFIG_CCACHE=y
```

另外 ccache 目录不是 `staging_dir/ccache`：`rules.mk` 里
`CCACHE_DIR = $(if $(CONFIG_CCACHE_DIR),…,$(TOPDIR)/.ccache)`，
`CONFIG_CCACHE_DIR` 为空时落在**源码根的 `.ccache`**。workflow 缓存的正是这个目录
（另外两处 `staging_dir/ccache`、`~/.ccache` 只是兜底）。

### 5.4 Release 只保留最新一次编译

Release 是**滚动**语义（tag 固定，如 `pt1570-r10`），但产物文件名带时间戳
（`…-squashfs-sysupgrade-20261114-1600.itb`）。`softprops/action-gh-release` 只覆盖**同名**附件，
所以每隔一次编译就会多留一套旧 itb —— 十几轮之后 Release 列表就没法看了。

现在发布后会多跑一步「清理旧附件」，按**本次产物清单**反删其余附件，最终只留下最新一套。

**顺序是「先传后删」**，不是"先删后传"：万一上传环节失败，旧产物还在，不会出现一个空 Release。

三道护栏，宁可不删也不误删：

| 护栏 | 触发条件 | 行为 |
|---|---|---|
| 清单为空 | `release-keep.txt` 不存在或为空 | 打 warning 跳过（否则 grep 失败会被当成"不匹配"而删光） |
| 零交集 | 附件里**没有任何一个**在清单中（`MATCH=0`） | 判定为解析异常，中止，一个都不删 |
| 单个失败 | `gh release delete-asset` 返回非 0 | 只打 warning 计数，不影响 job 结论 |

清理结果会写进该次 run 的 **Step Summary**（清理前附件数 / 保留数 / 删除数 / 失败数），
日志里也有一行 `PRUNE_OK tag=… before=… kept=… stale=… removed=… failed=…`。

想保留历史版本时，把 Run workflow 里的 **`prune_release`** 取消勾选即可（默认勾选）。
旧版本的另一个去处是 Actions 对应 run 的 **Artifacts**（保留 30 天）。

---

## 6. 无线默认值策略：对齐原厂，协议/信道交还驱动推导（重要）

`package/network/config/wifi-scripts/files/lib/wifi/mac80211.uc` 生成 `/etc/config/wireless`
时，`htmode` 取的是**该频段支持的最高协议**：

```ucode
const htmode_order = [ "EHT", "HE", "VHT", "HT" ];
let htmode = filter(htmode_order, (m) => band[lc(m)])[0];
```

2026-11-16 把原厂固件 rootfs 解包对比后确认：**原厂的 `mac80211.uc` 与上游逐行相同**，
原厂也不钉 htmode / 信道，全靠 `rtl_ax_ap` 驱动宣称的能力推导。这套驱动的频段能力是：

| 频段 | HT | VHT | HE | EHT | 推导终态 |
|---|---|---|---|---|---|
| 2.4G（8192XB） | ✅ | ❌ | ✅ | ❌ | **HE20**（width 强制 20） |
| 5G（8852C） | ✅ | ✅ | ✅ | ❌ | **HE80**（max_width 160 封顶 80） |

因此本仓库同样**不做任何钉死**：htmode、信道全部交还驱动推导（信道为 auto），
首启脚本只兜 country=CN、启用、不隐藏——与原厂行为一致。

**历史与风险提示（2026-11-14 的 HE 信标事件）**：当时真机上 2.4G 推导出 HE20，
出现"Windows 能搜到能连、Android 永远看不到 SSID"的现象（疑似 HE 信标兼容性），
为此曾把 2G 钉死 HT20。但该修复**从未刷机复验**，且原厂同样推导 HE20，故按用户
决定回退为推导模式。如果刷机后手机又搜不到 2.4G：

1. 先确认现象：`iw dev phy1-ap0 info` 看 `width`，`grep ieee80211ax /var/run/hostapd-phy1.conf`；
2. 临时对策：LuCI → 网络 → 无线 → 编辑 2.4G 接口 → htmode 手动改 **HT20** 保存即可，
   不需要重新编译；
3. 若确认是 HE 信标问题且想长期规避，再回仓库把生成器钉回 HT20。

> 顺带纠正一个常见误判：`iwinfo` 显示的 `HT Mode: HT40` **不代表真实带宽**，它读的是
> `ht_capab` 里的 `SHORT-GI-40` 标志位。真实带宽只看 `iw dev phyX-ap0 info` 的 `width`。

---

## 7. 目录结构

```
.
├── diy-part1.sh                    # feeds 之后、加载 .config 之前：往源码树"注入"
├── diy-part2.sh                    # 加载 .config 之后：默认值定制 + 两次 defconfig + 硬断言
├── configs/
│   └── youhua_pt1570-r10.config     # 机型无关的基础包集合（机型由 target_model 决定）
├── files/                           # 原样覆盖进 rootfs
│   ├── etc/init.d/tyfza1-factory            # factory 校准提取（必须精确 284 字节）
│   ├── etc/uci-defaults/96-pt1570-r10-leds     # 面板灯 → 真实网口
│   ├── etc/uci-defaults/97-pt1570-r10-wifi24   # 2.4G 首启兜底：country/启用/不隐藏（见 §6）
│   ├── etc/uci-defaults/98-pt1570-r10-wifi-stability  # 断流缓解：不踢空闲终端 + country（见 FAQ）
│   ├── etc/uci-defaults/99-pt1570-fit          # 时区/主机名/FIT 接线兜底
│   └── lib/firmware/realtek/tyfza1/            # WiFi AP 固件 8×bin + 42 张 RFE54 射频表
├── board/
│   ├── dts/rtl9617c-pt1570-r10.dts  # 板级 DTS（root=/dev/fit0 自洽启动、按键修正）
│   ├── devices/pt1570-r10.mk.inc    # image/Makefile 的 Device 定义片段
│   └── wifi/rtl_ax_ap/              # 已真机验证的驱动全套（PE IRAM revert 版）
├── scripts/
│   ├── apply-board.sh               # 注入 DTS + Device + sysupgrade 白名单
│   ├── overlay-wifi-driver.sh       # 整套替换驱动（含 pe-tx-code.h md5 强校验）
│   ├── patch-upstream.sh            # 上游修补：factory 284 / fitblk 上限 / R10 端口命名
│   ├── preflight.sh                 # 静态自检，编译前跑，任何 FAIL 立即终止
│   ├── verify-rf-tables.py          # 42 张表逐字段模拟驱动解析器
│   └── verify-fit-boot.py           # 产物 FIT 结构 + bootargs 可启动性校验
├── .github/workflows/
│   └── Build-PT1570-R10.yml         # 唯一 workflow（32 步）
├── .gitattributes                   # 全仓锁定 LF
└── .gitignore                       # 忽略编译产物 / 本地缓存
```

---

## 8. 刷完怎么验

```sh
dmesg | grep -E 'fit0|fitblk'     # 应见 "mapped 1 uImage.FIT filesystem sub-image as /dev/fit0"
dmesg | grep -i rtl_ax            # 应见 native AP backend ... WCPU ready（两路各一行）
mount | grep ' / '                # squashfs + overlay（不是 tmpfs）
iw dev                            # phy0-ap0 / phy1-ap0 均存在
iw dev phy1-ap0 info | head -8    # 2.4G：width 20 MHz
iwinfo phy1-ap0 info | grep -E 'ESSID|Encryption'   # PT1570-R10-2.4G / none
ip -br addr show br-lan           # 192.168.1.1
```

面板口顺序自查：插 LAN1 → `ip -br link` 里应是 `lan1` 起、且面板 LAN1 灯亮。

---

## 9. 常见问题

**Q：刷完固件后没有 SSID，`logread | grep rtl_ax_ap` 里 probe 失败？**
驱动 `rtl_ax_ap` 在启动时要读 `/lib/firmware/realtek/tyfza1/<芯片>/flash-calibration.bin`
（284 字节 TYFC0003 板级校准）。真文件是 `tyfza1-factory`（START=09）开机从 factory
UBI 卷生成到 `/tmp`，rootfs 里放的是**符号链接**（原厂如此）。早期这个仓库经
GitHub 网页上传（Add files via upload），**symlink 被静默丢掉**，驱动
`request_firmware` 直接 -ENOENT → 两颗 WiFi 芯片 probe 失败 → 无线全灭。
2026-11-18 起已恢复两条 symlink，并加了兜底：factory 卷对应区域为空时，
`tyfza1-factory` 会改用内置的 `flash-calibration.factory-fallback.bin`
（284B，从本机 mtd3 static_conf 的 NV_CFG 备份合成：thermal/晶振/TSSI/RX
gaingap 为真实值，扩展增益表为 0）+ 现场 MAC 填 `wlan_address`。
自查：`ls -la /lib/firmware/realtek/tyfza1/rtl8192xbe/` 应看到 `flash-calibration.bin -> /tmp/...`。

**Q：编译刚跑 20 多秒就失败，日志里只有 "Process completed with exit code 1"？**
`diy-part2.sh` 的每条断言都用 `::error::diy-part2: <原因>` 输出，GitHub 会把它渲染成
run 页面顶部的注解，不点进日志也能看到；`ERR trap` 还会兜住"没预想到会失败"的命令
（如 `make defconfig`），输出失败的命令原文。历史上最典型的一次是 §5.3 的
`CONFIG_CCACHE` 被 Kconfig 重置——只写 `CCACHE=y` 而不开 `DEVEL`，25 秒就退出。

**Q：日志末尾只有 `PREFLIGHT_OK=False fails=1`，找不到是哪条 FAIL？**
`scripts/preflight.sh` 现在会在最后打印“失败项汇总”，并对每条失败发 `::error::preflight: <原因>`，
GitHub 会把它渲染成 run 页面顶部注解。历史踩坑：网页上传丢了 `.gitattributes`，
而当时那条检查是硬 FAIL —— 现在改为「有它就必须写 `eol=lf`；没有它只 WARN，
前提是 workflow 里确实有 CRLF 归一化步骤」。

**Q：网页上传后 `.gitattributes` / `.gitignore` 不见了？**
浏览器拖文件夹上传会静默过滤点开头的文件。用 **Add file → Create new file**，
文件名直接输入 `.gitattributes`（可以带前导点）即可。这两个文件只影响本地 git 检出，
CI 里没有也能正常编译（workflow 会做 CRLF 归一化）。

**Q：Actions 编译成功，但 Release 里没有附件？**
`upload_release` 默认 `true`。另外历史踩坑：`github.event.inputs.*` 是**字符串**，
`'true' == true` 在表达式里恒为 false，曾导致 Release 步骤永远被跳过。现在用
`github.event.inputs.upload_release == 'true'` 显式比较，已修复。

**Q：Artifacts 里找不到单个 itb？**
文件名会被加上时间戳（`…-squashfs-sysupgrade-20261114-1530.itb`），所以 artifact 的路径写成
`*squashfs-sysupgrade*.itb`；下载后仍套一层 zip，解压即裸 itb。真正的单文件在 Release 附件里。

**Q：Release 里的旧固件怎么没了？**
这是设计行为（§5.4）：每次发布成功后都会删掉不属于本次产物的旧附件，只留最新一套，
避免带时间戳的 itb 堆积成几十个。想保留历史就取消勾选 `prune_release`；旧版本也可以从
对应 run 的 Artifacts 拿（保留 30 天）。清理只动**附件**，不动 Release 本身和 git tag。

**Q：清理会不会把刚传上去的也删了？**
不会。清理按"本次产物清单"反删，清单是发布前从固件目录实时枚举出来的；而且清单为空、
或与现有附件零交集时会直接跳过（见 §5.4 的护栏表）。

**Q：`tssi-thermal-2g.bin` 应该放哪、多大？**
驱动 `xb-tssi.h` 写死了路径与尺寸：`rtl8192xbe/tssi-thermal-2g.bin`，**恰好 120 字节**
（结构 `[2][2][30]` 有符号温度偏移）；5G 是 `rtl8852ce/tssi-thermal-5g.bin`，360 字节。
放错目录驱动读不到，大小不符会被 `size != N, ignored` 丢弃。原厂 rootfs 里的
2.4G 表本身就是全 0（原厂对 2.4G 不做温补），所以这张表是"对齐原厂行为"，
不是 2.4G 信号问题的修复项。preflight 第 3 节会校验路径、尺寸与串位。

**Q：Wi-Fi 时不时断流 / 终端被踢下线？**
首启脚本 `98-pt1570-r10-wifi-stability` 做两件事：
1. 所有 VAP `skip_inactivity_poll=1` + `disassoc_low_ack=0` —— 不再主动轮询和
   踢掉省电中的终端（最常见的"连着连着就掉"来源，终端自己会决定重连）；
2. 所有 radio 统一 `country=CN`（与原厂 92 号脚本一致）。
协议/信道不在本脚本处理（交还驱动推导，见 §6）。注意：uci-defaults 只在首启生效，
刷机若"保留配置"需要手动执行或恢复出厂。5G 用 auto 信道若出现"所有终端同时掉一下
再恢复"，是 DFS 雷达误报触发信道切换——把 5G 信道手动固定到 **149**（CN 合法、
非 DFS）即可。若做完仍断流，抓
`logread | grep -E 'hostapd|wifi-stability'` 和 `dmesg` 里 rtl_ax_ap 的报错再定位。

**Q：系统里（web）升级没有反应，重启后固件没变？**
旧固件的 platform.sh 用 `nand_do_upgrade` 硬编码往 UBI 卷写镜像，但运行中的
rootfs 正挂在这个卷的 fitblk/ubiblock 设备上——卷被占用，写入静默失败，
重启自然是旧固件（上游 8c91b228b4 "release fitblk before sysupgrade" 修复）。
2026-11-16 起 `apply-board.sh` 会把 platform.sh 升级为 `fit_do_upgrade` 流程
（先 `fitblk /dev/fit0` 释放块设备再写卷），并把 `fitblk` 工具复制进
sysupgrade 的 ramfs。**验证方法**：升级完成后看 LuCI 概览「型号」，新固件显示
`Youhua PT1570-R10 (RTL9617C, 4xGE, UBI)`；仍显示 `... FIT ABI` 就是没刷进去
（这个标记来自朋友 2026-11-16 的实证思路，也用于区分朋友版固件）。

**Q：网页升级直接报 `this image is for youhua,pt1500-h10, not youhua,pt1570-r10`？**
镜像本身没问题，是**升级钩子被 H10 的脚本抢走了**。`/sbin/sysupgrade` 启动时会
`source` 掉 `/lib/upgrade/*.sh` 全部脚本，其中 `pt1500-fip.sh`（H10 专用，按字母序
排在 `platform.sh` 之后）无条件定义 `platform_check_image` / `platform_do_upgrade` /
`platform_copy_config`，把本机型 `platform.sh` 里的版本整个覆盖掉：前者只认
`youhua,pt1500-h10`，所以第一句就判死；后者写 `fip` 卷，而 R10 上没有这个卷。
2026-11-16 起 `apply-board.sh` 会把这三个定义包进 `case "$(board_name)"`，仅在
H10 机型生效。**注意**：这个 bug 在**运行中的旧固件**里也存在，所以刷入这一版之前
若报同样错误，可先在旧固件里把 `/lib/upgrade/pt1500-fip.sh` 的函数体用同样的
`case` 包起来，或直接用 U-Boot recovery 刷写。
（排查命令：`sh -x /sbin/sysupgrade -T /tmp/firmware.bin` 能看到加载顺序）

**Q：刷完没有无线信号？**
按顺序查：`dmesg | grep -i -E 'rtl_ax|EINVAL'` → `ls -l /lib/firmware/realtek/tyfza1/`
→ `ls -l /etc/init.d/tyfza1-factory`（**必须有 `x`**）→ `cat /lib/firmware/realtek/tyfza1/rtl8852ce/flash-calibration.bin | wc -c`（**必须是 284**）。

**Q：电脑能看到 2.4G，手机看不到？**
参见 §6 的 HE 信标历史事件。先确认当前 htmode：`grep -i htmode /etc/config/wireless`
（推导模式下 2.4G 为 HE20）。若怀疑是 HE 信标兼容性，LuCI 里把 2.4G htmode 手动改
**HT20** 观察手机能否搜到；能搜到即可确认，再决定是否回仓库长期钉回。

**Q：网口顺序和面板对不上？**
`scripts/patch-upstream.sh` 里对 R10 用 `index = 4 - port` 修正命名。如果上游改了这段
switch，断言会在 `preflight.sh` 第 7b 节直接报错。

**Q：为什么第一次（或改了 diy 脚本后）还是要编一小时？**
缓存是"内容寻址 + 配置指纹"的：改了 `diy-part1/2.sh`、`.config` 或 `scripts/*`，工具链缓存的 key
就会变，必须重建一次；之后同配置的构建才能吃到缓存。想确认命中情况，看这两处：
Actions 日志里 `Restore toolchain & host tools cache` 是否显示 `Cache restored`，
以及编译结束时的 `ccache stats` 里 `Hits / Misses` 比例（正常 ≥ 70%）。

**Q：能不能加别的插件？**
在 `configs/youhua_pt1570-r10.config` 里加 `CONFIG_PACKAGE_xxx=y`，并在 `diy-part2.sh`
第 6 节的断言列表里补上同名符号 —— 否则 defconfig 静默丢包时你不会收到任何提示。

---

## 11. 上游与致谢

### 上游基座（锁定的 commit 是什么）

`source_ref` 的默认值 `20b4cf4490ca55cc406d07e391691efa8cd8a087` 不是随手取的，它对应：

| 项目 | 值 |
|---|---|
| 仓库 | `lyq1996/rtl9617c-openwrt` |
| 分支 | `feature/pt1500-h10-openwrt-fixes`（**该分支 HEAD 就是这个 SHA**） |
| 作者 / 时间 | Leo，2026-11-07 19:45（北京时间） |
| 提交标题 | `pon: apply EPON queues per queue like stock` |
| 改动 | `package/tyfza1-pon-control/src/{pon-backend.h,pon-oamd.c}`、`.../uci-defaults/90-tyfza1-pon-wan` |

内容是把 `epon_sla` 里"整条 TCONT 重写"改成"逐队列更新 VOQ map / VSTBL credit / token bucket"，
对齐厂商固件的 `dal_rtl8277c_ponmac_queue_add()` 行为。

**为什么用完整 40 位 SHA**：Clone 步骤是 `git fetch --depth=1 origin "$SOURCE_REF"` 后
`checkout FETCH_HEAD`。写分支名会随上游前进而漂移——镜像内容变、缓存 key 失效、
"上次能跑这次不行"无法复现。写 SHA 才能字节级复现。

**为什么不能换成 `main` / `refactor`**：

| 分支 | HEAD | 说明 |
|---|---|---|
| `feature/pt1500-h10-openwrt-fixes` | `20b4cf4`（2026-11-07） | ✅ 本仓库基线，真机验证过 |
| `main` | `cea9938`（2026-10-29） | 早已停更，缺 PON 队列修复 |
| `refactor`（上游默认分支） | `13ebc89`（2026-11-13） | net 层 ni/fe 拆分 + RTL8221B PHY 内置补丁，**另一条开发线** |

后两者会与本仓库的 xram 端口映射（`index = 4 - port`）、PON 默认值、factory 284 补丁相互冲突，
换之前必须重新真机验证。

**分支前进后怎么办**：Clone 步骤在按 SHA 拉取失败时会回退到该分支并打 `::warning::`。
分支 HEAD 目前仍等于锁定 SHA，所以回退是等价的；一旦上游推进这个分支，回退就不再等价——
看到那条 warning 时，先核对新提交再决定是否更新锁定值（同时要重跑真机验证）。

### 致谢

- 源码基座：[`lyq1996/rtl9617c-openwrt`](https://github.com/lyq1996/rtl9617c-openwrt)
- 驱动参考：`dreamtekcat/PonWRT-TYFZA1`（pt1570 分支，PE IRAM revert 版）
- Workflow 结构参考：P3TERX `Actions-OpenWrt`
- DTS 依据：PT1570-R10 真机 `/proc/device-tree` 全量导出（447 个属性）交叉核对

许可证随上游：GPL-2.0。刷机有风险，请先确认自己有救砖手段（U-Boot Web Failsafe / 串口）。

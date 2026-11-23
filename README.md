# PT1570-R10-CI

友华 **PT1570-R10**（Realtek **RTL9617C**）的 OpenWrt FIT 固件云编译仓库。

采用 P3TERX `Actions-OpenWrt` 的"定制层"思路：**本仓库不存 OpenWrt 源码**，只放板级
支持、驱动 overlay、rootfs 默认值和防回归断言；GitHub Actions 在 runner 上克隆上游源码、
注入定制、编译、校验产物，最后发布到 Release。

- 上游基座（**双基线**）：`lyq1996/rtl9617c-openwrt`
  - **克隆基线 = `refactor`
  - **硬件层 = `20b4cf4`**（分支 `feature/pt1500-h10-openwrt-fixes` HEAD，2026-11-07，
    `pon: apply EPON queues per queue like stock`）——编译时在 refactor 之上叠加

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
   | `source_ref` | `ae4aeac…` | 克隆基线 commit / 分支。默认 = `refactor` @ `ae4aeac`（用户指定）；编译时会叠加 `20b4cf4` 硬件层（详见 §11「上游基座」） |
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
| 5G | SSID `PT1570-R10-5G`，**开放（无密码）**，htmode/信道交还驱动推导（预期 HE80 / auto） |
| 2.4G | SSID `PT1570-R10-2.4G`，**开放（无密码）**，htmode/信道交还驱动推导（预期 HE20 / auto） |
| 面板灯 | 跟随真实网口（EPHY0..3 → LAN4..LAN1） |

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
  主题已由 argon 换成 **design**（`luci-theme-design`，`0x676e67/luci-theme-design`
  的 main/lua 版，`diy-part1.sh` 调 `scripts/overlay-theme.sh` 直接拉库编译，
  锁 commit `5cea733`）。默认主题由包自带 `30_luci-theme-design` 设定。
  厂商的两处 argon 设置都已删除：workflow 不再 checkout `luci-theme-argon` 包，
  PON 包里的 `95-tyfza1-argon` / `97-tyfza1-argon-default` 由 overlay 脚本删除
  （这两个脚本序号靠后，会抢走 design 的默认主题）。
  未启用 tailscale / samba / vsftpd / upnp / wol —— 这些是定制项，
  需要时在 `configs/youhua_pt1570-r10.config` 里加 `CONFIG_PACKAGE_*` 即可
  （`diy-part2` 第 5/6 节会重新断言防丢包）。主题一律走包构建，不以静态文件注入 `files/`。

> ⚠️ GitHub 单仓库缓存配额 **10 GB**（LRU 淘汰）。四层缓存全量约 7–8 GB，正常够用。
> 如果发现 dl 缓存老是被挤掉，优先调小 `CCACHE_MAXSIZE`（workflow 顶部 env，默认 1200M）。

### 5.3 Release 只保留最新一次编译

Release 是**滚动**语义（tag 固定，如 `pt1570-r10`），但产物文件名带时间戳
（`…-squashfs-sysupgrade-20261114-1600.itb`）。`softprops/action-gh-release` 只覆盖**同名**附件，
所以每隔一次编译就会多留一套旧 itb —— 十几轮之后 Release 列表就没法看了。

现在发布后会多跑一步「清理旧附件」，按**本次产物清单**反删其余附件，最终只留下最新一套。

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

## 6. 目录结构

```
.
├── diy-part1.sh                    # feeds 之后、加载 .config 之前：往源码树"注入"
├── diy-part2.sh                    # 加载 .config 之后：默认值定制 + 两次 defconfig + 硬断言
├── configs/
│   └── youhua_pt1570-r10.config     # 机型无关的基础包集合（机型由 target_model 决定）
├── files/                           # 原样覆盖进 rootfs
│   ├── etc/modules.d/50-rtl-ax-ap            # rtl_ax_ap 模块自动加载（ITB 移植，见 §6.1）
│   ├── etc/hotplug.d/ieee80211/10-wifi-detect # 无线 add 后重跑 wifi config（ITB 移植）
│   ├── etc/uci-defaults/92-pt1570-r10-wifi-default  # 双频首启 SSID/加密（ITB 移植，见 §6.1）
│   ├── etc/uci-defaults/92-pt1570-r10-wireless-country # 默认 country=CN（ITB 移植）
│   ├── etc/init.d/tyfza1-factory            # factory 校准提取（必须精确 284 字节）
│   ├── etc/init.d/wifi-regdom               # 开机兜底 regdomain=CN（5G 必需，见 §6.2）
│   ├── etc/uci-defaults/96-pt1570-r10-leds     # 面板灯 → 真实网口
│   ├── etc/uci-defaults/97-pt1570-r10-wifi24   # 2.4G 首启兜底：country/启用/不隐藏（见 §6）
│   ├── etc/uci-defaults/98-pt1570-r10-wifi-stability  # 断流缓解：不踢空闲终端 + country（见 FAQ）
│   ├── etc/uci-defaults/99-pt1570-fit          # 时区/主机名/FIT 接线兜底
│   └── lib/firmware/realtek/tyfza1/            # ITB 全量 AP 固件 + 70 张射频表（含 RFE50/PON_2G/YH9570，见 §6.1）
│   └── lib/firmware/regulatory.db(+.p7s)       # 带签名的无线法规库，5G 不广播的根因修复（见 §6.2）
├── board/
│   ├── dts/rtl9617c-pt1570-r10.dts  # 板级 DTS（root=/dev/fit0 自洽启动、按键修正）
│   ├── devices/pt1570-r10.mk.inc    # image/Makefile 的 Device 定义片段
│   └── wifi/rtl_ax_ap/              # 已真机验证的驱动全套（PE IRAM revert 版）
├── scripts/
│   ├── apply-board.sh               # 注入 DTS + Device + sysupgrade 白名单
│   ├── overlay-wifi-driver.sh       # 整套替换驱动（含 pe-tx-code.h md5 强校验）
│   ├── patch-upstream.sh            # 上游修补：factory 284 / fitblk 上限 / R10 端口命名
│   ├── preflight.sh                 # 静态自检，编译前跑，任何 FAIL 立即终止
│   ├── verify-rf-tables.py          # 70 张表逐字段模拟驱动解析器（ITB 全量，见 §6.1）
│   └── verify-fit-boot.py           # 产物 FIT 结构 + bootargs 可启动性校验
├── .github/workflows/
│   └── Build-PT1570-R10.yml         # 唯一 workflow（32 步）
├── .gitattributes                   # 全仓锁定 LF
└── .gitignore                       # 忽略编译产物 / 本地缓存
```

---

## 7. 常见问题

**Q：为什么第一次（或改了 diy 脚本后）还是要编一小时？**
缓存是"内容寻址 + 配置指纹"的：改了 `diy-part1/2.sh`、`.config` 或 `scripts/*`，工具链缓存的 key
就会变，必须重建一次；之后同配置的构建才能吃到缓存。想确认命中情况，看这两处：
Actions 日志里 `Restore toolchain & host tools cache` 是否显示 `Cache restored`，
以及编译结束时的 `ccache stats` 里 `Hits / Misses` 比例（正常 ≥ 70%）。

**Q：能不能加别的插件？**
在 `configs/youhua_pt1570-r10.config` 里加 `CONFIG_PACKAGE_xxx=y`，并在 `diy-part2.sh`
第 6 节的断言列表里补上同名符号 —— 否则 defconfig 静默丢包时你不会收到任何提示。

---

## 8. 上游与致谢

### 上游基座（双基线：refactor 克隆 + 20b4cf4 硬件层）

按你的要求，**克隆基线用 `refactor`**。但 refactor 是 net 层 ni/fe 拆分的新代码线，
它把 PCIe/WiFi/USB/LED 驱动和 4GE 板级 DTS 都删了——单独用它编不出 PT1570-R10 的完整固件
（无 WiFi、无 USB、无面板灯、4GE 不通）。所以编译时在 refactor 基线之上**叠加**一套
已真机验证的硬件层，两者各司其职：

| 角色 | 变量 | 锁定值 | 来源分支 | 作用 |
|---|---|---|---|---|
| 克隆基线 | `SOURCE_REF` | `ae4aeac45a70be1bdf68af65cbbacb360f201b27` | `refactor`（2026-11-19 HEAD） | 提供 net 层 ni/fe 拆分等主线代码 |
| 硬件层 | `HARDWARE_REF` | `20b4cf4490ca55cc406d07e391691efa8cd8a087` | `feature/pt1500-h10-openwrt-fixes`（2026-11-07 HEAD） | 提供 PCIe/WiFi/USB/LED 驱动、4GE DTS、PON/LuCI 包 |

**叠加具体做什么**（workflow 的 Clone 步骤，早于 diy-part1）：

1. `git clone --depth=1` 后 `checkout $SOURCE_REF`（refactor 基线）。
2. `fetch $HARDWARE_REF`，用它的**整棵** `target/linux/rtl9617c` 替换 refactor 的
   （`rm -rf` 再 `git checkout $HW_REF -- target/linux/rtl9617c`）——保证驱动、内核 patch、
   dtsi 内部一致，net 层拆分不进入。
3. 补齐 refactor 没有的包：`tyfza1-pon-control`、`luci-app-tyfza1-pon`、
   `pt1500-storage`、`tools/mtd-utils/Makefile`、wifi-scripts 的 ucode 文件。
   （argon 主题包已去掉，design 由 diy-part1 的 overlay-theme.sh 直接拉库。）
4. 之后 diy-part1/2 的全部注入逻辑原样运行（它们依赖的正是 20b4cf4 形态的源码树）。

这样 refactor 是名副其实的 git 基线，而真机验证过的驱动/修复一个不少。
两个值都写完整 40 位 SHA、`git fetch --depth=1 origin <SHA>` 精确检出，字节级可复现；
缓存 key `SOURCE_HASH=${BASE_HASH}-${HW_HASH}` 同时绑定两者，任一线前进都换 key，
绝不拿旧缓存编新组合。`preflight.sh` 会校验这套双基线配置没被改坏。

**另两条线为什么单独都不行**：

| 分支 | HEAD | 说明 |
|---|---|---|
| `refactor` | `ae4aeac`（2026-11-19） | ✅ 克隆基线；但缺 WiFi/USB/LED/4GE 驱动，须叠加硬件层 |
| `feature/pt1500-h10-openwrt-fixes` | `20b4cf4`（2026-11-07） | ✅ 硬件层来源，真机验证过 |
| `main` | `cea9938`（2026-10-29） | 早已停更，缺 PON 队列修复，不用 |

**分支前进后怎么办**：Clone 步骤在按 SHA 拉取失败时会回退到对应分支并打 `::warning::`。
看到 warning 时先核对新提交，确认无回归再更新锁定值（同时要重跑真机验证）。

### 致谢

- 源码基座：[`lyq1996/rtl9617c-openwrt`](https://github.com/lyq1996/rtl9617c-openwrt)
- 驱动参考：`dreamtekcat/PonWRT-TYFZA1`（pt1570 分支，PE IRAM revert 版）
- Workflow 结构参考：P3TERX `Actions-OpenWrt`
- DTS 依据：PT1570-R10 真机 `/proc/device-tree` 全量导出（447 个属性）交叉核对

许可证随上游：GPL-2.0。刷机有风险，请先确认自己有救砖手段（U-Boot Web Failsafe / 串口）。

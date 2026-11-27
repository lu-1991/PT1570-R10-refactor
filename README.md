# PT1570-R10-CI

友华 **PT1570-R10**（Realtek **RTL9617C**）的 OpenWrt FIT 固件云编译仓库。

采用 P3TERX `Actions-OpenWrt` 的"定制层"思路：**本仓库不存 OpenWrt 源码**，只放板级
支持、驱动 overlay、rootfs 默认值和防回归断言；GitHub Actions 在 runner 上克隆上游源码、
注入定制、编译、校验产物，最后发布到 Release。

- 上游基座（**纯 refactor 单基线**）：`lyq1996/rtl9617c-openwrt`
  - **克隆基线 = `refactor` @ `c815335`**（2026-11-27 HEAD，Taurus 平台驱动线；
    含 8192XB 闭环射频校准、PCIe coherent ATU / irq-affinity，以及 wifi
    flush/beacon 超时、txpower 下发与 rmmod 崩溃修复，见 §6）

---

## 1. 硬件规格

| 项目 | 规格 |
|---|---|
| SoC | Realtek RTL9617C，4×ARM Cortex-A55，target `rtl9617c/generic`（`aarch64_cortex-a55`） |
| 有线 | 4×GE（内部 GPHY 4 颗），面板标 LAN1–LAN4 |
| 上行 | PON（`rtl9617c-pon-control` 驱动，外部 feed；**无默认 WAN**，自行配置 VLAN/协议） |
| 5G | RTL8852CE（PCIe0 → `phy0`），rtw89 mac80211 backport + AP 固件，协议/信道由驱动推导（HE80 / auto） |
| 2.4G | RTL8192XBE（PCIe1 → `phy1`），同上方案（HE20 / auto） |
| 存储 | SPI NAND + UBI 5 分区；rootfs 以 FIT 子镜像形式挂在 `/dev/fit0` |
| 按键 | reset(gpio8)、rfkill(gpio99)、lights-toggle(gpio103) |
| 灯 | 12 颗（internet / los / pon / phone / usb0 / usb1 / power / wps / lan0–3） |
| factory 卷 | `0x1000` MAC、`0x2000` 5G 校准、`0x3000` 2.4G 校准、`0x4000` BOSA、`0x5000` PON A2H |

> 面板接线（真机逐口插线确认）：芯片 NI `port0..3` **反序**对应面板 `LAN4..LAN1`。
> 2026-11-25 起：Taurus NI 驱动直接读 R10 DTS 的 `label="lan1".."lan4"` 命名端口
> （不再用旧的 xram 内核补丁），面板灯由 `96-pt1570-r10-leds` 纠正。

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
   | `source_ref` | `c815335…` | 克隆基线 commit / 分支。默认 = `refactor` @ `c815335`（纯 refactor 单基线，无硬件层叠加，详见 §6） |
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
| `youhua_pt1570_r10` | 友华 PT1570-R10 | `pt1570-r10` | ✅ 本仓库目标机型（2026-11-25 切纯 refactor 后待真机复验） |

---

## 3. 刷机

**用 `*-squashfs-sysupgrade-<时间戳>.itb`，不要用 `initramfs-recovery`**（后者跑在内存里，
重启即失、配置不保存，只适合救砖/试启动）。

```sh
# 路由器上（或 LuCI → 系统 → 备份/刷写固件）
sysupgrade -n /tmp/openwrt-...-youhua_pt1570_r10-squashfs-sysupgrade-20261114-1530.itb
```

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

## 5. 目录结构

```
.
├── diy-part1.sh                    # feeds 之后、加载 .config 之前：往源码树"注入"
├── diy-part2.sh                    # 加载 .config 之后：默认值定制 + 两次 defconfig + 硬断言
├── configs/
│   └── youhua_pt1570-r10.config     # 机型无关的基础包集合（机型由 target_model 决定）
├── files/                           # 原样覆盖进 rootfs
│   ├── etc/hotplug.d/ieee80211/10-wifi-detect # 无线 add 后重跑 wifi config
│   ├── etc/uci-defaults/92-pt1570-r10-wifi-default  # 双频首启 SSID/加密
│   ├── etc/uci-defaults/92-pt1570-r10-wireless-country # 默认 country=CN
│   ├── etc/init.d/tyfza1-factory            # factory 卷提取（PON serial/MAC/BOSA；WiFi 校准已走 DTS nvmem）
│   ├── etc/init.d/wifi-regdom               # 开机兜底 regdomain=CN + 2.4G channel=6/HT20
│   ├── etc/uci-defaults/96-pt1570-r10-leds     # 面板灯 → 真实网口
│   ├── etc/uci-defaults/97-pt1570-r10-wifi24   # 2.4G 首启兜底
│   ├── etc/uci-defaults/98-pt1570-r10-wifi-stability  # 断流缓解
│   ├── etc/uci-defaults/99-pt1570-fit          # 时区/主机名/FIT 接线兜底
│   └── lib/firmware/regulatory.db(+.p7s)       # 带签名的无线法规库（5G 必需）
├── board/
│   ├── dts/rtl9617c-pt1570-r10.dts  # 板级 DTS（基于 rtk-taurus.dtsi 重写，Taurus compatible）
│   └── devices/pt1570-r10.mk.inc    # image/Makefile 的 Device 定义片段（新 PON 包名 + rtw89 kmod）
├── scripts/
│   ├── apply-board.sh               # 注入 DTS + Device + sysupgrade 白名单（Taurus 树）
│   ├── overlay-theme.sh             # 拉库 ucode 版 design + 清 argon 残留（适配外部 feed PON 包）
│   ├── patch-upstream.sh            # 上游修补：fitblk 4MiB 上限 + NI EEE/LPI 关闭
│   ├── preflight.sh                 # 静态自检，编译前跑，任何 FAIL 立即终止
│   └── verify-fit-boot.py           # 产物 FIT 结构 + bootargs 可启动性校验
├── .github/workflows/
│   └── Build-PT1570-R10.yml         # 唯一 workflow（32 步）
├── .gitattributes                   # 全仓锁定 LF
└── .gitignore                       # 忽略编译产物 / 本地缓存
```

---
## 6. 上游与致谢

### 上游基座（纯 refactor 单基线 @ c815335）

| 项目 | 值 |
|---|---|
| 克隆基线 `SOURCE_REF` | `c81533502df6533b273c5201f99f67abd88c62ab`（`refactor` 2026-11-27 HEAD） |
| PON 包 | 外部 feed `crysister/rtl9617c-packages`（`rtl9617c-pon-control` / `luci-app-rtl9617c-pon`） |
| WiFi | 上游 mac80211 backport 补丁(100-103) + `kmod-rtw89-8852ce` / `kmod-rtw89-8192xbe` + `rtl*-ap-firmware` 包 |
| R10 板级 | 本仓库 `board/dts/rtl9617c-pt1570-r10.dts`（基于 `rtk-taurus.dtsi` 重写） |

**有线/WiFi 关键适配点**（都在 `board/dts/rtl9617c-pt1570-r10.dts`）：
- 4×GE：MDIO 下 `ethernet-phy@1..4`，NI `port0..3` → 面板 LAN4..LAN1，`label` 显式命名；
- WiFi：pcie0 5G 设 `realtek,ap-firmware` + RFE54，pcie1 2.4G 也设 **RFE54**（双频
  都是 eFEM）；双频各绑 factory 卷的 `wifi_cal_radio0/1` nvmem cell。
  RFE 定案过程（2026-11-26 真机两轮）：`rtw8192xb_rfe_gpio()` 里只有 `rfe_type > 50`
  才会把 PAPE（PA 使能）/ TRSW（TX-RX 开关）/ LNAON 路由到引脚，`50` 分支一条 GPIO
  都不配。曾据"旧厂商固件用 `RFE50/PON_2G` 表"把 2.4G 写成 50，真机结果是：能扫到
  邻居 AP（-60 dBm，RX 正常）、`AP-ENABLED`、`txpower 20 dBm`、驱动侧 `tx_packets`
  也在涨，但手机贴着天线也搜不到 SSID —— 帧出了 MAC，外置 FEM 的 T/R 开关停在接收
  侧、PA 使能悬空，一级放大都没有。错判根源是那份厂商固件同时带了 `RFE50` 与
  `RFE54/RTK66287`（RTK66287 即外置 PA+LNA 模组）两套表，一套固件覆盖多板型，不能
  反推本板型号。现已改回 54，preflight 断言双频必须都是 `<54>` 且不得出现 `<50>`；
- 2.4G 发射链路（上游 `b842507`，2026-11-26）：此前上游 103 补丁只带 IQK，没有
  TSSI/DPK/TXGAPK，2.4G 的 TX 功率与温补表实际未标定；该提交补齐 `rtw8192xb_tssi*`
  / `rtw8192xb_dpk` / `rtw8192xb_txgapk` / `power_trim` / `fem_setup`，TSSI 内部按
  `is_efem = rfe_type >= 51` 分 eFEM/iFEM 两套初值（RFE54 走 eFEM 那套）；
- WiFi 稳定性（上游 `79b6a45` / `c815335`，2026-11-26/27）：`79b6a45` 把 6GHz
  `sband`/`channels`/`bitrates`/`iftype_data` 从 `kfree` 改为 `devm_kfree`，修掉
  真机 `rmmod rtw89_8192xbe` 时的 `list_del/list_add corruption` 内核警告；
  `c815335` 在 `dle_is_txq_empty()` 里忽略 AP beacon 的 `CMAC0_MBH`/`DMAC_CPUIO`
  busy 位、并把 `rtw89_mac_bcn_drop()` 超时按 `beacon_int` 缩放，修掉真机
  `timed out to flush queues`（2.4G beacon 发不出去的直接证据）；同提交还补齐
  txpower 下发（`BSS_CHANGED_TXPOWER` / `get_txpower`，用户功率表上限）、
  multi-BSS（最多 5 组 AP）、SER L2 恢复与 ACS survey —— 这几项与 R10 的
  2.4G 无发射、5G 弱信号现象直接相关，故基线必须锁在 `c815335` 及以后；
- PCIe（上游 `cd75278`，2026-11-26）：`rtk-taurus.dtsi` 给两路控制器加了
  `coherent-atu` 窗口 + `realtek,coherent-hi-addr` + `dma-coherent`（本板 DTS
  include 该 dtsi，自动继承），驱动侧清 8 个 ATU 项并在 link training 前配好低/高
  2 GiB DDR 一致窗口；本板 DTS 再补 `irq-affinity = <1>/<2>` 把两路父中断从 CPU0
  挪到 CPU1/CPU2（与 tianyi 板同策略）。属性缺失时驱动记 -1 跳过，不会编译或启动失败；
- 2.4G 兜底：`wifi-regdom` 每次开机把 2.4G radio 的 channel 空/auto 落到 6、
  htmode 空/auto 落到 HT20（历史注释里"手机搜不到改 HT20"的对策，真机已复验），
  手动设定的合法值不动；空 country 补 CN；
- 四口 Link flap：`patch-upstream.sh` 从 NI 驱动 MAC 能力层去掉
  `lpi_capabilities` / `lpi_interfaces` / `lpi_timer_default`，关闭 EEE/LPI
  （refactor 新引入，GPHY 用 vendor MMD 模拟 EEE，与对端节能状态机不同步会反复重训链路）；
- 启动：`chosen.bootargs` 写死 `root=/dev/fit0` + `u-boot,version` 门闩（不依赖 bootloader
  注入 root=），ubi_device 分区可写（rootfs_data overlay 必需）；
- 系统内升级：`apply-board.sh` 必须在 `platform.sh` 的 check/upgrade 两处都注入合法
  case 分支 `youhua,pt1570-r10)`。旧写法 `youhua,pt1570-r10 |` 不是 case 分支，会落到
  `Unsupported board`，导致 Web 上传验证失败且 `-F` 强制更新也在 do_upgrade 阶段失败；
- LED/按键：旧 `gpio0` 全局编号按 `bank=floor(n/32), pin=n%32` 换成 `gpio_bankN` 分组编号。

> **旧 WiFi 资产已清理（2026-11-26）**：双基线时代手工塞进
> `files/lib/firmware/realtek/tyfza1/` 的 70 张射频表 + 旧 AP/NCTL 固件、以及
> `files/lib/firmware/rtw89/` 的非 AP 版固件，已全部删除（约 3.5 MB）。依据：新 rtw89
> backport 驱动把 PHY_REG/RadioA/TXPWR 表编译进 C 数组、校准走 DTS `wifi_cal_radio0/1`
> nvmem cell 直读 factory 卷、固件由 `rtl*-ap-firmware` 包提供，真机日志证实加载的是
> `rtw89/rtw8xxx_ap_fw.bin`。`tyfza1-factory` 保留 PON serial/MAC/BOSA 提取（仍在用），
> 已移除 WiFi flash-calibration 的 284B 生成/fallback 死代码。preflight 与 workflow 的
> 对应断言已同步改为"确认旧资产已清 + AP 固件进镜像"口径。

### 致谢

- 源码基座：[`lyq1996/rtl9617c-openwrt`](https://github.com/lyq1996/rtl9617c-openwrt)
- 驱动参考：`dreamtekcat/PonWRT-TYFZA1`（pt1570 分支，PE IRAM revert 版）
- Workflow 结构参考：P3TERX `Actions-OpenWrt`
- DTS 依据：PT1570-R10 真机 `/proc/device-tree` 全量导出（447 个属性）交叉核对

许可证随上游：GPL-2.0。刷机有风险，请先确认自己有救砖手段（U-Boot Web Failsafe / 串口）。

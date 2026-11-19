# 友华 PT1570-R10 (RTL9617C) OpenWrt 云编译源码 —— 云端拉库版

这个仓库**只有适配层**（几十 KB），不含 292MB 的 OpenWrt 源码树。
编译时由 GitHub Actions 在云端自动从上游拉取源码、叠加硬件层与 PT1570-R10 设备定义，然后编译出固件。

## 上传与编译（三步）

1. 在 GitHub 新建一个**空仓库**（public/private 均可）。
2. 把本目录所有内容（含 `.github/` 隐藏目录）推送上去：

   ```bash
   cd PT1570-R10-云端拉库编译
   git init
   git add -A
   git commit -m "PT1570-R10 cloud-build adapter"
   git remote add origin https://github.com/<你的账号>/<仓库名>.git
   git branch -M main
   git push -u origin main
   ```

   > 推送前请确认 `.github/workflows/build-pt1570-r10.yml` 一并被 `git add`（它是隐藏目录，容易漏）。

3. 打开仓库 **Actions** 页面 → 左侧选 **Build PT1570-R10 (云端拉库)** → **Run workflow**，
   可填 SSID / 密码 / 管理 IP，跑完在 Artifacts 下载 `PT1570-R10-firmware`。
   若想同时发 Release，把 `make_release` 勾上（需给 workflow 加 `contents: write` 权限，见下）。

## 云端做了什么

`scripts/cloud-pull.sh` 按固定 commit 拉取，保证每次编译可复现：

| 步骤 | 来源 | 内容 |
| --- | --- | --- |
| 基线 | `lyq1996/rtl9617c-openwrt` @ `refactor` (`ae4aeac`) | OpenWrt 主树 |
| 硬件层 | 同仓库 `20b4cf4` | 完整 `target/linux/rtl9617c`（PCIe/WiFi/USB/LED 驱动、4GE DTSI）、PON/LuCI 包、mtd-utils 修复、wifi-scripts |
| 设备适配 | 本仓库 `board/` | PT1570-R10 DTS + image profile 补丁 + sysupgrade 白名单补丁 |
| 配置 | 本仓库 `config-pt1570-r10.txt` + `customize-pt1570.sh` | 机型、软件包、默认 IP/SSID/时区 |

硬件层 commit `20b4cf4` 来自已在 PT1570-R10 真机启动验证的方案（4×GE、双频 WiFi、PON 拨号、FIT 启动均正常）。
其中两个关键防变砖修复：不覆盖 `chosen/bootargs`、去掉 `ubi_device` 的 `read-only`。

## 目录结构

```
.
├── .github/workflows/build-pt1570-r10.yml   # 云编译工作流（手动触发，可发 Release）
├── scripts/cloud-pull.sh                    # 云端拉库 + 叠加适配 + 校验
├── board/
│   ├── dts/rtl9617c-pt1570-r10.dts          # 设备树
│   └── patches/
│       ├── 901-pt1570-image.patch           # image Makefile: 新增 youhua_pt1570_r10 profile
│       └── 902-pt1570-sysupgrade.patch      # sysupgrade 白名单
├── config-pt1570-r10.txt                    # 配置种子
└── customize-pt1570.sh                      # 默认设置 + 关键包二次断言
```

## 固件内容与刷机提醒

功能：PON 拨号 + 4×千兆 LAN、双频 WiFi（RTL8852CE 5G / RTL8192XBE 2.4G）、LuCI 中文界面、USB 存储、面板 LED/三按键。

**刷机前**：这是 FIT UBI 统一方案固件，需配合社区 U-Boot（`pt1570-r10.boot.bin`）和重建的 UBI 布局，原厂 A/B 卷不能直接刷。
务必保留原厂备份 `pt1570-r10-backup/`，尤其 `mtd1/env`、`mtd2/env2` 和 `mtd4/ubi_device` 里的 factory 卷（MAC / PON SN / 校准数据）。

## 常见问题

- **Actions 里找不到工作流**：确认 `.github/workflows/` 已推送；GitHub 默认禁用 workflows 时，到 Actions 页面点 "I understand my workflows, go ahead and enable them"。
- **Release 发布失败**：在仓库 Settings → Actions → General → Workflow permissions 选 "Read and write permissions"。
- **编译报错**：下载对应 run 的 `build.log` artifact 发我，我据此调整补丁。
- **本地也想编译**：桌面另有完整源码树 `PT1570-R10-OpenWrt-云编译源码`（292MB，Linux 下可直接 `make`）。

## 可复现性说明

上游 `refactor` 分支 HEAD 若前进，`cloud-pull.sh` 会打印警告但仍继续（优先用当前 HEAD）；若编译异常，可把脚本里的 `REFACTOR_COMMIT` 固定为 `ae4aeac45a70be1bdf68af65cbbacb360f201b27`。硬件层 commit 已用完整 SHA 固定。

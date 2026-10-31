# 交接报告：小米平板 5（nabu）Ubuntu 相机 bring-up

> **⚠️ 项目已终止（2026-10-31 17:30）**：用户决定放弃相机适配，设备上的全部调试改动已还原：
> 删除了 ESP 中的 `6.14.11-cam1.efi` / `6.14.11-cam2.efi`、`/lib/modules/6.14.11-nabu-cam1`、
> 设备上的内核源码树与诊断产物，并已重启回日常内核 `6.14.11-nabu-tmm`。
> 开发包（gcc、v4l-utils 等）按用户要求保留。本文档仅作技术存档，供以后重新启动时参考。

> 生成时间：2026-10-31 16:30（Asia/Shanghai）
> 目的：让下一个 AI / 开发者无需回溯对话即可继续推进。
> 工作区：`<workspace>`

---

## 0. 一句话现状

**Phase 1 已完成**（CCI 总线、双路供电、MCLK、复位全部打通，两颗传感器 `ov13b10` / `ov8856` 都能 probe）。
**Phase 2 进行中**：CAMSS 驱动已加入 SM8150 资源集，能 probe 出 `/dev/media0` 和 `/dev/video0..7`，但 VFE 格式路径有一个"Unsupported HW version" WARN；修复已编译安装，**最后一次重启后尚未验证**（设备一度在 `10.210.131.x` 可连，随后失联）。

当前目标：先抓到一帧 RAW（前摄 ov8856 优先），再进 libcamera softISP 出图。

---

## 1. 设备与环境

| 项目 | 值 |
|---|---|
| 设备 | Xiaomi Pad 5（nabu，SM8150 / 骁龙 860） |
| 系统 | Ubuntu 26.04 (resolute)，GNOME |
| 当前测试内核 | `6.14.11-nabu-cam1`（我们自己编的，独立于日常内核） |
| 日常内核 | `6.14.11-nabu-tmm`（原厂社区内核，rEFInd 里选它可回退） |
| 启动方式 | ESP(sda31, FAT32, 334MB) + rEFInd；内核是 UKI（`.linux`+`.dtb`+`.cmdline`+`.uname`，**无 initramfs**），放在 `EFI/ubuntu/*.efi` |
| SSH | 用户 `xiany`，密码由用户提供（**本文件不保存密码**） |
| 网络 | Wi-Fi 2.4G，每次重启随机 MAC → **IP 每次都会变** |

### 1.1 设备 IP 变化怎么处理

让用户看一下 WiFi 详情，或用 PowerShell 扫全网段（本会话验证可用）：

```powershell
$env:SSH_ASKPASS='<workspace>\.tmp-askpass.bat'  # 内含密码，需重建
$env:SSH_ASKPASS_REQUIRE='force'; $env:DISPLAY='localhost:0'
$opts=@('-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=NUL','-o','PreferredAuthentications=password','-o','PubkeyAuthentication=no','-o','ConnectTimeout=4')
$clients=@(); $tasks=@()
foreach ($i in 1..254) { $h="10.210.131.$i"; $c=[System.Net.Sockets.TcpClient]::new(); $clients+=$c; $tasks+=[pscustomobject]@{h=$h;t=$c.ConnectAsync($h,22)} }
Start-Sleep -Milliseconds 1800
$up=$tasks | Where-Object { $_.t.IsCompleted -and $_.t.Status -eq 'RanToCompletion' } | ForEach-Object { $_.h }
$clients | ForEach-Object { $_.Dispose() }
foreach ($h in $up) { $r = ssh @opts "xiany@$h" "hostname" 2>$null; if ($r -match 'xiany') { "FOUND $h" } }
```

历史 IP（都失效了，仅供判断网段）：`.85 .25 .144 .3 .173 .59 .107 .179`。

### 1.2 设备上的构建环境（已装好，重启不丢）

- 源码：`/home/xiany/kbuild/linux-sm8150-6.14.11`（1.7 GB）
- 工具链：gcc 15.2.0、make 4.4.1、dtc 1.7.2、ukify（systemd 259）、v4l-utils、i2c-tools、libcamera-tools 均已安装
- 配置：`.config` 取自设备 `/proc/config.gz`，改动：
  - `LOCALVERSION="-nabu-cam1"`，`LOCALVERSION_AUTO` 关闭
  - `CONFIG_SM_CAMCC_8150=y`
  - `CONFIG_VIDEO_OV8856=m`、`CONFIG_VIDEO_OV13B10=m`、`CONFIG_VIDEO_QCOM_CAMSS=m`、`CONFIG_I2C_QCOM_CCI=m`
- 模块目录：`/lib/modules/6.14.11-nabu-cam1`（140 MB，与日常内核完全隔离）

### 1.3 本地工作区（唯一的"源码真值"）

| 路径 | 内容 |
|---|---|
| `src/linux/linux-sm8150-6.14.11/` | 已应用全部改动的内核树（7 个文件被改） |
| `docs/patches/nabu-camera-bringup.patch` | 相对原厂 zip 的完整补丁（7 文件，23 KB） |
| `docs/camera-feasibility.md` | 可行性评估（含实测结论） |
| `docs/camera-workplan-appendix.md` | DTS 全文、驱动补丁、构建/刷机流程、Phase 1 踩坑记录 |
| `tools/collect-camera-info.sh` | 设备侧诊断采集脚本 |
| `collect/` | 第一次采集的诊断包（config/dmesg/DT/UKI 信息） |

---

## 2. 硬件事实（来自工厂 DTS，已核实）

| 项目 | 后摄 | 前摄 |
|---|---|---|
| Sensor | OV13B10 @0x10 | OV8856 @0x10 |
| CCI | CCI0 master0（i2c-3） | CCI0 master1（i2c-4） |
| CSIPHY | 0（0xac65000，IRQ 477） | 1（0xac66000，IRQ 478） |
| MCLK | camcc MCLK0，TLMM GPIO13 | camcc MCLK1，TLMM GPIO14 |
| Reset | GPIO28（active low） | GPIO30（active low） |
| VANA 开关 | GPIO11 | GPIO31 |
| VIO 1.8V | PM8150L LDO1（`vreg_l1c_1p8`） | 同左 |
| VANA 3.0~4.0V | PM8150L BOB（`vreg_bob`） | 同左 |
| VDIG 1.2V | PM8150L GPIO3 控制的固定 LDO（`vreg_cam_vdig`） | 同左 |
| link-freq | 560 MHz（4 lane） | 360/180 MHz（4 lane，两个都必须列） |

SoC 侧：CSID 0xacb3000 / 0xacba000（IRQ 464/466），VFE 0xacaf000 / 0xacb6000（IRQ 465/467），CSIPHY 0xac65000–0xac68000，CCI0 0xac4a000（IRQ 460）。另有 2 个 CSID-lite、2 个 VFE-lite 未启用。

---

## 3. 已完成：Phase 1（✅ 已验证）

结果：

```
/sys/bus/i2c/devices/3-0010 -> ov13b10
/sys/bus/i2c/devices/4-0010 -> ov8856
```

ov8856 在 probe 阶段会真实读 chip ID（0x300A/0x300B），probe 成功 = 供电/时钟/复位/CCI 全对。

### 3.1 四个必须知道的坑

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | `CCI reset timeout` | CCI 少给 AHB 类时钟，寄存器访问不通 | 补 `CAMNOC_AXI`、`SLOW_AHB_SRC`、`CPAS_AHB`、`CORE_AHB` + `assigned-clock-rates`（80 MHz / 37.5 MHz） |
| 2 | 前摄 `master 1 queue 0 timeout` | CCI0 master1 用 GPIO19/20，pinctrl 只 mux 了 17/18 | `cci0_default` pins 加 `gpio19/20` |
| 3 | ov13b10 不 probe，bind 返回 EIO 且无日志 | 6.14 的 `ov13b10.c` **只有 ACPI match** | 加 `of_match_table`（`ovti,ov13b10`） |
| 4 | `ov8856: no link frequency ... supported` | 驱动要求 DT 列出该 lane 配置的**全部**表项 | 4-lane 写 `<360000000 180000000>` |

---

## 4. Phase 2 进行中（⚠️ 未完成）

### 4.1 已写好的代码（都在本地树 + 已部署到设备）

| 文件 | 改动 |
|---|---|
| `drivers/media/platform/qcom/camss/camss.h` | 枚举加 `CAMSS_8150` |
| `drivers/media/platform/qcom/camss/camss.c` | 新增 `csiphy_res_8150[2]`、`csid_res_8150[2]`、`vfe_res_8150[2]`、`sm8150_resources`、`qcom,sm8150-camss` match |
| `drivers/media/platform/qcom/camss/camss-vfe.c` | 两处 `switch (version)` 加 `case CAMSS_8150`（`vfe_src_pad_code`、`vfe_bpl_align`） |
| `drivers/media/platform/qcom/camss/camss-csiphy-3ph-1-0.c` | `csiphy_gen2_config_lanes` 加 `case CAMSS_8150`，**暂用 sm8250 的 lane 寄存器表** |
| `arch/arm64/boot/dts/qcom/sm8150.dtsi` | 新增 `camss@ac65000`（2×csiphy、2×csid、2×vfe、23 个时钟、3 个 power-domain、8 个 IOMMU SID） |
| `arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dts` | `&camss` 使能 + `vdda-phy-supply` + ports/endpoints 与两颗 sensor 对接 |

### 4.2 已经观察到的现象（重要线索）

第一次带 camss 启动后：

```
/dev/media0
/dev/video0 ... /dev/video7
```

说明 **CAMSS probe 成功、subdev 和 video 节点都注册了**。但 dmesg 反复出现：

```
WARNING: ... camss-vfe.c:404 vfe_src_pad_code+0x134
"Unsupported HW version: 0x8150(?)"
```

已定位：`vfe_src_pad_code()` 的 `switch (version)` 没有 `CAMSS_8150` 分支。已按计划补上（同一组里加 case），并补了 `vfe_bpl_align` 与 csiphy lane 表的选择。模块已重编、安装、重启 —— **但重启后设备失联，这一版修复尚未验证**。

### 4.3 下一个 AI 要做的第一件事

1. 找到设备 IP（见 1.1），SSH 进去。
2. `dmesg | grep -iE 'WARNING|Unsupported|unknown cspi'` —— 确认 WARN 消失。
3. `media-ctl -p -d /dev/media0` —— 记录完整拓扑（csiphy/csid/vfe 实体名、pad、sensor 名）。
4. `v4l2-ctl --list-devices` 与 `for v in /dev/video*; do v4l2-ctl -d $v --list-formats; done`。
5. 按拓扑配置 pipeline，先抓前摄 RAW：

```bash
media-ctl -d /dev/media0 --set-v4l2 '"ov8856 4-0010":0[fmt:SBGGR10_1X10/3280x2464]'
# 依 media-ctl -p 的实际实体名/链接逐级设置 csiphy->csid->vfe
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3280,height=2464,pixelformat=BG10 \
         --stream-mmap --stream-count=5 --stream-to=/tmp/f.raw
```

### 4.4 已知风险 / 大概率要改的地方

| 风险 | 说明 | 处理建议 |
|---|---|---|
| IOMMU SID | 用了下游 DTS 的 `0x840/0x860/0xA40/0xA60/0xC40/0xC60/0xE40/0xE60`，mask `0x620` —— **未验证** | 先加内核参数 `iommu.passthrough=1` 排除；不行再逐个试 SID |
| CSIPHY 寄存器表 | SM8150 是 CSIPHY v1.1，我们暂时用 sm8250 的 `lane_regs_sm8250` | 若 CSI 起不来/无数据，改试 `lane_regs_sdm845`，或对照下游 `cam_csiphy_1_1` 新增一份表 |
| VFE/CSID 代际 | 用 `vfe_ops_170` + `csid_ops_gen2`（SM8150 实际是 175 代） | 先看能否出帧；不行再对照下游 `cam_vfe`/`cam_csid` 的 175 实现补 ops |
| VFE 时钟表 | 直接借了 sdm845 的表（上限 600 MHz，SM8150 可到 760 MHz） | 低分辨率测试无影响，高分辨率再调 |
| interconnect | 未配置（`icc_res = NULL`） | 若带宽不足再补 `mmss_noc`/`config_noc` |
| 只实现了 2/4 通道 | 只有 CSIPHY0/1、CSID0/1、VFE0/1；lite 通道未描述 | 满足前后摄即可，lite 通道后续再加 |

### 4.5 后续路线（Phase 3）

RAW 抓通后：libcamera 0.7 已装且有 softISP，把 sensor 加进 libcamera 的 sensor 属性表 → `cam -l` → `gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink` → GNOME Snapshot。之后再补 AF、闪光灯、EEPROM、双摄切换。

---

## 5. 构建 / 部署 / 回退（已跑通，照抄即可）

```bash
# 设备上
cd /home/xiany/kbuild/linux-sm8150-6.14.11

# 只改驱动（模块）：约 1 分钟
make -j6 modules
sudo make modules_install INSTALL_MOD_PATH=/
sudo depmod -a 6.14.11-nabu-cam1

# 改了 DTS：重编 dtb + 重打 UKI（Image 不变）
make -j6 qcom/sm8150-xiaomi-nabu.dtb
ukify build --linux=arch/arm64/boot/Image \
  --devicetree=arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb \
  --cmdline="root=PARTLABEL=linux rw fw_devlink=permissive" \
  --uname="6.14.11-nabu-cam1" --os-release=@/etc/os-release \
  --output=/tmp/6.14.11-cam1.efi
sudo mount /dev/disk/by-partlabel/esp /mnt/esp
sudo cp /tmp/6.14.11-cam1.efi /mnt/esp/EFI/ubuntu/
sync && sudo umount /mnt/esp

# 改了内核本体（Image）：全部重编，约 22 分钟
make -j6 Image modules
```

**回退**：重启 → rEFInd 菜单选 `6.14.11`（日常内核）。测试内核只新增 `EFI/ubuntu/6.14.11-cam1.efi`，旧文件与旧模块都没动。

**注意**：`/boot/vmlinuz-*`、`/boot/dtb-*` 只是留档，真正生效的是 ESP 里的 UKI。

---

## 6. 代码改动明细（7 个文件，见 `docs/patches/nabu-camera-bringup.patch`）

1. **`sm8150.dtsi`**
   - 新增 `camss@ac65000`：reg/reg-names（csiphy0/1、csid0/1、vfe0/1）、6 个中断、3 个 power-domain（`IFE_0_GDSC`/`IFE_1_GDSC`/`TITAN_TOP_GDSC`）、23 个时钟、8 个 `iommus`；
   - 新增 `cci@ac4a000`（`qcom,sm8250-cci`，6 个时钟含 4 个 AHB 类，master0/1 两条 i2c 总线）。
2. **`sm8150-xiaomi-nabu.dts`**
   - `cam_vdig`（PM8150L GPIO3）、`cam_vana_rear`（GPIO11）、`cam_vana_front`（GPIO31）三个 fixed regulator；
   - MCLK0/1、reset、CCI 四根线的 pinctrl；
   - `ov13b10@10`（CCI master0）与 `ov8856@10`（CCI master1），三路 supply + endpoint（含 link-frequencies）；
   - `&camss` 使能 + `vdda-phy-supply = <&vreg_l3c_1p2>` + 两个 port/endpoint 与 sensor 对接。
3. **`ov13b10.c`**
   - 单 `avdd` → `dovdd/avdd/dvdd` 三路 bulk regulator（搬上游 v8 补丁）；
   - 新增 `of_match_table`（6.14 原版没有，不加就永远不会 probe）。
4. **`camss.h`**：`CAMSS_8150` 枚举。
5. **`camss.c`**：SM8150 的 csiphy/csid/vfe 资源 + resources 结构 + DT match。
6. **`camss-vfe.c`**：`vfe_src_pad_code()` 与 `vfe_bpl_align()` 支持 `CAMSS_8150`。
7. **`camss-csiphy-3ph-1-0.c`**：`csiphy_gen2_config_lanes()` 支持 `CAMSS_8150`（暂用 sm8250 lane 表）。

---

## 7. 日常内核 vs 测试内核的差异（避免误判）

在跑的 `6.14.11-nabu-tmm` 的 DT 比我们这棵树多出 `idtp9418`（无线充电/hall）节点，且 `ufs reset-names` 是 `core_reset`、wifi `freq-table-hz` 不同。测试内核 DT 与驱动同源自洽，能正常启动，但**会缺无线充电等次要功能**——它只用于相机调试。

---

## 8. 给下一个 AI 的提示

- 所有源码改动以 `src/linux/linux-sm8150-6.14.11/` 为准；`docs/patches/nabu-camera-bringup.patch` 是相对原厂 zip 的 diff，可直接 `git apply` 到干净树。
- 设备上那份源码与本地一致（本轮最后一次同步后只差最后一次验证）。
- 迭代成本：改模块 ≈ 3 分钟（含重启），改 DTB ≈ 5 分钟，改 Image ≈ 25 分钟。**能改模块就别改 Image**。
- 每次重启 IP 必变；先扫描再操作。
- 若设备彻底连不上：让用户重启并在 rEFInd 里选 `6.14.11`（回日常内核），再排查测试内核是否挂起。
- `dmesg` 里 `ov8856 4-0010: failed to find sensor: -5` 表示 CCI master1 读不到 sensor（先查 pinctrl 19/20 与供电），`no link frequency` 表示 link-frequencies 列表不全。

# 小米平板 5（nabu）Ubuntu 26.04 相机修复可行性评估

- 评估日期：2026-10-31
- 评估对象：`linux-sm8150-6.14.11` 内核树 + `ubuntu-26.04-xiaomi-nabu.img.xz` + 小米官方 `nabu` 内核源码（Android 侧）
- 前提：Android 侧相机功能正常，说明**硬件、供电、MIPI 走线、传感器本身全部正常**，问题 100% 在 Linux 侧的软件栈。

---

## 一、结论

**可行，但这不是"配置/少装包"级别的问题，而是一次小规模的新平台移植。** 具体说：

| 判断项 | 结论 |
|---|---|
| 硬件是否支持 Linux | 支持。两颗传感器在主线上都有驱动；SoC 的相机时钟/电源域驱动在 6.14 里已经存在 |
| 为什么不工作 | 6.14.11 的 Qualcomm CAMSS（CSI 解码 + ISP 前端）**驱动不支持 SM8150**，且 `sm8150.dtsi` 里根本没有 CAMSS/CSI/CCI 节点 |
| 修复性质 | 写设备树 + 给 CAMSS 驱动增加 `SM8150` 资源集 + 给 OV13B10 补多路电源支持；用户态用 libcamera 软件 ISP 出图 |
| 工作量（有经验的嵌入式内核开发者） | 3–8 周；在我逐段对照下游代码协助下，可以压到 **2–4 周** |
| 第一个"确定性信号"多久能拿到 | **1–3 天**：只加 CCI + 供电 + 传感器节点，能读到传感器 chip ID，就能证明 80% 的硬件侧不确定性不存在 |
| 成功概率（后摄先出 raw 图） | 约 70–80%；双摄 + 自动对焦 + 闪光灯全功能约 50% |
| 变砖风险 | 极低。只改内核/DTB，不动 bootloader、不动分区表，随时可以刷回原镜像 |

一句话总结：**相机缺的不是"驱动包"，而是 CAMSS 驱动里的一份 SM8150 描述；好消息是所需要的时钟、电源域、IOMMU、NoC 节点在 6.14 里已经齐了，缺的部分可以照抄已经很成熟的 SDM845/SM8250 实现。**

---

## 二、硬件实况（从工厂设备树中读出的事实）

依据：Android 源码中的 [`nabu-sm8150-camera-sensor-mtp.dtsi`](../src/android/Xiaomi_Kernel_OpenSource-nabu-r-oss/arch/arm64/boot/dts/qcom/nabu-sm8150-camera-sensor-mtp.dtsi) 与 [`sm8150-camera.dtsi`](../src/android/cam/Xiaomi_Kernel_OpenSource-nabu-r-oss/arch/arm64/boot/dts/qcom/sm8150-camera.dtsi)。

### 2.1 传感器

| 项目 | 后摄（主摄） | 前摄 |
|---|---|---|
| 型号 | **OV13B10**（OmniVision 1300 万） | **OV8856**（OmniVision 800 万） |
| I²C 地址 | 0x10（7-bit） | 0x10（7-bit） |
| CCI 控制器 / master | CCI0 / master 0 | CCI0 / master 1 |
| CSI PHY | CSIPHY0（0xac65000） | CSIPHY1（0xac66000） |
| MIPI 时钟 | MCLK0 = TLMM GPIO 13 | MCLK1 = TLMM GPIO 14 |
| 复位 | TLMM GPIO 28 | TLMM GPIO 30 |
| VANA 开关 | TLMM GPIO 11 | TLMM GPIO 31 |
| VIO 1.8V | PM8150L LDO1 | PM8150L LDO1 |
| VANA 3.0–4.0V | PM8150L BOB | PM8150L BOB |
| VDIG 1.2V | PM8150L GPIO3 控制的固定 LDO（源 PM8150 S4） | 同上（工厂 DT 复用同一路） |
| 附加 | AF 马达（VAF 2.8V，TLMM GPIO 29）、EEPROM、闪光灯（PM8150L flash0/torch0） | EEPROM |

### 2.2 SoC 侧相机子系统（SM8150，代号 CAMSS 1.7.5 代）

| 模块 | 数量 / 基址 | 中断 |
|---|---|---|
| CSIPHY（v1.1） | 4 个：0xac65000 / 0xac66000 / 0xac67000 / 0xac68000 | 477/478/479/448 |
| CSID（175） | 2 个全功能：0xacb3000、0xacba000；2 个 lite：0xacc8000、0xaccf000 | 464/466/468/359 |
| VFE/IFE（175） | 2 个全功能：0xacaf000、0xacb6000；2 个 lite：0xacc4000、0xaccb000 | 465/467/469/360 |
| CCI | 2 个：0xac4a000（CCI0）、0xac4b000（CCI1） | 460 / 271 |
| 时钟控制器 | `camcc@ad00000`（CAMCC） | — |
| 电源域 | TITAN_TOP_GDSC、IFE_0_GDSC、IFE_1_GDSC | — |

**最小可用链路（后摄）**：`OV13B10 → CSIPHY0 → CSID0 → VFE0 → /dev/videoX（raw Bayer）`
**前摄**：`OV8856 → CSIPHY1 → CSID1 → VFE1`。

> 注意：后摄和前摄是两条**独立**链路，可以只做一条。前摄的 OV8856 主线驱动完整度更高（见 §3.4），**建议以前摄作为第一个出图目标，后摄紧随其后**。

---

## 三、为什么现在不工作：逐层缺口

| # | 层 | 当前状态（已核对源码） | 缺口 | 难度 |
|---|---|---|---|---|
| 1 | 设备树 | [`sm8150-xiaomi-nabu.dts`](../src/linux/linux-sm8150-6.14.11/arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dts) 中**没有任何** camera/csiphy/cci 节点；[`sm8150.dtsi`](../src/linux/linux-sm8150-6.14.11/arch/arm64/boot/dts/qcom/sm8150.dtsi) 中**没有** camss 节点 | 需新增 `camss@`、`cci@`、`csiphy@` 节点与传感器子节点 | 中（纯描述性工作） |
| 2 | CAMSS 驱动 | [`camss.c`](../src/linux/linux-sm8150-6.14.11/drivers/media/platform/qcom/camss/camss.c) 的 `camss_dt_match` 只有 8916/8953/8996/660/845/8250/sc7280/sc8280xp；**无 SM8150**。上游主线（截至 2026-10-31 的 master）也只有 `qcom,sm8250-camss.yaml` 等，**没有** `qcom,sm8150-camss.yaml` | 需新增 `CAMSS_8150` 资源集（csiphy/csid/vfe 的资源、时钟、电源域、IOMMU 流 ID） | **高（主要工作量）** |
| 3 | 时钟 / 电源域 | ✅ 已具备：[`camcc-sm8150.c`](../src/linux/linux-sm8150-6.14.11/drivers/clk/qcom/camcc-sm8150.c) 已在主线，含 MCLK0–3、CCI0/1、CSIPHY0–3、CSIxPHYTIMER、IFE0/1/lite 时钟，以及 `titan_top_gdsc` / `ife_0_gdsc` / `ife_1_gdsc`；[`qcom,sm8150-camcc.h`](../src/linux/linux-sm8150-6.14.11/include/dt-bindings/clock/qcom,sm8150-camcc.h) 绑定齐全 | 无（这是最大利好） | 无 |
| 4 | 传感器驱动 | `ov8856.c`：完整，支持 `dovdd/avdd/dvdd` 三路电源 ✅；`ov13b10.c`：**只支持单路 `avdd`**、无 DT binding yaml（6.14 状态） | OV13B10 需补三路电源（上游 2026-04 已有 v8 补丁可直接搬，见 §5） | 低 |
| 5 | CCI 总线驱动 | [`i2c-qcom-cci.c`](../src/linux/linux-sm8150-6.14.11/drivers/i2c/busses/i2c-qcom-cci.c) 有 `cci_v2` 数据，兼容 `qcom,sm8250-cci` 等；SM8150 的 CCI 也是 v2 代 | 加一条 `qcom,sm8150-cci` 兼容或直接复用 sm8250 的；补 DTS 节点 | 低 |
| 6 | 内核配置 | 未知（当前树里没有 `.config`） | 需确认 `CONFIG_VIDEO_QCOM_CAMSS`、`CONFIG_I2C_QCOM_CCI`、`CONFIG_VIDEO_OV13B10`、`CONFIG_VIDEO_OV8856`、`CONFIG_MEDIA_CONTROLLER` 等是否开启 | 低 |
| 7 | 用户态 | Ubuntu 26.04 自带 libcamera（0.6 及以上）+ PipeWire；libcamera 软件 ISP 在 2025–2026 已经成熟（FOSDEM 2026 有专场更新） | 需确认版本；可能需要为 OV13B10/OV8856 补 libcamera 的 sensor 属性表/调优文件 | 中 |

**结论：真正的墙只有一堵——CAMSS 驱动对 SM8150 的支持。** 其他都是"体力活"。

---

## 四、修复路线（分阶段，每阶段都有明确验收标准）

> 设计的核心原则：**先验证风险最高的假设，用最小改动换最大信息量**。所以顺序是"能不能点亮传感器 → 能不能收到 CSI 数据 → 能不能出图 → 好不好用"，而不是"一次性把驱动写完再试"。

### Phase 0：现状采集（0.5 天，你只需要跑一个脚本）

- 目标：确认你现在的内核到底编进了什么、libcamera 什么版本、设备树里有什么。
- 动作：在 Ubuntu 里运行 [`tools/collect-camera-info.sh`](../tools/collect-camera-info.sh)，把生成的 tar.gz 给我。
- 验收：拿到 `dmesg`、`/proc/config.gz`、`/proc/device-tree`、`media-ctl -p`、`lsmod`、libcamera 版本。
- 产出：确定是"内核完全没编 CAMSS"还是"编了但没设备树节点"。

### Phase 1：点灯——CCI + 供电 + 传感器探测（1–3 天）★ 最高性价比

- 目标：**不碰 CAMSS**，只让 Linux 能通过 CCI 读到传感器的 chip ID。
- 改动（约 150 行 DTS）：
  1. `sm8150.dtsi` 增加 `cci: i2c@ac4a000` 节点（`qcom,sm8250-cci` 兼容、CCI0 时钟、`titan_top_gdsc`）。
  2. `sm8150-xiaomi-nabu.dts` 增加：
     - `vreg_cam_vio`（PM8150L L1）、`vreg_cam_vana`（PM8150L BOB）、`cam_vdig`（PM8150L GPIO3 的 `regulator-fixed`）；
     - `cam_sensor_mclk0/1`、`cam_sensor_rear/front` pinctrl 状态；
     - `ov13b10@10` / `ov8856@10` 节点（reset-gpios、powerdown/vana-gpios、clock、三路 supply、`link-frequencies`、port/endpoint 指向 CSIPHY）。
  3. 打开 `CONFIG_I2C_QCOM_CCI`、`CONFIG_VIDEO_OV8856`、`CONFIG_VIDEO_OV13B10`。
- 验收：`dmesg` 出现 `ov8856 0-0010: Detected OV8856 sensor` / `ov13b10 ... chip id 0x13b1`，且 `i2cdetect -y <cci总线号>` 能看到 0x10。
- **意义**：这一步就把"供电时序、MCLK、复位 GPIO、CCI 总线"四个最容易翻车的点全部验证掉；后面 CAMSS 调试时如果读不到 sensor，就可以立刻排除这些原因。
- 风险：低。即使失败也只影响启动日志，不影响系统。

### Phase 2：CAMSS 打通（1–4 周，主要工作量）

拆成四个可独立验收的小步：

**2a. CSIPHY（2–4 天）**
- 在 `camss.c` 里新增 `csiphy_res_8150`、`csid_res_8150`、`vfe_res_8150` 与 `sm8150_resources`；先只填 **1 个 CSIPHY（0 号）**。
- 复用 `csiphy_ops_3ph_1_0`（与下游 `cam_sensor_csiphy` v1.1 逐寄存器对照，必要时新增 `csiphy_ops_3ph_1_1`）。
- 验收：`dmesg` 中 CAMSS probe 成功，`media-ctl -p` 能看到 `msm_csiphy0` 实体，且 PHY 初始化后无 timeout/IRQ 错误。

**2b. CSID（3–5 天）**
- 复用 `csid_ops_gen2`；SM8150 的 CSID 175 与 SDM845 的 CSID 170 差异通常只在虚拟通道/裁剪寄存器。
- 验收：CSI2 错误计数为零（`/sys/kernel/debug/...` 或 dmesg 无 "CSID error"）。

**2c. VFE（3–7 天）**
- 以 `vfe_ops_170` 为模板（SM8150 的 VFE **没有** SM8250 那种 `ife_ahb/areg` 时钟，时钟结构与 SDM845 更接近），先只做 **RDI 单路直通**（不做全功能 ISP、不做缩放/统计）。
- 验收：`v4l2-ctl --device /dev/video0 --stream-mmap --stream-count=10 --stream-to=/tmp/frame.raw` 能稳定拿到 4208×3120 RAW10 帧。

**2d. 联调（3–7 天）**
- 补 IOMMU 流 ID（下游 DTS 给出：IFE `0x840/0x860/0xA40/0xA60/0xC40/0xC60/0xE40/0xE60`，mask `0x620`；需换算成主线 `apps_smmu` 的写法）与 interconnect（`cam_ahb`、`cam_hf_*`、`cam_sf_*`）。
- 验收：连续抓 100 帧不丢帧，帧率符合预期（30fps 档）。

> Phase 2 是唯一可能"超预算"的阶段：如果 CSIPHY v1.1 或 VFE 175 的寄存器差异比预期大，需要额外 1–2 周。判断依据会在 2a 结束时就有。

### Phase 3：出图——libcamera 软件 ISP（1–2 周）

- 目标：让 GNOME Snapshot / `pipewire` 摄像头 / Firefox 能用。
- 动作：
  1. 确认 libcamera ≥ 0.6（Ubuntu 26.04 应满足），并启用软件 ISP pipeline（`simple` pipeline + CPU 去马赛克）。
  2. 在 libcamera 的 `camera_sensor_properties.cpp` 里加 OV8856 / OV13B10 条目（black level、CFA 排列、可用测试图案），必要时加 tuning file。
  3. 确认 `pipewire` 的 `libcamera` 插件能看到设备（`wpctl status` 里出现 Camera 节点）。
- 验收：`cam -l` 列出摄像头；`gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink` 出图；Snapshot 能拍照。
- 说明：软件 ISP 在骁龙 855 上跑 1080p 没问题，4K 会吃力；这是"能出图、颜色基本正确"的方案，不是"和 Android 一样好"。

### Phase 4：完善（1 周，可选）

- AF 马达（后摄，VAF 2.8V + CCI）、闪光灯（PM8150L flash/torch）、EEPROM 读取（用于 AWB/镜头阴影校准）、前后摄切换、suspend/resume、功耗。

---

## 五、关键风险与对策

| 风险 | 影响 | 概率 | 对策 |
|---|---|---|---|
| CSIPHY v1.1 与主线的 3ph-1.0 寄存器不兼容 | Phase 2a 卡住 | 中 | 先对照下游 `cam_csiphy_1_1.c` 的寄存器表；主线 `camss-csiphy-3ph-1-0.c` 已支持 845/8250 两代，新增一代的成本可控 |
| VFE/CSID 175 与 170 差异大于预期 | Phase 2c 延长 | 中 | 只做 RDI 直通路径（不走全 ISP），把需要移植的寄存器压到最少 |
| IOMMU 流 ID / interconnect 写错 | 抓帧时 IOMMU fault 或总线挂死 | 高（但易排查） | 用下游 DTS 的 SID 表逐个试；先 `iommu.passthrough=1` 验证链路，再收紧 |
| 电源时序（VANA 经 GPIO 开关） | 传感器 probe 失败/图像花屏 | 中 | Phase 1 就会暴露；必要时在 `regulator-fixed` 上加 `enable-active-high` + ramp delay，或在驱动里显式排序 |
| OV13B10 单电源驱动不够用 | 后摄 probe 失败 | 高（确定存在） | 移植上游 2026-04 的 "ov13b10: Support multiple regulators" v8 补丁（`dovdd/avdd/dvdd` 三路），改动约 50 行 |
| 无 EEPROM 校准数据 | 颜色/暗角一般 | 高 | 先用通用 AWB/CCM；后续加 EEPROM 驱动读取模组校准 |
| 维护成本：这是"树外"支持 | 内核升级要重做 | 中 | 尽量按上游风格写，边做边发 patch 到 linux-media，长期可进主线 |
| 时间成本 | 2–4 周甚至更久 | — | 分阶段验收，每阶段都有可回退点；Phase 1 就能判断值不值得继续 |

---

## 六、降级方案（如果不想投入这么多）

1. **只做前摄**：OV8856 驱动完整、链路简单（CSIPHY1→CSID1→VFE1），是"最快出图"的路径，工作量约为双摄的 60%。
2. **只要"能看到画面"**：Phase 2c 之后先用脚本抓 RAW 并用 `raw2rgb` 转 PNG，不接 libcamera，1 天内可验证成像质量。
3. **USB 摄像头过渡**：任何 UVC 摄像头在 Ubuntu 上即插即用；若近期有视频会议需求，这是零成本方案。
4. **借道 Android**：不改 Linux 相机栈，只在需要拍照时切回 Android（不推荐，但确实是"能用"的兜底）。

---

## 七、需要你配合的事项（切换系统时）

### 7.1 Ubuntu 侧（必须）

在 Ubuntu 里执行（脚本已放在工作区，纯只读采集，不修改系统）：

```bash
sudo bash tools/collect-camera-info.sh
# 生成 ~/camera-info-<日期>.tar.gz
```

脚本会收集：

| 项目 | 用途 |
|---|---|
| `uname -a`、`/proc/cmdline` | 确认内核版本与启动参数 |
| `/proc/config.gz`（或 `/boot/config-*`） | 确认 CAMSS/CCI/OV13B10/OV8856 是否编译 |
| `dmesg` 全文 | 找 camss/cci/csiphy/i2c 相关报错 |
| `/proc/device-tree/` 全量 | 确认实际生效的 DT（是否就是这棵树编的） |
| `media-ctl -p`、`v4l2-ctl --list-devices` | 确认 media 拓扑与 video 节点 |
| `ls /sys/bus/i2c/devices`、`i2cdetect -l` | 确认 CCI 总线是否注册 |
| `dpkg -l \| grep -E 'libcamera\|pipewire'`、`cam -l` | 确认用户态版本与能力 |
| `lsmod`、`/sys/kernel/debug/clk/clk_summary`（部分） | 确认模块加载与时钟状态 |

### 7.2 Android 侧（可选，但很有价值）

- 打开相机后 `adb shell dmesg > android-cam.log`（找 `cam_sensor`、`cci`、`csiphy` 的初始化序列，可作为我们 DT 参数的对照）。
- `adb shell "cat /proc/device-tree/qcom,csiphy@ac65000/..."` 或直接 dump `/sys/firmware/devicetree/base`，确认**实际运行的 dtbo** 与源码是否一致（小米经常在 dtbo 里覆盖参数）。
- 若方便，告诉我 vendor 分区里相机 HAL 的 sensor 库文件名（`/vendor/lib64/camera/`），可以反查 sensor 型号与 EEPROM 布局。

### 7.3 构建与刷机方式（必须确认）

- 你现在这个 Ubuntu 内核是**怎么编、怎么刷**的？（`fastboot flash linux ...`？还是替换 boot.img 里的 kernel/dtb？有没有用 `efi.tar` 里的 GRUB？）
- 是否有第二台 Linux 机器可用于交叉编译（还是只能在平板上 `make`）？
- 是否接受我提供"可回退"的测试内核（先备份当前 boot 分区）？

---

## 八、建议的下一步

**我建议从 Phase 1 开始，而不是直接写 CAMSS。** 理由：

1. 它能用最小代价验证 4 个高风险点（供电、MCLK、复位、CCI）；
2. 它是纯增量改动，出问题也不会影响你现在的系统；
3. 它产出的 DTS 片段是 Phase 2 的必要输入。

我可以在你确认后直接产出 Phase 1 的补丁（DTS 片段 + config 片段 + OV13B10 多电源补丁），你编译验证。如果 Phase 1 通过，我们再按 2a→2d 推进。

> 附：文件级改动清单、DTS 骨架草案与验证命令，见 [`camera-workplan-appendix.md`](./camera-workplan-appendix.md)。

---

## 九、实测结论（2026-10-31，SSH 实机确认）

设备 `10.210.131.x`，Ubuntu 26.04 (resolute)，内核 `6.14.11-nabu-tmm #2 SMP PREEMPT 2025-08-14`，8 核 / 5.2 GB 内存 / 118 GB 根分区。

| 项目 | 实测结果 | 影响 |
|---|---|---|
| `CONFIG_VIDEO_QCOM_CAMSS` | `=m`，模块已编译安装 | 驱动存在，但没有任何设备树节点可绑定 |
| `CONFIG_I2C_QCOM_CCI` | `=m` | 同上 |
| `CONFIG_SM_CAMCC_8150` | **未开启** | camcc 驱动不加载 → MCLK/CCI 时钟与 TITAN/IFE GDSC 全部不可用 |
| `CONFIG_VIDEO_OV8856` / `OV13B10` | **均未开启** | 两颗传感器驱动都不存在 |
| 设备树 | 无 camss / csiphy / cci 节点；`camcc@ad00000` 节点存在 | 与评估一致，需新增 |
| `/dev/video*`、`/dev/media*` | 不存在 | 系统里没有任何 V4L2 设备 |
| 用户态 | libcamera 0.7.0、libspa-0.2-libcamera 1.6.2、gstreamer1.0-libcamera、gnome-snapshot 均已安装；缺 v4l-utils / libcamera-tools | 出图链路已具备，只缺调试工具 |
| 启动链 | ESP（334 MB FAT32）+ rEFInd；内核以 **UKI** 形式放在 `EFI/ubuntu/*.efi`，内含 `.linux` / `.dtb` / `.cmdline` / `.uname`，**没有 initrd** | 换内核 = 用 `ukify` 重新打包并放到 ESP |
| 源码一致性 | 本工作区 6.14.11 树编出的 DTB 与在用的 `/boot/dtb-6.14.11-nabu-tmm` **不完全一致**：活体 DT 多出 idtp9418（无线充电/hall）节点，`ufs reset-names` 为 `core_reset`、wifi `freq-table-hz` 不同；其余节点集合一致 | 在跑的 6.14.11 与本树同源但带少量本地补丁；测试内核 DT 与驱动同源自洽即可启动，只会缺无线充电等次要功能 |

**结论修正**：路线不变，但 Phase 1 的配置清单与构建/刷机链路已经完全明确（见附录 G），并且设备已可通过 SSH 直接迭代，不需要你来回切换系统。

---

## 十、Phase 2 代码级复核：距抓 RAW 只差 3 个必修缺陷（2026-10-31 第二轮）

前提：`CAMSS_8150` 资源集（csiphy/csid/vfe）、`sm8150.dtsi` 的 camss + cci 节点、`nabu.dts` 的两颗 sensor 与 port 连接均已落地，`6.14.11-nabu-cam1` 能把全部子设备注册出来（Phase 1 通过）。

逐条对照 Android 下游头文件与 mainline 驱动后，确认以下缺陷（均可定位到行号）：

| # | 位置 | 问题 | 证据 | 后果 | 修法 |
|---|---|---|---|---|---|
| D1 | `camss-csiphy-3ph-1-0.c:563` `csiphy_is_gen2()` | `switch` 中没有 `CAMSS_8150`，返回 false | 分支只列 7280/8250/8280XP/845 | SM8150 落入 `csiphy_gen1_config_lanes()`，按 CSIPHY 1.0 的 LNn 布局写寄存器；CSIPHY 1.1 实际使用的 0x0/0x4/0x8/0x14/0x1C/0x2C/0x34/0x38/0x3C/0x60/0x64 全都没被配置 → PHY 出不了可用的 MIPI 时钟/数据 | 补 `case CAMSS_8150:` |
| D2 | 同文件 `:524` `csiphy_gen2_config_lanes()` | `CAMSS_8150` 分支用 `lane_regs_sm8250[5][20]` | Android `cam_csiphy_1_1_hwreg.h` 的 14 项与 `lane_regs_sc8280xp[5][14]` 逐条相同（0x0004=0x0C、0x002C=0x01、0x0034=0x0F、0x001C=0x0A、0x0014=0x60、0x003C=0xB8、0x0000=0x90、0x0008=settle 计数、0x0010=0x52、0x0038=0xFE、0x0060/0x0064）；sm8250 表项数与取值都不同 | settle 时间与均衡参数错误，D1 修好后仍大概率锁不住 | 改用 `lane_regs_sc8280xp` |
| D3 | `sm8150.dtsi:3830` camss `clocks` + `vfe_res_8150` | 缺 `GCC_CAMERA_HF_AXI_CLK` / `GCC_CAMERA_SF_AXI_CLK`；`vfe_res_8150` 的时钟表里也没有 `cam_hf_axi`（对比 `vfe_res_8250:1148`） | `gcc-sm8150.c:3489–3491` 已导出这两个时钟 | VFE 的 AXI 出帧通路时钟门控未开，写 RDI 帧到内存会挂死或无输出（典型现象：`v4l2-ctl --stream-mmap` 卡住、VFE 报 AXI/bus 错误） | DTS 补两路时钟，`vfe_res_8150` 补 `"cam_hf_axi"` |
| D4（非阻塞） | `sm8150.dtsi:3862` camss `iommus` | 没有 `interconnects` 投票 | 下游 cpas 显式 vote CAMNOC↔DDR；`sm8150_resources` 没有 `icc_res` | 低分辨率单帧 RAW 一般能过（NoC 默认带宽够）；高分辨率/连拍可能 timeout | Phase 3 再补 `icc_res` + DTS；先用 `iommu.passthrough=1` 摘掉 SMMU 变量 |

已核对为"可直接复用、不需要改"的部分：

- CSID 175 的 RDI 寄存器（0x40/0x44/0x48/0x4C + 0x100×rdi，RDI CFG 0x300+0x100×rdi）与 `csid_ops_gen2` 一致；
- VFE 175 的 CAMIF/RDI/IRQ/BUS 偏移与 `vfe_ops_170` 一致，`line_num = 4`（PIX + RDI0–2）对应 VFE175 的 3 路 RDI；
- CSIPHY 1.1 公共寄存器（0x800/0x814/0x818/0x81C、IRQ 0x82C–0x854）与 `csiphy_ops_3ph_1_0` 一致；
- `ov13b10.c:631` 已支持 `dovdd/avdd/dvdd` 三路电源（多电源补丁已在本树内），`link-frequencies = <560000000>` 与驱动的 `OV13B10_LINK_FREQ_560MHZ` 对齐。

**修正后的判断**：D1+D2+D3 修完就具备抓 RAW 的条件，每轮迭代成本 3–5 分钟（模块/DTB），预计 2–3 轮看到第一帧。前摄 OV8856（驱动成熟、单电源 360 MHz 链路）仍是最快的验证目标，后摄 OV13B10 紧随。

---

## 参考资料

- 上游 CAMSS 绑定（确认 SM8150 尚不存在）：[`qcom,sm8250-camss.yaml`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/Documentation/devicetree/bindings/media/qcom,sm8250-camss.yaml)（`qcom,sm8150-camss.yaml` 返回 404）
- OV13B10 多电源补丁（v8，2026-04）：[`[PATCH v8 2/2] media: ov13b10: Support multiple regulators`](https://lkml.iu.edu/hypermail/linux/kernel/2604.0/03234.html)
- libcamera 软件 ISP 现状（FOSDEM 2026）：[libcamera software ISP status update](https://fosdem.org/2026/events/attachments/TKSK3G-libcamera-softisp/slides/267491/libcamera_r0fvfbu.pdf)
- libcamera ISP 特性矩阵：[libcamera ISP Feature Support Matrix](https://docs.libcamera.org/master/isp-feature-matrix.html)

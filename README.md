# nabu-linux-camera

**Xiaomi Pad 5 (nabu) 的 Ubuntu/Linux 相机移植记录** · *Linux camera bring-up notes for the Xiaomi Pad 5 (nabu)*

> **状态：⏸ 已暂停（2026-10-31）**
> 设备已还原到调试前状态（测试内核、模块、源码均已删除），日常内核 `6.14.11-nabu-tmm` 正常使用。
> 本仓库保存完整的技术过程与补丁，**以后想重启项目时无需从头开始**。
>
> **Status: ⏸ Paused (2026-10-31)**
> The device has been fully restored (test kernel, modules and sources removed); the daily kernel `6.14.11-nabu-tmm` is in use. This repository keeps the full technical trail and patches so the work can be resumed without starting over.

---

## 中文

### 1. 这是什么

小米平板 5（代号 **nabu**，SoC **SM8150 / 骁龙 860**）在 Ubuntu 26.04 下相机不可用。本仓库记录了定位、移植与调试的完整过程：硬件事实、内核设备树与驱动改动、踩过的坑、构建/刷机流程，以及一个可直接应用的补丁。

相机在 Linux 下不可用的原因不是"缺个软件包"，而是**主线 6.14 的 Qualcomm CAMSS 驱动不支持 SM8150**（上游至今没有 `qcom,sm8150-camss` 绑定），同时设备树里完全没有 CCI/CAMSS/传感器节点。

### 2. 做到哪一步了

| 阶段 | 内容 | 状态 |
|---|---|---|
| Phase 0 | 实机诊断（内核配置、dmesg、设备树、UKI 启动链） | ✅ |
| Phase 1 | CCI 总线 + 双路供电 + MCLK/复位；`ov13b10` 与 `ov8856` 均 probe 成功 | ✅ 已验证 |
| Phase 2 | camss 驱动加入 SM8150 资源集 + 设备树节点，能 probe 出 `/dev/media0`、`/dev/video0..7` | ⚠️ 协议已打通，最后一版 WARN 修复未验证 |
| Phase 3 | libcamera softISP 出图 | ❌ 未开始 |

Phase 1 的验证结果：

```
/sys/bus/i2c/devices/3-0010 -> ov13b10   (CCI0 master0, 后摄)
/sys/bus/i2c/devices/4-0010 -> ov8856    (CCI0 master1, 前摄)
```

OV8856 在 probe 时会真实读取 chip ID（0x300A/0x300B），probe 成功即证明供电时序、MCLK、复位 GPIO、CCI 总线全部正确。

### 3. 硬件事实（从工厂设备树读出，已核实）

| 项目 | 后摄 | 前摄 |
|---|---|---|
| Sensor | OV13B10 @ 0x10 | OV8856 @ 0x10 |
| CCI | CCI0 master0 | CCI0 master1 |
| CSIPHY | CSIPHY0（0xac65000, IRQ 477） | CSIPHY1（0xac66000, IRQ 478） |
| MCLK | camcc MCLK0 / TLMM GPIO13 | camcc MCLK1 / TLMM GPIO14 |
| Reset | GPIO28（低有效） | GPIO30（低有效） |
| VANA 开关 | GPIO11 | GPIO31 |
| VIO 1.8V / VANA 3.0–4.0V | PM8150L LDO1 / PM8150L BOB | 同左 |
| VDIG 1.2V | PM8150L GPIO3 控制的固定 LDO | 同左 |
| Link freq | 560 MHz（4 lane） | 360/180 MHz（4 lane） |

SoC：CSID 0xacb3000 / 0xacba000（IRQ 464/466），VFE 0xacaf000 / 0xacb6000（IRQ 465/467），CCI0 0xac4a000（IRQ 460）。

### 4. 四个必须知道的坑

| 现象 | 根因 | 修法 |
|---|---|---|
| `CCI reset timeout` | CCI 只给了 `CCI_0_CLK`/`_SRC`，缺 AHB 类时钟 | 补 `CAMNOC_AXI`、`SLOW_AHB_SRC`、`CPAS_AHB`、`CORE_AHB` + `assigned-clock-rates`（80 MHz / 37.5 MHz） |
| 前摄 `master 1 queue 0 timeout` | CCI0 master1 用 GPIO19/20，pinctrl 只 mux 了 17/18 | `cci0_default` pins 加 `gpio19/20` |
| `ov13b10` 不 probe，bind 返回 EIO 且无日志 | 6.14 的 `ov13b10.c` **只有 ACPI match** | 加 `of_match_table`（`ovti,ov13b10`） |
| `ov8856: no link frequency ... supported` | 驱动要求 DT 列出该 lane 配置的**全部**表项 | 4-lane 写 `<360000000 180000000>` |

另外：`CONFIG_SM_CAMCC_8150=y` 是前提（相机时钟与 TITAN/IFE GDSC 都在这个驱动里）；VFE/CSIPHY 的 `switch (version)` 需要补 `CAMSS_8150` 分支。

### 5. 如何继续（恢复项目）

1. 阅读 [`docs/HANDOFF.md`](docs/HANDOFF.md)：完整现状、待验证清单、风险与命令。
2. 给干净的内核树打补丁：
   ```bash
   git apply docs/patches/nabu-camera-bringup.patch
   ```
   （补丁基于 `linux-sm8150-6.14.11`，即社区 nabu 内核树，7 个文件）
3. 按 HANDOFF 第 5 节的构建/部署流程重编：`CONFIG_SM_CAMCC_8150=y`、`OV8856`/`OV13B10`/`CAMSS`/`CCI` 打开，`LOCALVERSION` 用独立值，UKI 放 ESP。
4. 第一件事：确认 `dmesg` 里 `Unsupported HW version` WARN 已消失，`media-ctl -p` 看拓扑，然后尝试抓前摄 RAW。

### 6. 目录结构

```
README.md                          ← 本文件（中英双语）
docs/
  HANDOFF.md                       ← 交接报告：现状/待办/命令（最重要）
  camera-feasibility.md            ← 可行性评估（含实机结论）
  camera-workplan-appendix.md      ← DTS 全文、踩坑记录、构建流程
  patches/
    nabu-camera-bringup.patch      ← 7 个文件的完整改动
tools/
  collect-camera-info.sh           ← 设备侧只读诊断采集
  restore-device.sh                ← 一键撤销全部调试改动
```

### 7. 许可证与致谢

- 代码/补丁：GPL-2.0（见 [`LICENSE`](LICENSE)），与 Linux 内核一致。
- 文档：CC BY 4.0。
- 感谢社区 nabu 内核维护者（TheMojoMan 等）以及小米开源的 Android 内核设备树，本项目的硬件信息与基线内核均来自它们。

---

## English

### 1. What is this

The camera does not work on the Xiaomi Pad 5 (**nabu**, **SM8150 / Snapdragon 860**) under Ubuntu 26.04. This repository documents the full investigation and port: hardware facts, kernel device-tree and driver changes, pitfalls, build/flash workflow, and an apply-ready patch.

The root cause is not a missing package: **mainline 6.14's Qualcomm CAMSS driver has no SM8150 support** (there is still no `qcom,sm8150-camss` binding upstream), and the device tree contains no CCI/CAMSS/sensor nodes at all.

### 2. Progress

| Phase | Content | Status |
|---|---|---|
| 0 | On-device diagnosis (kernel config, dmesg, DT, UKI boot chain) | ✅ |
| 1 | CCI bus + sensor rails + MCLK/reset; both `ov13b10` and `ov8856` probe successfully | ✅ Verified |
| 2 | CAMSS resources for SM8150 + DT nodes; `/dev/media0` and `/dev/video0..7` appear | ⚠️ Plumbing works; last WARN fix unverified |
| 3 | libcamera softISP capture | ❌ Not started |

Phase 1 result:

```
/sys/bus/i2c/devices/3-0010 -> ov13b10   (CCI0 master0, rear)
/sys/bus/i2c/devices/4-0010 -> ov8856    (CCI0 master1, front)
```

OV8856 reads its chip ID (0x300A/0x300B) during probe, so a successful probe proves the power sequencing, MCLK, reset GPIO and CCI bus are all correct.

### 3. Hardware facts (from the vendor device tree, verified)

| Item | Rear | Front |
|---|---|---|
| Sensor | OV13B10 @ 0x10 | OV8856 @ 0x10 |
| CCI | CCI0 master0 | CCI0 master1 |
| CSIPHY | CSIPHY0 (0xac65000, IRQ 477) | CSIPHY1 (0xac66000, IRQ 478) |
| MCLK | camcc MCLK0 / TLMM GPIO13 | camcc MCLK1 / TLMM GPIO14 |
| Reset | GPIO28 (active low) | GPIO30 (active low) |
| VANA switch | GPIO11 | GPIO31 |
| VIO 1.8V / VANA 3.0–4.0V | PM8150L LDO1 / PM8150L BOB | same |
| VDIG 1.2V | fixed LDO gated by PM8150L GPIO3 | same |
| Link freq | 560 MHz (4 lanes) | 360/180 MHz (4 lanes) |

SoC: CSID 0xacb3000 / 0xacba000 (IRQ 464/466), VFE 0xacaf000 / 0xacb6000 (IRQ 465/467), CCI0 0xac4a000 (IRQ 460).

### 4. Four pitfalls worth knowing

| Symptom | Root cause | Fix |
|---|---|---|
| `CCI reset timeout` | CCI lacked AHB-class clocks, register access never worked | add `CAMNOC_AXI`, `SLOW_AHB_SRC`, `CPAS_AHB`, `CORE_AHB` + `assigned-clock-rates` (80/37.5 MHz) |
| Front sensor `master 1 queue 0 timeout` | CCI0 master1 uses GPIO19/20 but pinctrl only muxed 17/18 | extend `cci0_default` pins |
| `ov13b10` never probes, bind returns EIO with no log | 6.14 `ov13b10.c` has **ACPI match only** | add `of_match_table` (`ovti,ov13b10`) |
| `ov8856: no link frequency ... supported` | driver requires **all** link frequencies of the chosen lane config | 4-lane: `<360000000 180000000>` |

Also: `CONFIG_SM_CAMCC_8150=y` is mandatory (camera clocks and TITAN/IFE GDSCs live there), and the VFE/CSIPHY `switch (version)` blocks need a `CAMSS_8150` case.

### 5. How to resume

1. Read [`docs/HANDOFF.md`](docs/HANDOFF.md) — current state, verification checklist, risks and commands.
2. Apply the patch to a clean `linux-sm8150-6.14.11` tree:
   ```bash
   git apply docs/patches/nabu-camera-bringup.patch
   ```
3. Rebuild following HANDOFF section 5: enable `CONFIG_SM_CAMCC_8150=y`, `OV8856`, `OV13B10`, `CAMSS`, `CCI`, use a dedicated `LOCALVERSION`, package the kernel as a UKI on the ESP.
4. First step: confirm the `Unsupported HW version` WARN is gone, inspect `media-ctl -p`, then try a front-camera RAW capture.

### 6. Layout

```
README.md                          ← this file (bilingual)
docs/
  HANDOFF.md                       ← hand-off report: state / TODOs / commands (start here)
  camera-feasibility.md            ← feasibility assessment with on-device findings
  camera-workplan-appendix.md      ← full DTS, pitfalls, build workflow
  patches/
    nabu-camera-bringup.patch      ← complete 7-file diff
tools/
  collect-camera-info.sh           ← read-only diagnostics collector (device side)
  restore-device.sh                ← one-shot rollback of all debug changes
```

### 7. License & credits

- Code/patches: GPL-2.0 (see [`LICENSE`](LICENSE)), matching the Linux kernel.
- Documentation: CC BY 4.0.
- Thanks to the nabu community kernel maintainers (TheMojoMan and others) and Xiaomi's open-source Android kernel device trees; both the hardware information and the baseline kernel come from them.

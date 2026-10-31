# 附录：改动清单、DTS/驱动草案与验证命令

> 配套文档：[相机修复可行性评估](./camera-feasibility.md)
> 状态说明：Phase 1 已在真实设备上验证通过（见"Phase 1 实测记录"）；Phase 2 的代码仍是草案。

---

## A. 文件级改动清单

### A.1 内核（`linux-sm8150-6.14.11`）

| 文件 | 改动 | 阶段 | 状态 |
|---|---|---|---|
| `arch/arm64/boot/dts/qcom/sm8150.dtsi` | 新增 `cci: i2c@ac4a000`（含 master0/1 两条 i2c 总线） | 1 | ✅ 已验证 |
| `arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dts` | 相机 regulator（VIO/VANA/VDIG）、pinctrl（MCLK0/1、reset、CCI 0/1 四根线）、`ov13b10@10`、`ov8856@10` | 1 | ✅ 已验证 |
| `drivers/media/i2c/ov13b10.c` | ① 单 `avdd` → `dovdd/avdd/dvdd` 三路（上游 v8 补丁）；② **新增 OF match table**（6.14 只有 ACPI match） | 1 | ✅ 已验证 |
| `drivers/media/i2c/ov8856.c` | 无需改动 | 1 | ✅ |
| `drivers/media/platform/qcom/camss/camss.c` | 新增 `csiphy_res_8150` / `csid_res_8150` / `vfe_res_8150` / `sm8150_resources` + `CAMSS_8150` 枚举 | 2 | ⏳ 待写 |
| `drivers/i2c/busses/i2c-qcom-cci.c` | 可选：新增 `qcom,sm8150-cci` 兼容 | 1 | 可复用 `sm8250-cci`，暂不需要 |
| `.config` | 打开 CAMSS/CCI/OV13B10/OV8856/SM_CAMCC_8150 | 1 | ✅ 已验证 |

### A.2 用户态（Ubuntu 内）

| 项目 | 改动 | 阶段 |
|---|---|---|
| libcamera | 已装 0.7.0（自带 softISP）；Phase 3 可能需补 sensor properties/tuning | 3 |
| PipeWire | 已装 1.6.2 + `libspa-0.2-libcamera` | 3 |
| 调试工具 | 建议 `apt install v4l-utils i2c-tools libcamera-tools` | 1 |

---

## B. Phase 1 DTS（已实测可用）

### B.1 `sm8150.dtsi` 里的 CCI 节点

```dts
cci: i2c@ac4a000 {
	compatible = "qcom,sm8250-cci";
	reg = <0 0x0ac4a000 0 0x1000>;
	#address-cells = <1>;
	#size-cells = <0>;
	interrupts = <GIC_SPI 460 IRQ_TYPE_EDGE_RISING>;
	power-domains = <&camcc TITAN_TOP_GDSC>;
	clocks = <&camcc CAM_CC_CAMNOC_AXI_CLK>,
		 <&camcc CAM_CC_SLOW_AHB_CLK_SRC>,
		 <&camcc CAM_CC_CPAS_AHB_CLK>,
		 <&camcc CAM_CC_CORE_AHB_CLK>,
		 <&camcc CAM_CC_CCI_0_CLK>,
		 <&camcc CAM_CC_CCI_0_CLK_SRC>;
	clock-names = "camnoc_axi", "slow_ahb_src", "cpas_ahb",
		      "core_ahb", "cci", "cci_src";
	assigned-clocks = <&camcc CAM_CC_CAMNOC_AXI_CLK>,
			  <&camcc CAM_CC_CCI_0_CLK>;
	assigned-clock-rates = <80000000>, <37500000>;
	status = "disabled";

	cci_i2c0: i2c-bus@0 {
		reg = <0>;
		clock-frequency = <400000>;
		#address-cells = <1>;
		#size-cells = <0>;
	};

	cci_i2c1: i2c-bus@1 {
		reg = <1>;
		clock-frequency = <400000>;
		#address-cells = <1>;
		#size-cells = <0>;
	};
};
```

> 只给 `CAM_CC_CCI_0_CLK`/`_CLK_SRC` 会得到 `CCI reset timeout`；AHB 类时钟是必须的。

### B.2 nabu dts 里的供电、pinctrl 与传感器

```dts
/ {
	vreg_cam_vdig: regulator-cam-vdig {
		compatible = "regulator-fixed";
		regulator-name = "cam_vdig";
		regulator-min-microvolt = <1200000>;
		regulator-max-microvolt = <1200000>;
		regulator-enable-ramp-delay = <135>;
		enable-active-high;
		gpio = <&pm8150l_gpios 3 GPIO_ACTIVE_HIGH>;
		vin-supply = <&vreg_s4a_1p8>;
	};

	vreg_cam_vana_rear: regulator-cam-vana-rear {
		compatible = "regulator-fixed";
		regulator-name = "cam_vana_rear";
		regulator-min-microvolt = <3008000>;
		regulator-max-microvolt = <3008000>;
		regulator-enable-ramp-delay = <135>;
		enable-active-high;
		gpio = <&tlmm 11 GPIO_ACTIVE_HIGH>;
		vin-supply = <&vreg_bob>;
	};

	vreg_cam_vana_front: regulator-cam-vana-front {
		compatible = "regulator-fixed";
		regulator-name = "cam_vana_front";
		regulator-min-microvolt = <3008000>;
		regulator-max-microvolt = <3008000>;
		regulator-enable-ramp-delay = <135>;
		enable-active-high;
		gpio = <&tlmm 31 GPIO_ACTIVE_HIGH>;
		vin-supply = <&vreg_bob>;
	};
};

&tlmm {
	cam_sensor_mclk0_active: cam-sensor-mclk0-active {
		pins = "gpio13";
		function = "cam_mclk";
		drive-strength = <2>;
		bias-disable;
	};
	cam_sensor_mclk0_suspend: cam-sensor-mclk0-suspend {
		pins = "gpio13";
		function = "cam_mclk";
		drive-strength = <2>;
		bias-pull-down;
	};
	cam_sensor_mclk1_active: cam-sensor-mclk1-active {
		pins = "gpio14";
		function = "cam_mclk";
		drive-strength = <2>;
		bias-disable;
	};
	cam_sensor_mclk1_suspend: cam-sensor-mclk1-suspend {
		pins = "gpio14";
		function = "cam_mclk";
		drive-strength = <2>;
		bias-pull-down;
	};
	cam_sensor_rear_reset: cam-sensor-rear-reset {
		pins = "gpio28";
		function = "gpio";
		drive-strength = <2>;
		bias-disable;
		output-low;
	};
	cam_sensor_front_reset: cam-sensor-front-reset {
		pins = "gpio30";
		function = "gpio";
		drive-strength = <2>;
		bias-disable;
		output-low;
	};
	/* CCI0 的 master0(17/18) 与 master1(19/20) 都要 mux 成 cci_i2c */
	cci0_default: cci0-default {
		pins = "gpio17", "gpio18", "gpio19", "gpio20";
		function = "cci_i2c";
		drive-strength = <2>;
		bias-disable;
	};
};

&cci {
	status = "okay";
	pinctrl-names = "default";
	pinctrl-0 = <&cci0_default>;
};

&cci_i2c0 {
	ov13b10: camera@10 {
		compatible = "ovti,ov13b10";
		reg = <0x10>;
		clock-frequency = <19200000>;
		clocks = <&camcc CAM_CC_MCLK0_CLK>;
		assigned-clocks = <&camcc CAM_CC_MCLK0_CLK>;
		assigned-clock-rates = <19200000>;
		reset-gpios = <&tlmm 28 GPIO_ACTIVE_LOW>;
		pinctrl-names = "default", "standby";
		pinctrl-0 = <&cam_sensor_mclk0_active &cam_sensor_rear_reset>;
		pinctrl-1 = <&cam_sensor_mclk0_suspend &cam_sensor_rear_reset>;
		dovdd-supply = <&vreg_l1c_1p8>;
		avdd-supply = <&vreg_cam_vana_rear>;
		dvdd-supply = <&vreg_cam_vdig>;
		status = "okay";

		port {
			ov13b10_ep: endpoint {
				clock-lanes = <0>;
				data-lanes = <1 2 3 4>;
				link-frequencies = /bits/ 64 <560000000>;
			};
		};
	};
};

&cci_i2c1 {
	ov8856: camera@10 {
		compatible = "ovti,ov8856";
		reg = <0x10>;
		clock-frequency = <19200000>;
		clocks = <&camcc CAM_CC_MCLK1_CLK>;
		clock-names = "xvclk";
		assigned-clocks = <&camcc CAM_CC_MCLK1_CLK>;
		assigned-clock-rates = <19200000>;
		reset-gpios = <&tlmm 30 GPIO_ACTIVE_LOW>;
		pinctrl-names = "default", "standby";
		pinctrl-0 = <&cam_sensor_mclk1_active &cam_sensor_front_reset>;
		pinctrl-1 = <&cam_sensor_mclk1_suspend &cam_sensor_front_reset>;
		dovdd-supply = <&vreg_l1c_1p8>;
		avdd-supply = <&vreg_cam_vana_front>;
		dvdd-supply = <&vreg_cam_vdig>;
		status = "okay";

		port {
			ov8856_ep: endpoint {
				clock-lanes = <0>;
				data-lanes = <1 2 3 4>;
				/* 4-lane 配置的全部表项都必须列出 */
				link-frequencies = /bits/ 64 <360000000 180000000>;
			};
		};
	};
};
```

---

## C. Phase 2 camss 资源草案（`camss.c`，未验证）

```c
/* 数值来自下游 sm8150-camera.dtsi，需逐项核对 */
static const struct camss_subdev_resources csiphy_res_8150[] = {
	/* CSIPHY0 */
	{
		.regulators = { "vdda-phy", "vdda-pll" },
		.clock = { "csiphy0", "csiphy0_timer" },
		.clock_rate = { { 400000000 }, { 300000000 } },
		.reg = { "csiphy0" },
		.interrupt = { "csiphy0" },
		.csiphy = {
			.hw_ops = &csiphy_ops_3ph_1_0,	/* 待与下游 v1.1 对照 */
			.formats = &csiphy_formats_sdm845,
		},
	},
	/* CSIPHY1..3 同理 */
};

static const struct camss_subdev_resources csid_res_8150[] = {
	/* CSID0 */
	{
		.clock = { "cpas_ahb", "vfe0_cphy_rx", "vfe0",
			   "vfe0_csid", "slow_ahb_src", "camnoc_axi" },
		.clock_rate = { { 80000000 }, { 400000000 }, { 400000000 },
				{ 480000000 }, { 80000000 }, { 0 } },
		.reg = { "csid0" },
		.interrupt = { "csid0" },
		.csid = {
			.hw_ops = &csid_ops_gen2,
			.parent_dev_ops = &vfe_parent_dev_ops,
			.formats = &csid_formats_gen2,
		},
	},
	/* CSID1、CSID lite0/1 */
};

static const struct camss_subdev_resources vfe_res_8150[] = {
	/* VFE0 */
	{
		.clock = { "camnoc_axi", "cpas_ahb", "slow_ahb_src",
			   "vfe0", "vfe0_axi", "vfe0_src" },
		.clock_rate = { { 0 }, { 80000000 }, { 80000000 },
				{ 19200000, 400000000, 558000000, 760000000 },
				{ 0 }, { 400000000 } },
		.reg = { "vfe0" },
		.interrupt = { "vfe0" },
		.vfe = {
			.line_num = 4,
			.has_pd = true,
			.pd_name = "ife0",
			.hw_ops = &vfe_ops_170,	/* 待与下游 vfe175 对照 */
			.formats_rdi = &vfe_formats_rdi_845,
			.formats_pix = &vfe_formats_pix_845,
		},
	},
	/* VFE1、VFE lite0/1 */
};

static const struct camss_resources sm8150_resources = {
	.version = CAMSS_8150,		/* 新增枚举 */
	.pd_name = "top",
	.csiphy_res = csiphy_res_8150,
	.csid_res = csid_res_8150,
	.vfe_res = vfe_res_8150,
	.csiphy_num = ARRAY_SIZE(csiphy_res_8150),
	.csid_num = ARRAY_SIZE(csid_res_8150),
	.vfe_num = ARRAY_SIZE(vfe_res_8150),
	.link_entities = camss_link_entities,
};
```

要点：

- **CSID 用独立 reg**（不像 SM8250 那样从 VFE 基址 + 偏移算），因为 SM8150 的 CSID 与 VFE 基址不同（0xacb3000 vs 0xacaf000）。`msm_csid_subdev_init()` 中非 `CAMSS_8250` 走 `devm_platform_ioremap_resource_byname()`。
- **电源域**沿用 SM8250 的 `has_pd/pd_name="ife0"/"ife1"` + `res->pd_name="top"`，对应 `camcc-sm8150` 的 `IFE_0_GDSC`/`IFE_1_GDSC`/`TITAN_TOP_GDSC`（已验证这些 genpd 存在于 `/sys/kernel/debug/pm_genpd/`）。
- **IOMMU**：下游 `msm_cam_smmu_ife` 的 SID 列表（0x840/0x860/0xA40/0xA60/0xC40/0xC60/0xE40/0xE60，mask 0x620），先开 `iommu.passthrough=1` 验证链路再收紧。
- **interconnect**：`sm8150.dtsi` 已有 `config_noc`/`mmss_noc`/`camnoc_virt`，按 SM8250 写法填 `cam_ahb`/`cam_hf_*`/`cam_sf_*`。

---

## D. 已应用的驱动补丁

### D.1 OV13B10 多电源（搬上游 v8）

```c
static const char * const ov13b10_supply_names[] = {
	"dovdd",	/* Digital I/O —— nabu: VIO 1.8V */
	"avdd",		/* Analog      —— nabu: VANA 3.0~4.0V */
	"dvdd",		/* Digital core —— nabu: VDIG 1.2V */
};
```

`regulator_enable/disable` → `regulator_bulk_enable/disable`；`devm_regulator_get_optional("avdd")` → `devm_regulator_bulk_get()`。

### D.2 OV13B10 增加 OF match（6.14 缺失，必须补）

```c
static const struct of_device_id ov13b10_of_ids[] = {
	{ .compatible = "ovti,ov13b10" },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, ov13b10_of_ids);

static struct i2c_driver ov13b10_i2c_driver = {
	.driver = {
		.name = "ov13b10",
		.pm = pm_ptr(&ov13b10_pm_ops),
		.acpi_match_table = ACPI_PTR(ov13b10_acpi_ids),
		.of_match_table = ov13b10_of_ids,
	},
	...
};
```

没有这段时，手动 `bind` 会返回 EIO 且 dmesg 无任何输出，非常难查。

---

## E. 内核配置片段（已验证）

```text
CONFIG_MEDIA_SUPPORT=m
CONFIG_MEDIA_CONTROLLER=y
CONFIG_VIDEO_V4L2_SUBDEV_API=y
CONFIG_MEDIA_PLATFORM_DRIVERS=y
CONFIG_VIDEO_QCOM_CAMSS=m
CONFIG_I2C_QCOM_CCI=m
CONFIG_VIDEO_OV8856=m
CONFIG_VIDEO_OV13B10=m
CONFIG_SM_CAMCC_8150=y
CONFIG_INTERCONNECT_QCOM_SM8150=y
CONFIG_QCOM_GDSC=y
CONFIG_QCOM_RPMHPD=y
CONFIG_IOMMU_SUPPORT=y
CONFIG_IOMMU_IO_PGTABLE_LPAE=y
```

---

## F. 验证命令

### Phase 1（已通过）

```bash
ls -d /sys/bus/i2c/devices/*-0010
for d in /sys/bus/i2c/devices/*-0010; do echo "$d -> $(basename $(readlink -f $d/driver))"; done
# 期望：3-0010 -> ov13b10，4-0010 -> ov8856
dmesg | grep -iE 'cci|ov13|ov8856'
```

### Phase 2（抓 RAW）

```bash
media-ctl -p -d /dev/media0
v4l2-ctl --list-devices
v4l2-ctl -d /dev/video0 --set-fmt-video=width=3264,height=2448,pixelformat=BG10 \
         --stream-mmap --stream-count=10 --stream-to=/tmp/frame.raw
```

### Phase 3（出图）

```bash
cam -l
gst-launch-1.0 libcamerasrc ! videoconvert ! autovideosink
```

---

## Phase 1 实测记录（2026-10-31，已成功）

测试内核 `6.14.11-nabu-cam1`（DT 与驱动同源，UKI 放在 ESP），四轮迭代后两颗传感器**全部 probe 成功**：

```
/sys/bus/i2c/devices/3-0010 -> ov13b10     (CCI0 master0)
/sys/bus/i2c/devices/4-0010 -> ov8856      (CCI0 master1)
```

ov8856 在 probe 阶段会真实读 chip ID（0x300A/0x300B），probe 成功即证明**供电、MCLK、复位、CCI 全部正确**。

### 1. 踩到的四个坑

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | `i2c-qcom-cci ac4a000.i2c: CCI reset timeout` | 只给了 `CCI_0_CLK`/`CCI_0_CLK_SRC`，缺 AHB 类时钟 | 补 `CAMNOC_AXI`、`SLOW_AHB_SRC`、`CPAS_AHB`、`CORE_AHB`，并设 `assigned-clock-rates`（camnoc 80 MHz / cci 37.5 MHz） |
| 2 | `master 1 queue 0 timeout`（前摄无响应） | CCI0 的 master1 用 GPIO19/20，pinctrl 只 mux 了 GPIO17/18 | `cci0_default` 的 pins 加上 `gpio19`、`gpio20` |
| 3 | ov13b10 根本不 probe（bind 返回 EIO、无日志） | 6.14 的 `ov13b10.c` 只有 ACPI match | 新增 `of_match_table`（`ovti,ov13b10`） |
| 4 | `ov8856: no link frequency 360000000 supported` → 改 720M 后又报 180M | 驱动要求 DT `link-frequencies` 包含该 lane 配置的**全部**表项 | 4-lane 用 `<360000000 180000000>` |

### 2. 现在的状态

- Phase 1 ✅：CCI 总线、两路供电、MCLK、复位、两颗 sensor 的 I2C 全部打通。
- 仍无 `/dev/video*`：没有 CAMSS（CSIPHY/CSID/VFE）节点与驱动支持，sensor 只是孤立 subdev。
- Phase 2 需要：`camss.c` 增加 `SM8150` 资源集 + `sm8150.dtsi` 增加 camss/csiphy 节点 + IOMMU/interconnect 描述。

### 3. 迭代方式（约 5 分钟一轮）

```bash
# 只改 DTS：重编 dtb + 重打 UKI，不用重编内核
make -j6 qcom/sm8150-xiaomi-nabu.dtb
ukify build --linux=arch/arm64/boot/Image \
  --devicetree=arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb \
  --cmdline="root=PARTLABEL=linux rw fw_devlink=permissive" \
  --uname="6.14.11-nabu-cam1" --os-release=@/etc/os-release \
  --output=/tmp/6.14.11-nabu-cam1.efi
# 挂 ESP、覆盖 EFI/ubuntu/6.14.11-cam1.efi、重启

# 只改驱动模块（如 ov13b10.c）
make -j6 modules && sudo make modules_install INSTALL_MOD_PATH=/ && sudo depmod -a 6.14.11-nabu-cam1
```

---

## G. 构建与刷机（已实测打通）

### G.1 设备的真实启动链

```
ESP (sda31, FAT32, 334MB)
└── EFI/BOOT/bootaa64.efi        rEFInd
    EFI/ubuntu/6.14.11.efi       UKI：.linux(31MB Image) + .dtb + .cmdline + .uname
    EFI/ubuntu/6.14.11-cam1.efi  测试内核
    EFI/ubuntu/6.17.0-...efi
```

- 命令行 `root=PARTLABEL=linux rw fw_devlink=permissive`，**没有 initramfs**。
- `/boot/vmlinuz-*`、`/boot/dtb-*` 只是留档，真正生效的是 ESP 里的 UKI。

### G.2 设备上的构建环境（已装好）

```bash
sudo apt-get install -y --no-install-recommends build-essential bison flex \
    libssl-dev libelf-dev device-tree-compiler kmod rsync cpio zstd xz-utils
# gcc 15.2.0, make 4.4.1, dtc 1.7.2, ukify(systemd 259)
```

源码在 `/home/xiany/kbuild/linux-sm8150-6.14.11`，`.config` 取自设备 `/proc/config.gz`。

### G.3 构建命令

```bash
cd /home/xiany/kbuild/linux-sm8150-6.14.11
zcat /proc/config.gz > .config
scripts/config --set-str LOCALVERSION "-nabu-cam1"
scripts/config --disable LOCALVERSION_AUTO
scripts/config --enable SM_CAMCC_8150
scripts/config --module VIDEO_OV8856
scripts/config --module VIDEO_OV13B10
make -j6 olddefconfig
make -j6 Image modules        # 8 核 / 5.2GB，约 22 分钟
```

### G.4 打包 UKI 并安装

```bash
ukify build \
  --linux=arch/arm64/boot/Image \
  --devicetree=arch/arm64/boot/dts/qcom/sm8150-xiaomi-nabu.dtb \
  --cmdline="root=PARTLABEL=linux rw fw_devlink=permissive" \
  --uname="6.14.11-nabu-cam1" \
  --os-release=@/etc/os-release \
  --output=/tmp/6.14.11-cam1.efi

sudo make modules_install INSTALL_MOD_PATH=/
sudo depmod 6.14.11-nabu-cam1

sudo mount /dev/disk/by-partlabel/esp /mnt/esp
sudo cp /tmp/6.14.11-cam1.efi /mnt/esp/EFI/ubuntu/
sync && sudo umount /mnt/esp
```

### G.5 回退方式

- 不覆盖任何旧文件，只新增条目；重启进 rEFInd 选回 `6.14.11` 即可。
- 模块在独立的 `/lib/modules/6.14.11-nabu-cam1`，不影响原系统。

### G.6 注意：源码与在跑内核存在少量差异

在跑的 `6.14.11-nabu-tmm` 的 DT 比本树多出 idtp9418（无线充电/hall）节点，且 `ufs reset-names`、wifi `freq-table-hz` 等属性不同。测试内核 DT 与驱动同源自洽，能正常启动，但会缺无线充电等次要功能——测试内核不要当日常内核用。

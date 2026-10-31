#!/bin/bash
# collect-camera-info.sh
# 在 Ubuntu (xiaomi-nabu) 上采集相机相关诊断信息，只读，不修改系统。
# 用法:  sudo bash tools/collect-camera-info.sh
# 产出:  ~/camera-info-<时间戳>.tar.gz
#
# 说明: 需要 root 才能完整读取 dmesg 与 /sys/kernel/debug。非 root 也能运行，
#       但部分内容会缺失（脚本会在日志里说明）。

set -u

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="${HOME}/camera-info-${STAMP}"
mkdir -p "${OUT}"/{config,dmesg,devicetree,media,i2c,debugfs,userspace,storage}
LOG="${OUT}/collection.log"

say() { echo "[collect] $*" | tee -a "${LOG}"; }
cap() { # cap <相对路径> <命令...>
    local f="${OUT}/$1"; shift
    { echo "### CMD: $*"; echo "### TIME: $(date -Is)"; echo; "$@" 2>&1; echo; } >> "${f}"
}
capsh() { # capsh <相对路径> <shell 片段>
    local f="${OUT}/$1"; shift
    { echo "### SH: $*"; echo; sh -c "$*" 2>&1; echo; } >> "${f}"
}

say "输出目录: ${OUT}"
say "内核: $(uname -a)"

# ---------- 0. 基本信息 ----------
cap system.txt sh -c 'uname -a; echo; cat /etc/os-release; echo; cat /proc/cmdline; echo; free -h; echo; nproc'
cap system.txt sh -c 'echo "--- mounts ---"; findmnt -o TARGET,SOURCE,FSTYPE,SIZE,USED 2>/dev/null; echo; echo "--- partitions ---"; cat /proc/partitions'
cap storage.txt sh -c 'lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINT 2>/dev/null; echo; ls -l /dev/disk/by-partlabel 2>/dev/null'

# ---------- 1. 内核配置 ----------
if [ -r /proc/config.gz ]; then
    zcat /proc/config.gz > "${OUT}/config/kernel.config" 2>/dev/null
    say "已读取 /proc/config.gz"
elif [ -r "/boot/config-$(uname -r)" ]; then
    cp "/boot/config-$(uname -r)" "${OUT}/config/kernel.config"
    say "已读取 /boot/config-$(uname -r)"
else
    say "警告: 找不到内核配置（/proc/config.gz 与 /boot/config-* 都不可读）"
fi
if [ -s "${OUT}/config/kernel.config" ]; then
    grep -E 'CAMSS|CCI|OV13B10|OV8856|MEDIA|V4L2|IOMMU|INTERCONNECT|QCOM_GDSC|RPMHPD|CAMCC' \
        "${OUT}/config/kernel.config" > "${OUT}/config/camera-relevant.txt"
fi

# ---------- 2. dmesg ----------
if dmesg > "${OUT}/dmesg/full.txt" 2>/dev/null && [ -s "${OUT}/dmesg/full.txt" ]; then
    say "dmesg 已采集"
else
    say "警告: dmesg 采集失败（可能是 dmesg_restrict=1 或非 root）"
    echo "dmesg 不可读（非 root 或 dmesg_restrict=1）" > "${OUT}/dmesg/full.txt"
fi
grep -iE 'cam|cci|csiphy|csid|vfe|ov8856|ov13b10|i2c|smmu|iommu|regulator' \
    "${OUT}/dmesg/full.txt" > "${OUT}/dmesg/filtered.txt" 2>/dev/null

# ---------- 3. 设备树 ----------
if [ -d /proc/device-tree ]; then
    # 用 tar 打包最稳妥，能保留属性文件名
    tar -czhf "${OUT}/devicetree/device-tree.tar.gz" -C /proc device-tree 2>/dev/null \
        || say "警告: 设备树打包失败（可忽略）"
    cat /proc/device-tree/model > "${OUT}/devicetree/model.txt" 2>/dev/null
    ls /proc/device-tree > "${OUT}/devicetree/top-level.txt" 2>/dev/null
    say "设备树已采集"
else
    say "警告: 没有 /proc/device-tree"
fi

# ---------- 4. media / v4l2 拓扑 ----------
have() { command -v "$1" >/dev/null 2>&1; }

if have media-ctl; then
    for m in /dev/media*; do
        [ -e "$m" ] || continue
        cap "media/$(basename "$m").txt" media-ctl -p -d "$m"
    done
    say "media-ctl 拓扑已采集"
else
    say "提示: 未安装 media-ctl（v4l-utils），跳过拓扑（建议 apt install v4l-utils）"
fi

if have v4l2-ctl; then
    cap media/v4l2-devices.txt v4l2-ctl --list-devices
    for v in /dev/video*; do
        [ -e "$v" ] || continue
        cap "media/$(basename "$v")-all.txt" v4l2-ctl -d "$v" --all
        cap "media/$(basename "$v")-formats.txt" v4l2-ctl -d "$v" --list-formats-ext
    done
    say "v4l2 设备已采集"
else
    say "提示: 未安装 v4l2-ctl（v4l-utils），跳过"
fi
capsh media/sysfs.txt 'ls -l /sys/class/video4linux/ 2>/dev/null; echo; ls -l /sys/class/media/ 2>/dev/null; echo; for d in /sys/class/video4linux/*; do [ -e "$d" ] || continue; echo "== $d"; cat "$d/name" 2>/dev/null; done'

# ---------- 5. I2C / CCI ----------
if have i2cdetect; then
    cap i2c/i2cdetect-list.txt i2cdetect -l
    # 只探测名字里带 cci 的总线，避免误碰 PMIC 总线
    i2cdetect -l 2>/dev/null | grep -i cci | while read -r bus _; do
        n=${bus#i2c-}
        cap "i2c/i2cdetect-bus-${n}.txt" i2cdetect -y -r "$n" 2>&1
    done
    say "i2cdetect 已采集"
else
    say "提示: 未安装 i2cdetect（i2c-tools），跳过"
fi
capsh i2c/sysfs.txt 'ls -l /sys/bus/i2c/devices/ 2>/dev/null; echo; for d in /sys/bus/i2c/devices/*; do [ -e "$d" ] || continue; echo "== $d: $(cat "$d/name" 2>/dev/null)"; done'

# ---------- 6. debugfs（时钟/电源/GPIO/中断） ----------
if [ -d /sys/kernel/debug ]; then
    capsh debugfs/clocks.txt 'grep -iE "cam|csi|cci|mclk" /sys/kernel/debug/clk/clk_summary 2>/dev/null | head -n 200'
    capsh debugfs/regulators.txt 'cat /sys/kernel/debug/regulator/regulator_summary 2>/dev/null | head -n 200'
    capsh debugfs/gpio.txt 'cat /sys/kernel/debug/gpio 2>/dev/null'
    capsh debugfs/pinctrl.txt 'ls /sys/kernel/debug/pinctrl 2>/dev/null'
    capsh debugfs/pm.txt 'ls /sys/kernel/debug/pm_genpd 2>/dev/null; cat /sys/kernel/debug/pm_genpd/*/status 2>/dev/null'
    say "debugfs 已采集（若为空，多为非 root 或未挂载 debugfs）"
else
    say "警告: /sys/kernel/debug 不存在（debugfs 未挂载）"
fi
capsh debugfs/interrupts.txt 'cat /proc/interrupts; echo; grep -iE "cam|cci|csi" /proc/interrupts'

# ---------- 7. 模块与用户态 ----------
cap userspace/modules.txt sh -c 'lsmod; echo; for m in qcom_camss i2c_qcom_cci ov8856 ov13b10; do echo "== modinfo $m"; modinfo "$m" 2>&1 | head -n 20; done'
capsh userspace/packages.txt 'dpkg -l 2>/dev/null | grep -iE "libcamera|pipewire|gstreamer|v4l-utils" '
cap userspace/cam-list.txt sh -c 'command -v cam >/dev/null 2>&1 && cam -l || echo "cam (libcamera-tools) 未安装"'
cap userspace/pipewire.txt sh -c 'command -v wpctl >/dev/null 2>&1 && wpctl status || echo "wpctl 未安装/未运行"'
capsh userspace/v4l2-extra.txt 'ls -l /dev/v4l/by-id/ 2>/dev/null; echo; ls -l /dev/v4l/by-path/ 2>/dev/null'

# ---------- 8. 打包 ----------
if [ "$(id -u)" -ne 0 ]; then
    say "注意: 当前不是 root，dmesg/debugfs 可能不完整。建议用 sudo 重跑。"
fi

tar -czf "${OUT}.tar.gz" -C "$(dirname "${OUT}")" "$(basename "${OUT}")" 2>/dev/null
if [ -f "${OUT}.tar.gz" ]; then
    say "完成: ${OUT}.tar.gz  ($(du -h "${OUT}.tar.gz" | cut -f1))"
    echo
    echo "请把下面这个文件发给我："
    echo "  ${OUT}.tar.gz"
else
    say "打包失败，请手动打包目录: ${OUT}"
fi

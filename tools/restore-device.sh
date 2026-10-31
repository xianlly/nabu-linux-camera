#!/bin/bash
# restore-device.sh
# 撤销本会话在 Xiaomi Pad 5 (nabu) 上做的相机调试改动，恢复到调试前的状态。
#
# 用法（在设备上，root）：
#   sudo bash restore-device.sh                 # 只删除测试内核/模块/源码/临时文件
#   sudo bash restore-device.sh --purge-packages # 额外卸载为编译而安装的开发包
#
# 只删除本会话新增的东西，不动任何原有文件（原内核/原模块/原 refind.conf 均不触碰）。

set -u

PURGE_PKGS=0
[ "${1:-}" = "--purge-packages" ] && PURGE_PKGS=1

SELF_KERNEL=$(uname -r)
echo "== 当前运行内核: $SELF_KERNEL"
if [ "$SELF_KERNEL" = "6.14.11-nabu-cam1" ]; then
    echo "!! 当前正运行测试内核；删除其文件是安全的，重启后会自动回到日常内核。"
fi

# ---------- 1. 从 ESP 删除调试内核条目 ----------
ESP_UKI="/mnt/esp/EFI/ubuntu/6.14.11-cam1.efi"
mkdir -p /mnt/esp
if mountpoint -q /mnt/esp; then
    echo "== /mnt/esp 已挂载"
else
    mount /dev/disk/by-partlabel/esp /mnt/esp || { echo "!! 挂载 ESP 失败"; exit 1; }
fi

echo "== 删除前 ESP 内容:"
ls -l /mnt/esp/EFI/ubuntu/ 2>/dev/null

# 删除所有本会话产生的调试内核（6.14.11-cam1.efi / -cam2.efi ...），保留原厂 6.14.11.efi 与 6.17.0-*.efi
for f in /mnt/esp/EFI/ubuntu/6.14.11-cam*.efi; do
    [ -e "$f" ] || continue
    rm -f "$f"
    echo "== 已删除 $f"
done
sync

echo "== 删除后 ESP 内容:"
ls -l /mnt/esp/EFI/ubuntu/ 2>/dev/null
umount /mnt/esp

# ---------- 2. 删除测试内核模块 ----------
if [ -d /lib/modules/6.14.11-nabu-cam1 ]; then
    echo "== 删除 /lib/modules/6.14.11-nabu-cam1 ($(du -sh /lib/modules/6.14.11-nabu-cam1 | cut -f1))"
    rm -rf /lib/modules/6.14.11-nabu-cam1
else
    echo "== 测试模块目录不存在"
fi

# ---------- 3. 删除源码与构建产物 ----------
for p in /home/xiany/kbuild /home/xiany/linux-6.14.11.zip; do
    if [ -e "$p" ]; then
        echo "== 删除 $p ($(du -sh "$p" | cut -f1))"
        rm -rf "$p"
    fi
done

# ---------- 4. 删除采集脚本/诊断包/备份 ----------
for p in /home/xiany/collect-camera-info.sh /root/refind.conf.bak \
         /tmp/6.14.11-cam1.efi /tmp/live-6.14.11.dtb /tmp/live-cmdline.txt; do
    [ -e "$p" ] && { rm -f "$p"; echo "== 删除 $p"; }
done
rm -rf /home/xiany/camera-info-* 2>/dev/null && echo "== 删除 camera-info-* 采集目录/压缩包"

# ---------- 5. 可选：卸载开发包 ----------
if [ "$PURGE_PKGS" = "1" ]; then
    echo "== 卸载编译/调试用包"
    DEBIAN_FRONTEND=noninteractive apt-get remove -y --purge \
        build-essential bison flex libssl-dev libelf-dev device-tree-compiler \
        v4l-utils i2c-tools libcamera-tools 2>&1 | tail -3
    apt-get autoremove -y 2>&1 | tail -3
    apt-get clean
    echo "== 已清理 apt 缓存"
fi

# ---------- 6. 结果核对 ----------
echo
echo "== /lib/modules 剩余:"
ls /lib/modules/
echo
echo "== 建议: 重启后确认 rEFInd 菜单只剩 6.14.11 与 6.17.0；"
echo "   当前内核是 $SELF_KERNEL，重启即可回到日常内核。"

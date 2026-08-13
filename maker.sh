#!/bin/bash
set -e 

# =================================================================
# 1. 环境依赖检查
# =================================================================
if ! command -v virt-customize &> /dev/null; then
    echo "[INFO] 正在安装必要工具: libguestfs-tools"
    apt update && apt install -y libguestfs-tools wget
fi

# =================================================================
# 2. 配置区域
# =================================================================
STORAGE="local"       # 存储 ID (支持 Directory/LVM/ZFS)
BRIDGE="vmbr0"        # 默认网桥
DISK_SIZE="20G"       # 自动扩容的目标大小

declare -A IMAGES
IMAGES=(
    ["1"]="Debian-13|https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
    ["2"]="Debian-12|https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    ["3"]="Ubuntu-22.04|https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
    ["4"]="Ubuntu-24.04|https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    ["5"]="Rocky-9|https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
    ["6"]="AlmaLinux-9|https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
)

# =================================================================
# 3. 交互与准备
# =================================================================
echo
echo "====================================================="
echo "                      Maker"
echo "====================================================="
for key in $(echo ${!IMAGES[@]} | tr ' ' '\n' | sort -n); do
    NAME=$(echo ${IMAGES[$key]} | cut -d'|' -f1)
    echo "  $key) $NAME"
done

read -p "请输入欲创建的 VM BIOS (默认: SeaBIOS): " BIOS
BIOS=${BIOS:-SeaBIOS}

case "$BIOS" in
    SeaBIOS|seabios)
        BIOS_TYPE="seabios"
        MACHINE="i440fx"
        ;;
    UEFI|uefi|OVMF|ovmf)
        BIOS_TYPE="ovmf"
        MACHINE="q35"
        ;;
    *)
        echo "[ERROR] 无效 BIOS 类型: $BIOS" >&2
        echo "[INFO] 可选值: SeaBIOS, UEFI" >&2
        exit 1
        ;;
esac


read -p "请选择系统编号 [1-6] (默认: 1): " CHOICE
CHOICE=${CHOICE:-1}

SELECTED=${IMAGES[$CHOICE]}
if [ -z "$SELECTED" ]; then
    echo "[ERROR] 无效选择" >&2
    exit 1
fi

read -p "请输入欲创建的 VM ID (默认: 9000): " VMID
VMID=${VMID:-9000}


OS_NAME=$(echo $SELECTED | cut -d'|' -f1)
IMG_URL=$(echo $SELECTED | cut -d'|' -f2)
IMG_FILE=$(basename $IMG_URL)

# 下载镜像
if [ ! -f "$IMG_FILE" ]; then
    echo "[INFO] 正在下载 $OS_NAME 镜像"
    wget -q --show-progress -O "$IMG_FILE" "$IMG_URL"
fi

# =================================================================
# 4. 修改镜像配置
# =================================================================
echo "[INFO] 正在修改镜像配置"

virt-customize -q -a "$IMG_FILE" \
    --install qemu-guest-agent,cloud-init \
    --run-command "rm -f /etc/ssh/sshd_config.d/*.conf" \
    --run-command "sed -i '/PermitRootLogin/d' /etc/ssh/sshd_config" \
    --run-command "sed -i '/PasswordAuthentication/d' /etc/ssh/sshd_config" \
    --run-command "echo 'PermitRootLogin yes' >> /etc/ssh/sshd_config" \
    --run-command "echo 'PasswordAuthentication yes' >> /etc/ssh/sshd_config" \
    --run-command "systemctl enable qemu-guest-agent" \
    --run-command "userdel -r ubuntu || userdel -r debian || userdel -r cloud-user || true" \
    --truncate /etc/machine-id \
    --run-command "rm -f /etc/ssh/ssh_host_*" \
    --run-command "cloud-init clean --logs" \
    --run-command "find /var/log -type f -exec truncate -s 0 {} \;"

# =================================================================
# 5. 构建虚拟机
# =================================================================
echo "[INFO] 正在创建虚拟机并导入磁盘 (ID: $VMID)"

# 创建 VM 基础配置
qm create $VMID \
    --name "Maker-$OS_NAME" \
    --ostype l26 \
    --bios $BIOS_TYPE \
    --machine $MACHINE \
    --cpu host \
    --memory 2048 \
    --cores 2 \
    --net0 virtio,bridge=$BRIDGE

# 导入磁盘：使用 import-from 自动处理路径与命名
qm set $VMID \
    --scsihw virtio-scsi-pci \
    --scsi0 $STORAGE:0,import-from=$(pwd)/$IMG_FILE,discard=on

# 添加 Cloud-Init CD-ROM
qm set $VMID --ide2 $STORAGE:cloudinit

# UEFI 模式需要 EFI 磁盘
if [ "$BIOS_TYPE" = "ovmf" ]; then
    qm set $VMID --efidisk0 $STORAGE:0,efitype=4m,pre-enrolled-keys=0
fi

# 关键系统设置
qm set $VMID --boot c --bootdisk scsi0
qm set $VMID --serial0 socket 
qm set $VMID --agent enabled=1

# 调整磁盘大小
echo "[INFO] 正在扩展磁盘空间至 $DISK_SIZE"
qm disk resize $VMID scsi0 $DISK_SIZE

# 转换成模版
echo "[INFO] 正在转换为 PVE 模版"
qm template $VMID

echo
echo "[OK] 创建成功"
echo "[INFO] 模版名称: Maker-$OS_NAME"
echo "[INFO] 模版 ID: $VMID"

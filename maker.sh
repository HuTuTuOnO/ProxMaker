#!/bin/bash
set -e 

log_title() {
    printf '\n%s\n%s\n%s\n' "=====================================================" "$1" "====================================================="
}

log_info() {
    printf '[INFO] %s\n' "$1"
}

log_success() {
    printf '[OK] %s\n' "$1"
}

log_error() {
    printf '[ERROR] %s\n' "$1" >&2
}

run_quiet() {
    local message=$1
    shift

    "$@" >> "$LOG_FILE" 2>&1 && return 0

    log_error "$message 失败，最近日志如下:"
    tail -n 60 "$LOG_FILE" >&2
    exit 1
}

# =================================================================
# 1. 环境依赖检查
# =================================================================
if ! command -v virt-customize &> /dev/null; then
    log_info "正在安装必要工具: libguestfs-tools"
    run_quiet "更新软件源" apt update
    run_quiet "安装必要工具" apt install -y libguestfs-tools wget
fi

# =================================================================
# 2. 配置区域
# =================================================================
STORAGE="local"       # 存储 ID (支持 Directory/LVM/ZFS)
BRIDGE="vmbr0"        # 默认网桥
DISK_SIZE="40G"       # 自动扩容的目标大小
LOG_FILE="/tmp/proxmaker.log"

: > "$LOG_FILE"

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
log_title "ProxMaker"
for key in $(echo ${!IMAGES[@]} | tr ' ' '\n' | sort -n); do
    NAME=$(echo ${IMAGES[$key]} | cut -d'|' -f1)
    printf '  %s) %s\n' "$key" "$NAME"
done

read -p "请选择系统编号 [1-6] (默认: 1): " CHOICE
CHOICE=${CHOICE:-1}

read -p "请输入欲创建的 VM ID (默认: 9000): " VMID
VMID=${VMID:-9000}

SELECTED=${IMAGES[$CHOICE]}
if [ -z "$SELECTED" ]; then
    log_error "无效选择"
    exit 1
fi

OS_NAME=$(echo $SELECTED | cut -d'|' -f1)
IMG_URL=$(echo $SELECTED | cut -d'|' -f2)
IMG_FILE=$(basename $IMG_URL)

# 下载镜像
if [ ! -f "$IMG_FILE" ]; then
    log_info "正在下载 $OS_NAME 镜像"
    run_quiet "下载 $OS_NAME 镜像" wget -q -O "$IMG_FILE" "$IMG_URL"
fi

# =================================================================
# 4. 离线注入配置 (核心修复部分)
# =================================================================
log_info "正在修改镜像配置"

run_quiet "修改镜像配置" virt-customize -a "$IMG_FILE" \
    --no-random-seed \
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
# 5. 构建 PVE 虚拟机
# =================================================================
log_info "正在创建虚拟机并导入磁盘 (ID: $VMID)"

# 创建 VM 基础配置
run_quiet "创建虚拟机" qm create $VMID --name "tpl-$OS_NAME" --memory 2048 --cores 2 --net0 virtio,bridge=$BRIDGE

# 导入磁盘：使用 import-from 自动处理路径与命名
run_quiet "导入磁盘" qm set $VMID --scsihw virtio-scsi-pci \
    --scsi0 $STORAGE:0,import-from=$(pwd)/$IMG_FILE,discard=on

# 添加 Cloud-Init CD-ROM
run_quiet "添加 Cloud-Init CD-ROM" qm set $VMID --ide2 $STORAGE:cloudinit

# 关键系统设置
run_quiet "设置启动磁盘" qm set $VMID --boot c --bootdisk scsi0
run_quiet "设置串口控制台" qm set $VMID --serial0 socket --vga serial0
run_quiet "启用 QEMU Guest Agent" qm set $VMID --agent enabled=1

# 调整磁盘大小
log_info "正在扩展磁盘空间至 $DISK_SIZE"
run_quiet "扩展磁盘空间" qm disk resize $VMID scsi0 $DISK_SIZE

# 转换成模版
log_info "正在转换为 PVE 模版"
run_quiet "转换为 PVE 模版" qm template $VMID

printf '\n'
log_success "创建成功"
log_info "模版名称: tpl-$OS_NAME"
log_info "模版 ID: $VMID"
log_info "详细日志: $LOG_FILE"
log_info "使用建议:"
log_info "1. 在部署(Clone)前，请在 Web UI 的 Cloud-Init 栏目设置用户密码。"
log_info "2. 建议先点击 'Regenerate Image' (重生成) 再启动。"

#!/bin/bash
set -euo pipefail

# ==============================================
# 整合版 Proxmox VE 云模板创建脚本（终极优化：精准模式直接用系统名）
# 核心更新：精准模式支持「直接输入系统名」，无需记忆偏移量，公钥登录优先
# ==============================================

# -------------------------- 默认配置（可修改）--------------------------
DEFAULT_STORAGE="local"          # 默认存储池
DEFAULT_BRIDGE="vmbr0"           # 默认网络桥接
DEFAULT_VMID="8000"              # 精准模式默认VMID（直接指定，无需计算）
DEFAULT_CPU_CORES="2"            # 默认CPU核心数
DEFAULT_MEMORY="2048"            # 默认内存(MB)
DEFAULT_DISK="30G"               # 默认磁盘大小
DEFAULT_USER="root"              # 默认Cloud-Init用户名
DEFAULT_PASSWORD="changeme"      # 备用密码（公钥失效时使用）
SSH_PWAUTH="false"               # 公钥模式下禁用密码登录（增强安全）

# 支持的10种Linux发行版（格式：系统名,镜像URL）- 直接对应，无需偏移量
declare -A OS_IMAGES=(
    ["Debian11"]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
    ["Debian12"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    ["CentOS8Stream"]="https://cloud.centos.org/centos/8-stream/x86_64/images/CentOS-Stream-GenericCloud-8-20240513.0.x86_64.qcow2"
    ["CentOS9Stream"]="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-20240513.0.x86_64.qcow2"
    ["Ubuntu2204"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img"
    ["Ubuntu2404"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-disk-kvm.img"
    ["AlmaLinux8"]="https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-latest.x86_64.qcow2"
    ["AlmaLinux9"]="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
    ["RockyLinux8"]="https://download.rockylinux.org/pub/rocky/8/cloud/x86_64/images/Rocky-8-GenericCloud-Base.latest.x86_64/Rcow2"
    ["RockyLinux9"]="https://download.rockylinux.org/pub/rocky/9/cloud/x86_64/images/Rocky-9-GenericCloud-Base.latest.x86_64/Rcow2"
    ["Fedora39"]="https://download.fedoraproject.org/pub/fedora/linux/releases/39/Cloud/x86_64/images/Fedora-Cloud-Base-39-1.5.x86_64.qcow2"
)

# -------------------------- 工具函数 --------------------------
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "❌ 必须以root用户运行！" >&2
        exit 1
    fi
}

check_qm() {
    if ! command -v qm &> /dev/null; then
        echo "❌ 未找到qm命令，确保在Proxmox VE节点上运行！" >&2
        exit 1
    fi
}

check_storage() {
    local storage="$1"
    if ! pvesm status | grep -q "^$storage"; then
        echo "❌ 存储池 $storage 不存在！" >&2
        exit 1
    fi
}

check_vmid() {
    local vmid="$1"
    if qm status "$vmid" &> /dev/null; then
        echo "⚠️ VMID $vmid 已存在"
        read -p "是否销毁现有VM并继续？(y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            qm destroy "$vmid" --purge 2>/dev/null
            echo "✅ 已销毁VMID $vmid"
        else
            echo "🚫 操作取消"
            exit 0
        fi
    fi
}

check_ssh_key() {
    local key_path="$1"
    if [ ! -f "$key_path" ] || [ ! -s "$key_path" ]; then
        echo "❌ SSH公钥文件不存在或为空：$key_path" >&2
        exit 1
    fi
}

check_os_name() {
    local os_name="$1"
    if [ -z "${OS_IMAGES[$os_name]}" ]; then
        echo "❌ 不支持的系统名：$os_name" >&2
        echo "✅ 支持的系统名：${!OS_IMAGES[*]}"
        exit 1
    fi
}

download_image() {
    local url="$1"
    local output="$2"
    if [ -f "$output" ]; then
        read -p "⚠️ 镜像文件已存在，是否重新下载？(y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            echo "ℹ️ 复用现有镜像文件"
            return 0
        fi
    fi
    echo "📥 正在下载 $url"
    if ! wget -q --show-progress -O "$output" "$url"; then
        echo "❌ 镜像下载失败！" >&2
        rm -f "$output"
        exit 1
    fi
}

config_cloudinit() {
    local vmid="$1"
    local user="$2"
    local password="$3"
    local bridge="$4"
    local ssh_key_path="${5:-}"

    qm set "$vmid" \
        --ciuser "$user" \
        --cipassword "$password" \
        --net0 "virtio,bridge=$bridge" \
        --boot order="scsi0;net0" \
        --serial0 socket --vga serial0

    # 注入SSH公钥
    if [ -n "$ssh_key_path" ]; then
        local ssh_key=$(cat "$ssh_key_path")
        qm set "$vmid" --sshkeys <(echo "$ssh_key")
        echo "✅ 已注入SSH公钥：$ssh_key_path"
    fi

    # 配置SSH登录模式
    local cloud_init_disk=$(qm config "$vmid" | grep "scsi0" | awk '{print $2}' | cut -d':' -f1)
    local mount_dir="/tmp/pve-cloudinit-$(date +%s)"
    mkdir -p "$mount_dir"
    guestmount -a "$cloud_init_disk" -m /dev/sda1 "$mount_dir" 2>/dev/null || guestmount -a "$cloud_init_disk" -m /dev/vda1 "$mount_dir"
    if [ -f "$mount_dir/etc/cloud/cloud.cfg" ]; then
        sed -i "s/^ssh_pwauth: .*/ssh_pwauth: $SSH_PWAUTH/" "$mount_dir/etc/cloud/cloud.cfg"
        echo "✅ SSH密码登录已$( [ "$SSH_PWAUTH" = "true" ] && echo "开启" || echo "禁用" )"
    fi
    guestunmount "$mount_dir"
    rm -rf "$mount_dir"
}

create_template() {
    local vmid="$1"
    local os_name="$2"
    local image_url="$3"
    local storage="$4"
    local bridge="$5"
    local cpu="$6"
    local memory="$7"
    local disk="$8"
    local user="$9"
    local password="${10}"
    local ssh_key_path="${11:-}"

    echo -e "\n=================================================="
    echo "📌 开始创建模板：Template-$os_name（VMID: $vmid）"
    echo "=================================================="

    check_vmid "$vmid"
    local temp_image="/tmp/${os_name}-cloudimg.qcow2"
    download_image "$image_url" "$temp_image"

    # 创建VM
    qm create "$vmid" \
        --name "Template-$os_name" \
        --cpu cputype=kvm64 \
        --cores "$cpu" \
        --memory "$memory" \
        --balloon 0 \
        --ostype l26 \
        --scsihw virtio-scsi-pci

    # 导入磁盘
    qm importdisk "$vmid" "$temp_image" "$storage" --format qcow2
    qm set "$vmid" --scsi0 "$storage:vm-$vmid-disk-0"
    qm resize "$vmid" scsi0 "$disk"

    # 配置Cloud-Init
    config_cloudinit "$vmid" "$user" "$password" "$bridge" "$ssh_key_path"

    # 转换为模板
    qm template "$vmid"
    rm -f "$temp_image"

    echo -e "✅ 模板创建完成：Template-$os_name（VMID: $vmid）"
    [ -n "$ssh_key_path" ] && echo "🔑 登录方式：ssh $user@VM_IP -i 私钥文件" || echo "🔑 登录方式：用户名$user + 密码$password"
    echo -e "==================================================\n"
}

# -------------------------- 模式选择与执行 --------------------------
show_menu() {
    echo -e "\n====== Proxmox VE 模板创建脚本（整合版）======"
    echo "1. 批量模式：一键创建所有10种系统模板（密码登录）"
    echo "2. 交互模式：手动选择系统并配置参数（支持公钥/密码）"
    echo "3. 精准模式：命令行直接指定系统名创建（公钥登录优先）"
    echo "4. 退出"
    echo -e "=============================================\n"
    read -p "请选择模式（1-4）：" mode
}

batch_mode() {
    local storage="$1"
    local bridge="$2"
    local vmid_start="$3"
    local cpu="$4"
    local memory="$5"
    local disk="$6"
    local user="$7"
    local password="$8"

    echo -e "\n🚀 批量模式启动，将创建10种系统模板（VMID从 $vmid_start 开始递增）"
    read -p "是否继续？(y/n) " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && { echo "🚫 操作取消"; exit 0; }

    local vmid=$vmid_start
    for os_name in "${!OS_IMAGES[@]}"; do
        local url="${OS_IMAGES[$os_name]}"
        create_template "$vmid" "$os_name" "$url" "$storage" "$bridge" "$cpu" "$memory" "$disk" "$user" "$password"
        ((vmid++))
    done

    echo -e "\n🎉 所有模板创建完成！可在Proxmox控制台克隆使用"
}

interactive_mode() {
    echo -e "\n🔧 交互模式"

    # 基础配置
    read -p "请输入存储池名称（默认：$DEFAULT_STORAGE）：" storage
    storage=${storage:-$DEFAULT_STORAGE}
    check_storage "$storage"

    read -p "请输入网络桥接名称（默认：$DEFAULT_BRIDGE）：" bridge
    bridge=${bridge:-$DEFAULT_BRIDGE}

    read -p "请输入VMID（默认：$DEFAULT_VMID）：" vmid
    vmid=${vmid:-$DEFAULT_VMID}

    read -p "请输入CPU核心数（默认：$DEFAULT_CPU_CORES）：" cpu
    cpu=${cpu:-$DEFAULT_CPU_CORES}
    read -p "请输入内存大小(MB)（默认：$DEFAULT_MEMORY）：" memory
    memory=${memory:-$DEFAULT_MEMORY}
    read -p "请输入磁盘大小（默认：$DEFAULT_DISK）：" disk
    disk=${disk:-$DEFAULT_DISK}

    read -p "请输入Cloud-Init用户名（默认：$DEFAULT_USER）：" user
    user=${user:-$DEFAULT_USER}

    # 登录方式选择
    read -p "是否使用SSH公钥登录？(y/n，默认n) " use_key
    use_key=${use_key:-n}
    local ssh_key_path=""
    if [[ $use_key =~ ^[Yy]$ ]]; then
        read -p "请输入SSH公钥文件路径（如~/.ssh/id_rsa.pub）：" ssh_key_path
        check_ssh_key "$ssh_key_path"
        SSH_PWAUTH="false"
    else
        read -p "请输入登录密码（默认：$DEFAULT_PASSWORD）：" password
        password=${password:-$DEFAULT_PASSWORD}
        SSH_PWAUTH="true"
    fi

    # 系统选择（直接显示系统名）
    echo -e "\n支持的系统列表："
    local i=1
    for os_name in "${!OS_IMAGES[@]}"; do
        echo "$i. $os_name"
        ((i++))
    done
    read -p "请选择要创建的系统（输入序号，输入all创建全部）：" choice

    if [ "$choice" = "all" ]; then
        read -p "请输入批量模式VMID起始值（默认：$DEFAULT_VMID）：" vmid_start
        vmid_start=${vmid_start:-$DEFAULT_VMID}
        batch_mode "$storage" "$bridge" "$vmid_start" "$cpu" "$memory" "$disk" "$user" "${password:-$DEFAULT_PASSWORD}"
    else
        local idx=$((choice-1))
        local os_names=("${!OS_IMAGES[@]}")
        if [ $idx -ge 0 ] && [ $idx -lt ${#os_names[@]} ]; then
            local os_name="${os_names[$idx]}"
            local url="${OS_IMAGES[$os_name]}"
            create_template "$vmid" "$os_name" "$url" "$storage" "$bridge" "$cpu" "$memory" "$disk" "$user" "${password:-$DEFAULT_PASSWORD}" "$ssh_key_path"
        else
            echo "❌ 无效选择"
            exit 1
        fi
    fi
}

# 核心优化：精准模式（命令行参数：存储池 网桥 VMID 系统名 公钥路径）
precision_mode() {
    local storage="$1"
    local bridge="$2"
    local vmid="$3"
    local os_name="$4"
    local ssh_key_path="$5"

    # 校验参数
    check_storage "$storage"
    check_ssh_key "$ssh_key_path"
    check_os_name "$os_name"

    local url="${OS_IMAGES[$os_name]}"
    # 使用默认硬件配置（可按需修改脚本默认值）
    create_template \
        "$vmid" "$os_name" "$url" \
        "$storage" "$bridge" \
        "$DEFAULT_CPU_CORES" "$DEFAULT_MEMORY" "$DEFAULT_DISK" \
        "$DEFAULT_USER" "$DEFAULT_PASSWORD" \
        "$ssh_key_path"
}

# -------------------------- 主程序 --------------------------
main() {
    check_root
    check_qm

    # 命令行参数判断（精准模式：直接用系统名）
    if [ $# -eq 5 ]; then
        # 精准模式用法：bash script.sh 存储池 网桥 VMID 系统名 公钥路径
        precision_mode "$1" "$2" "$3" "$4" "$5"
        exit 0
    elif [ $# -eq 8 ]; then
        # 批量模式（命令行）：bash script.sh 存储池 网桥 VMID起始值 CPU 内存 磁盘 用户名 密码
        batch_mode "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
        exit 0
    elif [ $# -ne 0 ]; then
        echo "❌ 无效参数！"
        echo "精准模式用法：bash $0 存储池 网桥 VMID 系统名 公钥路径"
        echo "示例：bash $0 local vmbr0 8004 Ubuntu2204 ~/.ssh/id_rsa.pub"
        echo "支持的系统名：${!OS_IMAGES[*]}"
        exit 1
    fi

    # 菜单模式
    show_menu
    case $mode in
        1) batch_mode "$DEFAULT_STORAGE" "$DEFAULT_BRIDGE" "$DEFAULT_VMID" "$DEFAULT_CPU_CORES" "$DEFAULT_MEMORY" "$DEFAULT_DISK" "$DEFAULT_USER" "$DEFAULT_PASSWORD" ;;
        2) interactive_mode ;;
        3) echo "❌ 精准模式请通过命令行参数运行！用法：bash $0 存储池 网桥 VMID 系统名 公钥路径" ;;
        4) echo "👋 退出脚本"; exit 0 ;;
        *) echo "❌ 无效选择"; exit 1 ;;
    esac
}

main "$@"

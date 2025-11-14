#!/bin/bash
# set -euo pipefail  # 使用更精细的错误处理，替代这个
set -o pipefail

# ==============================================
# Proxmox VE 云模板创建脚本（完全优化版）
# 包含所有现代最佳实践：并行下载、错误处理、缓存、校验等
# ==============================================

# -------------------------- 版本和基础配置 --------------------------
readonly VERSION="2.0.0"
readonly SCRIPT_NAME="$(basename "$0")"
readonly LOG_FILE="/var/log/pve-template-maker.log"
readonly CACHE_DIR="/var/cache/pve-templates"
readonly TEMP_DIR="/tmp/pve-templates-$$"

# 颜色定义
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m'
readonly CYAN='\033[0;36m'
readonly NC='\033[0m' # No Color

# 默认配置
readonly DEFAULT_STORAGE="local"
readonly DEFAULT_BRIDGE="vmbr0"
readonly DEFAULT_VMID="8000"
readonly DEFAULT_CPU_CORES="2"
readonly DEFAULT_MEMORY="2048"
readonly DEFAULT_DISK="30G"
readonly DEFAULT_USER="root"
readonly DEFAULT_PASSWORD="changeme"
readonly SSH_PWAUTH="false"

# -------------------------- 错误处理和日志系统 --------------------------
handle_error() {
    local error_code=$?
    local error_line=$BASH_LINENO
    local error_command=$BASH_COMMAND
    
    log_error "脚本执行失败！"
    log_error "错误代码: $error_code"
    log_error "错误行号: $error_line"
    log_error "失败命令: $error_command"
    log_error "查看详细日志: tail -f $LOG_FILE"
    
    cleanup
    exit $error_code
}

# 设置错误陷阱
trap handle_error ERR
trap cleanup EXIT
trap 'echo -e "\n${YELLOW}⚠️  收到中断信号，正在清理...${NC}"; cleanup; exit 130' INT TERM

# 日志函数
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

log_info() {
    log "INFO" "$@"
    echo -e "${CYAN}ℹ️  $*${NC}"
}

log_success() {
    log "SUCCESS" "$@"
    echo -e "${GREEN}✅ $*${NC}"
}

log_warning() {
    log "WARNING" "$@"
    echo -e "${YELLOW}⚠️  $*${NC}"
}

log_error() {
    log "ERROR" "$@"
    echo -e "${RED}❌ $*${NC}" >&2
}

log_debug() {
    [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG" "$@"
}

# -------------------------- 清理函数 --------------------------
cleanup() {
    if [[ -d "$TEMP_DIR" ]]; then
        log_info "清理临时文件..."
        rm -rf "$TEMP_DIR"
    fi
    
    # 解除挂载
    if [[ -n "${MOUNT_DIR:-}" ]] && mountpoint -q "$MOUNT_DIR"; then
        guestunmount "$MOUNT_DIR" 2>/dev/null || true
        rmdir "$MOUNT_DIR" 2>/dev/null || true
    fi
}

# -------------------------- 系统镜像配置（修复URL错误）--------------------------
declare -A OS_IMAGES=(
    ["Debian11"]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
    ["Debian12"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
    ["CentOS8Stream"]="https://cloud.centos.org/centos/8-stream/x86_64/images/CentOS-Stream-GenericCloud-8-20240513.0.x86_64.qcow2"
    ["CentOS9Stream"]="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-20240513.0.x86_64.qcow2"
    ["Ubuntu2204"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64-disk-kvm.img"
    ["Ubuntu2404"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64-disk-kvm.img"
    ["AlmaLinux8"]="https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-latest.x86_64.qcow2"
    ["AlmaLinux9"]="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
    ["RockyLinux8"]="https://download.rockylinux.org/pub/rocky/8/cloud/x86_64/images/Rocky-8-GenericCloud-Base.latest.x86_64.qcow2"  # 修复URL
    ["RockyLinux9"]="https://download.rockylinux.org/pub/rocky/9/cloud/x86_64/images/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"  # 修复URL
    ["Fedora39"]="https://download.fedoraproject.org/pub/fedora/linux/releases/39/Cloud/x86_64/images/Fedora-Cloud-Base-39-1.5.x86_64.qcow2"
)

# 镜像校验和（可选安全特性）
declare -A OS_IMAGES_CHECKSUM=(
    ["Debian12"]="sha256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
    ["Ubuntu2404"]="sha256:xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"
)

# -------------------------- 工具函数（增强版）--------------------------
print_header() {
    echo -e "${PURPLE}"
    echo "╔═══════════════════════════════════════════════════════════════════════╗"
    echo "║         Proxmox VE Cloud Template Maker v${VERSION} (Optimized)         ║"
    echo "║                    全面优化版本 - 功能强大                           ║"
    echo "╚═══════════════════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

print_usage() {
    cat << EOF
${BLUE}用法:${NC}
    精准模式 (系统名):  ${GREEN}$SCRIPT_NAME <存储池> <网桥> <VMID> <系统名> <公钥路径>${NC}
    精准模式 (镜像URL): ${GREEN}$SCRIPT_NAME <存储池> <网桥> <VMID> <镜像URL> <公钥路径>${NC}
    批量模式:          ${GREEN}$SCRIPT_NAME <存储池> <网桥> <VMID起始> <CPU> <内存> <磁盘> <用户> <密码>${NC}
    
${BLUE}选项:${NC}
    -h, --help      显示帮助信息
    -v, --version   显示版本信息
    -d, --debug     启用调试模式
    
${BLUE}支持的系统名:${NC}
    $(IFS=', '; echo "${!OS_IMAGES[*]}")
    
${BLUE}示例:${NC}
    $SCRIPT_NAME local vmbr0 8001 Ubuntu2404 ~/.ssh/id_rsa.pub
    $SCRIPT_NAME local vmbr0 8002 https://example.com/custom.qcow2 ~/.ssh/id_rsa.pub
EOF
}

# 带默认值的安全输入函数
read_with_default() {
    local prompt="$1"
    local default="$2"
    local value
    
    read -p "$(echo -e "${CYAN}$prompt${NC} (默认: ${YELLOW}$default${NC}): ")" value
    echo "${value:-$default}"
}

# 检查依赖
check_dependencies() {
    local missing_deps=()
    
    for cmd in qm pvesm wget curl guestmount guestunmount sha256sum; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_deps+=("$cmd")
        fi
    done
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "缺少必要的依赖: ${missing_deps[*]}"
        log_info "请安装缺失的依赖包"
        exit 1
    fi
}

# 检查root权限
check_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        log_error "必须以root用户运行此脚本"
        exit 1
    fi
}

# 检查存储池
check_storage() {
    local storage="$1"
    if ! pvesm status | grep -q "^$storage"; then
        log_error "存储池 $storage 不存在"
        return 1
    fi
    return 0
}

# 检查VMID
check_vmid() {
    local vmid="$1"
    if qm status "$vmid" &> /dev/null; then
        log_warning "VMID $vmid 已存在"
        read -p "是否销毁现有VM并继续？(y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            qm destroy "$vmid" --purge 2>/dev/null
            log_success "已销毁VMID $vmid"
        else
            log_info "操作取消"
            return 1
        fi
    fi
    return 0
}

# 检查SSH公钥
check_ssh_key() {
    local key_path="$1"
    if [[ ! -f "$key_path" ]] || [[ ! -s "$key_path" ]]; then
        log_error "SSH公钥文件不存在或为空: $key_path"
        return 1
    fi
    return 0
}

# 检查系统名
check_os_name() {
    local os_name="$1"
    if [[ -z "${OS_IMAGES[$os_name]:-}" ]]; then
        log_error "不支持的系统名: $os_name"
        log_info "支持的系统名: ${!OS_IMAGES[*]}"
        return 1
    fi
    return 0
}

# 提取镜像文件名
extract_image_name() {
    local url="$1"
    local filename
    filename=$(basename "$url" | sed -E 's/\?.*$//' | sed -E 's/\.(qcow2|img|raw)$//i')
    echo "Template-$filename"
}

# -------------------------- 下载系统（支持并行和缓存）--------------------------
download_image() {
    local url="$1"
    local output="$2"
    local os_name="${3:-}"
    
    # 确保缓存目录存在
    mkdir -p "$CACHE_DIR"
    
    # 生成缓存文件名 (使用URL的MD5值)
    local cache_filename
    cache_filename=$(echo -n "$url" | md5sum | cut -d' ' -f1)
    local cached_file="$CACHE_DIR/$cache_filename.qcow2"
    
    # 检查缓存
    if [[ -f "$cached_file" ]]; then
        log_info "发现缓存镜像，复用: $(basename "$cached_file")"
        cp "$cached_file" "$output"
        return 0
    fi
    
    # 检查目标文件是否存在
    if [[ -f "$output" ]]; then
        read -p "⚠️  镜像文件已存在，是否重新下载？(y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            log_info "复用现有镜像文件"
            return 0
        fi
    fi
    
    log_info "正在下载: $url"
    
    # 代理支持
    local wget_opts=()
    if [[ -n "${HTTP_PROXY:-}" ]]; then
        wget_opts+=("-e" "use_proxy=yes" "-e" "http_proxy=$HTTP_PROXY")
    fi
    
    # 下载并显示进度
    if ! wget -q --show-progress "${wget_opts[@]}" -O "$output" "$url"; then
        log_error "镜像下载失败"
        rm -f "$output"
        return 1
    fi
    
    # 添加到缓存
    cp "$output" "$cached_file"
    log_success "镜像下载完成，已缓存"
    
    # 校验镜像完整性（如果提供了校验和）
    if [[ -n "${os_name:-}" ]] && [[ -n "${OS_IMAGES_CHECKSUM[$os_name]:-}" ]]; then
        log_info "校验镜像完整性..."
        echo "${OS_IMAGES_CHECKSUM[$os_name]} $output" | sha256sum -c
    fi
}

# -------------------------- 并行下载支持 --------------------------
download_images_parallel() {
    local -n images_map=$1  # nameref for associative array
    local download_dir="$2"
    
    mkdir -p "$download_dir"
    
    log_info "开始并行下载镜像..."
    
    # 启动并行下载任务
    local pids=()
    for os_name in "${!images_map[@]}"; do
        local url="${images_map[$os_name]}"
        local output="$download_dir/${os_name}.qcow2"
        
        download_image "$url" "$output" "$os_name" &
        pids+=($!)
    done
    
    # 等待所有下载完成
    local failed_downloads=()
    for i in "${!pids[@]}"; do
        local os_name="${!images_map[@]:$i:1}"
        if ! wait "${pids[$i]}"; then
            failed_downloads+=("$os_name")
        fi
    done
    
    if [[ ${#failed_downloads[@]} -gt 0 ]]; then
        log_error "以下镜像下载失败: ${failed_downloads[*]}"
        return 1
    fi
    
    log_success "所有镜像下载完成"
    return 0
}

# -------------------------- Cloud-Init 配置 --------------------------
config_cloudinit() {
    local vmid="$1"
    local user="$2"
    local password="$3"
    local bridge="$4"
    local ssh_key_path="${5:-}"
    
    log_info "配置Cloud-Init..."
    
    qm set "$vmid" \
        --ciuser "$user" \
        --cipassword "$password" \
        --net0 "virtio,bridge=$bridge" \
        --boot order="scsi0;net0" \
        --serial0 socket --vga serial0
    
    # 注入SSH公钥
    if [[ -n "$ssh_key_path" ]]; then
        local ssh_key
        ssh_key=$(cat "$ssh_key_path")
        qm set "$vmid" --sshkeys <(echo "$ssh_key")
        log_success "已注入SSH公钥: $ssh_key_path"
    fi
    
    # 配置SSH登录模式
    local cloud_init_disk
    cloud_init_disk=$(qm config "$vmid" | grep "scsi0" | awk '{print $2}' | cut -d':' -f1)
    
    MOUNT_DIR="/tmp/pve-cloudinit-$(date +%s)"
    mkdir -p "$MOUNT_DIR"
    
    if guestmount -a "$cloud_init_disk" -m /dev/sda1 "$MOUNT_DIR" 2>/dev/null || \
       guestmount -a "$cloud_init_disk" -m /dev/vda1 "$MOUNT_DIR" 2>/dev/null; then
        if [[ -f "$MOUNT_DIR/etc/cloud/cloud.cfg" ]]; then
            sed -i "s/^ssh_pwauth: .*/ssh_pwauth: $SSH_PWAUTH/" "$MOUNT_DIR/etc/cloud/cloud.cfg"
            log_success "SSH密码登录已$([ "$SSH_PWAUTH" = "true" ] && echo "开启" || echo "禁用")"
        fi
        guestunmount "$MOUNT_DIR"
    fi
    
    rmdir "$MOUNT_DIR" 2>/dev/null || true
    unset MOUNT_DIR
}

# -------------------------- VM基础创建（重构重复代码）--------------------------
create_vm_base() {
    local vmid="$1"
    local name="$2"
    local cpu="$3"
    local memory="$4"
    
    log_info "创建基础VM配置..."
    
    qm create "$vmid" \
        --name "$name" \
        --cpu cputype=kvm64 \
        --cores "$cpu" \
        --memory "$memory" \
        --balloon 0 \
        --ostype l26 \
        --scsihw virtio-scsi-pci
    
    log_success "基础VM创建完成: $name (VMID: $vmid)"
}

# -------------------------- 完整模板创建流程 --------------------------
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
    
    print_header
    
    log_info "开始创建模板: Template-$os_name (VMID: $vmid)"
    
    # 检查VMID
    if ! check_vmid "$vmid"; then
        return 1
    fi
    
    # 下载镜像
    local temp_image="$TEMP_DIR/${os_name}-cloudimg.qcow2"
    if ! download_image "$image_url" "$temp_image" "$os_name"; then
        return 1
    fi
    
    # 创建基础VM
    create_vm_base "$vmid" "Template-$os_name" "$cpu" "$memory"
    
    # 导入磁盘
    log_info "导入磁盘镜像..."
    qm importdisk "$vmid" "$temp_image" "$storage" --format qcow2
    qm set "$vmid" --scsi0 "$storage:vm-$vmid-disk-0"
    qm resize "$vmid" scsi0 "$disk"
    
    # 配置Cloud-Init
    config_cloudinit "$vmid" "$user" "$password" "$bridge" "$ssh_key_path"
    
    # 转换为模板
    log_info "转换为模板..."
    qm template "$vmid"
    
    log_success "模板创建完成: Template-$os_name (VMID: $vmid)"
    if [[ -n "$ssh_key_path" ]]; then
        log_info "登录方式: ssh $user@<VM_IP> -i <私钥文件>"
    else
        log_info "登录方式: 用户名 $user + 密码"
    fi
}

# -------------------------- 精准模式 --------------------------
precision_mode() {
    local storage="$1"
    local bridge="$2"
    local vmid="$3"
    local input="$4"  # 系统名或镜像URL
    local ssh_key_path="$5"
    
    log_info "启动精准模式..."
    
    # 验证基础参数
    if ! check_storage "$storage"; then
        return 1
    fi
    
    if ! check_ssh_key "$ssh_key_path"; then
        return 1
    fi
    
    local os_name=""
    local image_url=""
    local template_name=""
    
    # 判断输入类型
    if [[ "$input" =~ ^https?:// ]]; then
        # 镜像URL模式
        image_url="$input"
        template_name=$(extract_image_name "$image_url")
        log_info "识别为镜像URL，自动生成模板名: $template_name"
    else
        # 系统名模式
        if ! check_os_name "$input"; then
            return 1
        fi
        os_name="$input"
        image_url="${OS_IMAGES[$os_name]}"
        template_name="Template-$os_name"
    fi
    
    # 使用默认硬件配置
    create_template "$vmid" "$os_name" "$image_url" "$storage" "$bridge" \
                   "$DEFAULT_CPU_CORES" "$DEFAULT_MEMORY" "$DEFAULT_DISK" \
                   "$DEFAULT_USER" "$DEFAULT_PASSWORD" "$ssh_key_path"
}

# -------------------------- 批量模式（支持并行）--------------------------
batch_mode() {
    local storage="$1"
    local bridge="$2"
    local vmid_start="$3"
    local cpu="$4"
    local memory="$5"
    local disk="$6"
    local user="$7"
    local password="$8"
    
    log_info "启动批量模式，将创建 ${#OS_IMAGES[@]} 种系统模板"
    log_info "VMID 从 $vmid_start 开始递增"
    
    read -p "是否继续？(y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log_info "操作取消"
        return 0
    fi
    
    # 验证存储池
    if ! check_storage "$storage"; then
        return 1
    fi
    
    # 先并行下载所有镜像
    if ! download_images_parallel OS_IMAGES "$TEMP_DIR"; then
        log_error "镜像下载失败，终止批量创建"
        return 1
    fi
    
    # 串行创建模板（qm命令需要串行）
    local vmid=$vmid_start
    local failed_templates=()
    
    for os_name in "${!OS_IMAGES[@]}"; do
        local image_file="$TEMP_DIR/${os_name}.qcow2"
        
        log_info "创建模板: $os_name (VMID: $vmid)"
        
        if ! check_vmid "$vmid"; then
            ((vmid++))
            continue
        fi
            
        # 创建基础VM
        create_vm_base "$vmid" "Template-$os_name" "$cpu" "$memory"
        
        # 导入磁盘（使用已下载的镜像）
        qm importdisk "$vmid" "$image_file" "$storage" --format qcow2
        qm set "$vmid" --scsi0 "$storage:vm-$vmid-disk-0"
        qm resize "$vmid" scsi0 "$disk"
        
        # 配置Cloud-Init
        config_cloudinit "$vmid" "$user" "$password" "$bridge"
        
        # 转换为模板
        qm template "$vmid"
        
        log_success "模板创建完成: Template-$os_name (VMID: $vmid)"
        ((vmid++))
    done
    
    log_success "批量创建完成！可在Proxmox控制台查看模板"
}

# -------------------------- 交互模式（增强版）--------------------------
interactive_mode() {
    print_header
    
    log_info "启动交互模式"
    
    # 基础配置输入
    local storage
    storage=$(read_with_default "存储池名称" "$DEFAULT_STORAGE")
    if ! check_storage "$storage"; then
        return 1
    fi
    
    local bridge
    bridge=$(read_with_default "网络桥接" "$DEFAULT_BRIDGE")
    
    local cpu
    cpu=$(read_with_default "CPU核心数" "$DEFAULT_CPU_CORES")
    
    local memory
    memory=$(read_with_default "内存大小(MB)" "$DEFAULT_MEMORY")
    
    local disk
    disk=$(read_with_default "磁盘大小" "$DEFAULT_DISK")
    
    local user
    user=$(read_with_default "用户名" "$DEFAULT_USER")
    
    local password
    password=$(read_with_default "密码" "$DEFAULT_PASSWORD")
    
    # SSH密钥配置
    local ssh_key_path=""
    read -p "是否使用SSH公钥登录？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        read -p "请输入SSH公钥文件路径: " ssh_key_path
        if ! check_ssh_key "$ssh_key_path"; then
            return 1
        fi
    fi
    
    # 系统选择
    echo "可选系统:"
    local os_list=("${!OS_IMAGES[@]}")
    for i in "${!os_list[@]}"; do
        echo "  $((i+1)). ${os_list[$i]}"
    done
    
    local choice
    read -p "请选择系统 (1-${#os_list[@]}): " choice
    if [[ ! "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt "${#os_list[@]}" ]]; then
        log_error "无效选择"
        return 1
    fi
    
    local os_name="${os_list[$((choice-1))]}"
    local vmid
    vmid=$(read_with_default "VMID" "$DEFAULT_VMID")
    
    if ! check_vmid "$vmid"; then
        return 1
    fi
    
    # 创建模板
    create_template "$vmid" "$os_name" "${OS_IMAGES[$os_name]}" "$storage" \
                   "$bridge" "$cpu" "$memory" "$disk" "$user" "$password" "$ssh_key_path"
}

# -------------------------- 现代菜单系统 --------------------------
show_menu() {
    print_header
    
    local options=(
        "批量模式：一键创建所有系统模板"
        "交互模式：手动配置参数创建模板"
        "精准模式：命令行直接创建模板"
        "清理缓存：删除所有缓存的镜像文件"
        "退出"
    )
    
    echo -e "${BLUE}请选择操作模式:${NC}"
    for i in "${!options[@]}"; do
        echo "  $((i+1))). ${options[$i]}"
    done
    echo
    
    local choice
    read -p "请输入选择 (1-${#options[@]}): " choice
    
    case "$choice" in
        1) 
            check_storage "$DEFAULT_STORAGE" || return 1
            batch_mode "$DEFAULT_STORAGE" "$DEFAULT_BRIDGE" "$DEFAULT_VMID" \
                      "$DEFAULT_CPU_CORES" "$DEFAULT_MEMORY" "$DEFAULT_DISK" \
                      "$DEFAULT_USER" "$DEFAULT_PASSWORD"
            ;;
        2) interactive_mode ;;
        3) 
            log_info "精准模式请使用命令行参数运行"
            print_usage
            ;;
        4) 
            log_info "清理缓存文件..."
            rm -rf "$CACHE_DIR"/*
            log_success "缓存清理完成"
            ;;
        5) 
            log_info "感谢使用，再见！"
            exit 0
            ;;
        *) 
            log_error "无效选择"
            return 1
            ;;
    esac
}

# -------------------------- 参数解析系统 --------------------------
parse_arguments() {
    case "${1:-}" in
        -h|--help)
            print_header
            print_usage
            exit 0
            ;;
        -v|--version)
            echo "$VERSION"
            exit 0
            ;;
        -d|--debug)
            export DEBUG=true
            shift
            ;;
    esac
    
    # 主参数逻辑
    if [[ $# -eq 5 ]]; then
        # 精准模式
        check_root
        check_dependencies
        precision_mode "$1" "$2" "$3" "$4" "$5"
    elif [[ $# -eq 8 ]]; then
        # 批量模式
        check_root
        check_dependencies
        batch_mode "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8"
    elif [[ $# -eq 0 ]]; then
        # 菜单模式
        check_root
        check_dependencies
        while true; do
            show_menu
            read -p "按回车键继续菜单，或输入 'q' 退出: " choice
            [[ "$choice" == "q" ]] && break
        done
    else
        print_header
        print_usage
        log_error "参数数量错误，期望 0, 5 或 8 个参数，实际提供 $# 个"
        exit 1
    fi
}

# -------------------------- 主程序入口 --------------------------
main() {
    # 确保临时目录存在
    mkdir -p "$TEMP_DIR"
    
    # 记录启动信息
    log_info "脚本启动 - 版本: $VERSION"
    log_info "参数: $*"
    log_info "日志文件: $LOG_FILE"
    
    # 解析参数并执行
    parse_arguments "$@"
    
    log_info "脚本执行完成"
}

# 执行主程序
main "$@"

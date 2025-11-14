#!/usr/bin/env bash
# =============================================================================
#  Proxmox VE 云模板创建脚本  v2.1.1  (2025-06 修复增强版)
#  1) 自动检测并安装缺失依赖
#  2) 根据出口 IP 自动选择国内外镜像站
#  3) 并行下载 + 本地缓存 + 断点续传 + SHA256 校验
#  4) 批量 / 交互 / 精准 三种模式
# =============================================================================
set -o pipefail
shopt -s extglob nameref

readonly VERSION="2.1.1"
readonly SCRIPT_NAME="$(basename "$0")"
readonly CACHE_DIR="/var/cache/pve-templates"
readonly TEMP_DIR="/tmp/pve-templates-$$"
readonly LOG_FILE=$(touch /var/log/pve-template-maker.log 2>/dev/null \
                    && echo /var/log/pve-template-maker.log \
                    || echo /dev/null)

# -------------------- 颜色 --------------------
readonly RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[1;33m' BLUE='\033[0;34m'
readonly PURPLE='\033[0;35m' CYAN='\033[0;36m' NC='\033[0m'

# -------------------- 默认配置 --------------------
readonly DEFAULT_STORAGE="local"
readonly DEFAULT_BRIDGE="vmbr0"
readonly DEFAULT_VMID="8000"
readonly DEFAULT_CPU_CORES="2"
readonly DEFAULT_MEMORY="2048"
readonly DEFAULT_DISK="30G"
readonly DEFAULT_USER="root"
readonly DEFAULT_PASSWORD="changeme"
readonly SSH_PWAUTH="false"

# -------------------- 日志系统 --------------------
log(){
  local level="$1"; shift
  local timestamp
  timestamp=$(date '+%F %T')
  echo -e "[$timestamp] [$level] $*" | tee -a "$LOG_FILE"
}
log_info(){ log "INFO" "$@"; echo -e "${CYAN}ℹ️  $*${NC}"; }
log_success(){ log "SUCCESS" "$@"; echo -e "${GREEN}✅ $*${NC}"; }
log_warning(){ log "WARNING" "$@"; echo -e "${YELLOW}⚠️  $*${NC}"; }
log_error(){ log "ERROR" "$@"; echo -e "${RED}❌ $*${NC}" >&2; }
log_debug(){ [[ "${DEBUG:-false}" == "true" ]] && log "DEBUG" "$@"; }

# -------------------- 错误陷阱 --------------------
cleanup(){
  [[ -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  if [[ -n "${MOUNT_DIR:-}" ]] && mountpoint -q "$MOUNT_DIR"; then
    guestunmount "$MOUNT_DIR" 2>/dev/null || true
    rmdir "$MOUNT_DIR" 2>/dev/null || true
  fi
  if [[ -n "${CUR_VMID:-}" ]]; then
    qm destroy "$CUR_VMID" --purge &>/dev/null || true
  fi
}
handle_error(){
  local line=$BASH_LINENO cmd=$BASH_COMMAND code=$?
  log_error "脚本异常！行号:$line 代码:$code 命令:$cmd"
  cleanup
  exit $code
}
trap handle_error ERR
trap cleanup EXIT
trap 'echo -e "\n${YELLOW}⚠️  中断信号，清理中...${NC}"; cleanup; exit 130' INT TERM

# -------------------- 依赖自动安装 --------------------
install_deps(){
  local pkgs=("$@") cmd=""
  if command -v apt-get &>/dev/null; then
    cmd="apt-get -qqy install"
  elif command -v dnf &>/dev/null; then
    cmd="dnf -q -y install"
  elif command -v yum &>/dev/null; then
    cmd="yum -q -y install"
  elif command -v zypper &>/dev/null; then
    cmd="zypper -q -n install"
  else
    log_error "未识别的包管理器，请手动安装：${pkgs[*]}"; return 1
  fi
  log_info "安装依赖：${pkgs[*]}"
  $cmd "${pkgs[@]}"
}

check_dependencies(){
  local deb_pkgs=(qemu-utils libguestfs-tools wget curl)
  local rh_pkgs=(qemu-img libguestfs-tools wget curl)
  local miss=()
  for c in qm pvesm wget curl guestmount guestunmount sha256sum; do
    command -v "$c" &>/dev/null || miss+=("$c")
  done
  if ((${#miss[@]})); then
    log_warning "缺失命令：${miss[*]}"
    if command -v apt-get &>/dev/null; then install_deps "${deb_pkgs[@]}"
    elif command -v dnf &>/dev/null || command -v yum &>/dev/null; then install_deps "${rh_pkgs[@]}"
    else log_error "请手动安装缺失命令"; exit 1; fi
  fi
}

# -------------------- 镜像地址智能替换 --------------------
select_mirror(){
  local domain="$1"
  local upstream="$domain"
  local ipinfo
  ipinfo=$(curl -s4 -m 5 --retry 2 https://ipinfo.io/country || curl -s6 -m 5 --retry 2 https://ipinfo.io/country || true)
  if [[ "$ipinfo" == "CN" ]]; then
    case "$upstream" in
      debian.org)      domain="mirrors.huaweicloud.com" ;;
      ubuntu.com)      domain="mirrors.tuna.tsinghua.edu.cn" ;;
      centos.org)      domain="mirrors.aliyun.com" ;;
      almalinux.org)   domain="mirrors.neusoft.edu.cn" ;;
      rockylinux.org)  domain="mirrors.aliyun.com" ;;
      fedoraproject.org) domain="mirrors.aliyun.com" ;;
    esac
  fi
  echo "$domain"
}

rewrite_urls(){
  local -n map_ref=$1
  local key url old_domain new_domain new_url
  for key in "${!map_ref[@]}"; do
    url="${map_ref[$key]}"
    old_domain=$(echo "$url" | awk -F[/:] '{print $4}')
    new_domain=$(select_mirror "$old_domain")
    if [[ "$new_domain" != "$old_domain" ]]; then
      new_url="${url/$old_domain/$new_domain}"
      log_info "镜像 [$key] 切换为 $new_url"
      map_ref[$key]="$new_url"
    fi
  done
}

# -------------------- 原始镜像表 --------------------
declare -A OS_IMAGES=(
  ["Debian11"]="https://cloud.debian.org/images/cloud/bullseye/latest/debian-11-genericcloud-amd64.qcow2"
  ["Debian12"]="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2"
  ["CentOS8Stream"]="https://cloud.centos.org/centos/8-stream/x86_64/images/CentOS-Stream-GenericCloud-8-20240513.0.x86_64.qcow2"
  ["CentOS9Stream"]="https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-20240513.0.x86_64.qcow2"
  ["Ubuntu2204"]="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
  ["Ubuntu2404"]="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  ["AlmaLinux8"]="https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-latest.x86_64.qcow2"
  ["AlmaLinux9"]="https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2"
  ["RockyLinux8"]="https://download.rockylinux.org/pub/rocky/8/cloud/x86_64/images/Rocky-8-GenericCloud-Base.latest.x86_64.qcow2"
  ["RockyLinux9"]="https://download.rockylinux.org/pub/rocky/9/cloud/x86_64/images/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
  ["Fedora39"]="https://download.fedoraproject.org/pub/fedora/linux/releases/39/Cloud/x86_64/images/Fedora-Cloud-Base-39-1.5.x86_64.qcow2"
)

# -------------------- 工具函数 --------------------
print_header(){
  echo -e "${PURPLE}
╔═══════════════════════════════════════════════════════════════════════╗
║         Proxmox VE Cloud Template Maker v${VERSION} (Optimized)         ║
║                    自动依赖 / 镜像加速 / 并行下载                     ║
╚═══════════════════════════════════════════════════════════════════════╝${NC}"
}
check_root(){
  [[ $(id -u) -ne 0 ]] && { log_error "请使用 root 运行"; exit 1; }
}
check_storage(){
  pvesm status | grep -q "^$1" && return 0
  log_error "存储池 $1 不存在"; return 1
}
check_vmid(){
  if qm status "$1" &>/dev/null; then
    read -p "⚠️  VMID $1 已存在，是否销毁重建？(y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
      qm destroy "$1" --purge 2>/dev/null || {
        log_error "销毁 VMID $1 失败，可能正在被克隆"; return 1
      }
      log_success "已销毁 VMID $1"
    else
      log_info "操作取消"; return 1
    fi
  fi
  return 0
}
check_ssh_key(){
  [[ -s "$1" ]] && return 0
  log_error "SSH 公钥文件不存在或为空：$1"; return 1
}
check_os_name(){
  [[ -n "${OS_IMAGES[$1]:-}" ]] && return 0
  log_error "不支持的系统名：$1"; return 1
}
read_with_default(){
  local prompt="$1" default="$2" val
  read -rp "$(echo -e "${CYAN}$prompt${NC} (默认: ${YELLOW}$default${NC}): ")" val
  echo "${val:-$default}"
}

# -------------------- 下载镜像（缓存 + 断点续传 + SHA256 校验）--------------------
download_image(){
  local url="$1" output="$2" os_name="${3:-}"
  mkdir -p "$CACHE_DIR"
  local cache_fn="${os_name:-unknown}-$(printf %s "${url%%+([[:space:]])}" | md5sum | cut -d' ' -f1)"
  local cached="$CACHE_DIR/$cache_fn.qcow2"
  local sum_url="${url}.SHA256SUM"
  if [[ -f "$cached" ]]; then
    log_info "命中缓存：$cached"
    cp "$cached" "$output"
    return 0
  fi
  log_info "下载：$url"
  local wget_opts=(-q --show-progress -O "$output" -c)
  [[ -n "${HTTP_PROXY:-}" ]] && wget_opts+=(-e use_proxy=yes -e "http_proxy=$HTTP_PROXY")
  if ! wget "${wget_opts[@]}" "$url"; then
    log_error "下载失败"; rm -f "$output"; return 1
  fi
  # 简单 SHA256 校验（如果镜像站提供）
  if wget -q -O - "$sum_url" | grep "$(basename "$url")" | sha256sum -c >/dev/null 2>&1; then
    log_success "SHA256 校验通过"
  else
    log_warning "SHA256 校验跳过或失败"
  fi
  cp "$output" "$cached"
  log_success "下载完成并已缓存"
}

# -------------------- 并行下载 --------------------
download_images_parallel(){
  local -n imap=$1
  local ddir="$2" pids=() fail=() names=()
  mkdir -p "$ddir"
  mapfile -t names < <(printf '%s\n' "${!imap[@]}" | sort)
  log_info "开始并行下载 ${#names[@]} 个镜像"
  local i
  for i in "${!names[@]}"; do
    download_image "${imap[${names[$i]}]}" "$ddir/${names[$i]}.qcow2" "${names[$i]}" &
    pids[$i]=$!
  done
  for i in "${!pids[@]}"; do
    if ! wait "${pids[$i]}"; then fail+=("${names[$i]}"); fi
  done
  if ((${#fail[@]})); then
    log_error "部分镜像下载失败：${fail[*]}"; return 1
  fi
  log_success "全部镜像下载完成"
}

# -------------------- Cloud-Init 配置 --------------------
config_cloudinit(){
  local vmid="$1" user="$2" pass="$3" bridge="$4" sshkey="$5" cloud_disk="$6"
  qm set "$vmid" --ciuser "$user" --cipassword "$pass" \
        --net0 "virtio,bridge=$bridge" \
        --serial0 socket --vga serial0
  [[ -n "$sshkey" ]] && qm set "$vmid" --sshkeys <(cat "$sshkey")
  [[ -f "$cloud_disk" ]] || { log_error "磁盘文件不存在：$cloud_disk"; return 1; }
  local mnt="/tmp/pve-ci-$$"
  mkdir -p "$mnt"
  if guestmount -a "$cloud_disk" -m /dev/sda1 "$mnt" 2>/dev/null || \
     guestmount -a "$cloud_disk" -m /dev/vda1 "$mnt" 2>/dev/null; then
    sed -i "s/^ssh_pwauth:.*/ssh_pwauth: $SSH_PWAUTH/" "$mnt/etc/cloud/cloud.cfg" 2>/dev/null || true
    chroot "$mnt" systemctl enable qemu-guest-agent.service 2>/dev/null || \
    ln -s /usr/lib/systemd/system/qemu-guest-agent.service \
          "$mnt/etc/systemd/system/multi-user.target.wants/" 2>/dev/null || true
    guestunmount "$mnt"
  else
    log_error "guestmount 失败，放弃 cloud-init 微调"; return 1
  fi
  rmdir "$mnt" 2>/dev/null || true
}

# -------------------- 创建 VM 基础 --------------------
create_vm_base(){
  local vmid="$1" name="$2" cpu="$3" mem="$4"
  qm create "$vmid" --name "$name" --cpu cputype=kvm64 --cores "$cpu" \
        --memory "$mem" --balloon 0 --ostype l26 --scsihw virtio-scsi-pci --agent 1
  log_success "基础 VM 创建：$name (VMID:$vmid)"
}

# -------------------- 单模板完整流程 --------------------
create_template(){
  local vmid="$1" os_name="$2" url="$3" storage="$4" bridge="$5"
  local cpu="$6" mem="$7" disk="$8" user="$9" pass="${10}" sshkey="${11}"
  export CUR_VMID=$vmid
  print_header
  log_info "开始创建模板：Template-$os_name (VMID:$vmid)"
  check_vmid "$vmid" || return 1
  local tmp_img="$TEMP_DIR/${os_name}-cloudimg.qcow2"
  download_image "$url" "$tmp_img" "$os_name" || return 1
  create_vm_base "$vmid" "Template-$os_name" "$cpu" "$mem"
  qm importdisk "$vmid" "$tmp_img" "$storage" --format qcow2
  until qm config "$vmid" | grep -q "unused0"; do sleep 1; done
  qm set "$vmid" --scsi0 "$storage:$vmid/vm-$vmid-disk-0.qcow2"
  local cloud_disk="/var/lib/vz/images/$vmid/vm-$vmid-disk-0.qcow2"
  qm resize "$vmid" scsi0 "$disk"
  qm set "$vmid" --ide2 "$storage:cloudinit"
  config_cloudinit "$vmid" "$user" "$pass" "$bridge" "$sshkey" "$cloud_disk" || return 1
  qm template "$vmid"
  log_success "模板创建完成：Template-$os_name (VMID:$vmid)"
}

# -------------------- 精准模式 --------------------
precision_mode(){
  local storage="$1" bridge="$2" vmid="$3" input="$4" sshkey="$5"
  log_info "启动精准模式"
  check_storage "$storage" || return 1
  check_ssh_key "$sshkey" || return 1
  local os_name="" url="" template_name
  if [[ "$input" =~ ^https?:// ]]; then
    url="$input"
    template_name=$(basename "$url" | sed -E 's/\?.*//;s/\.(qcow2|img)$//i')
    log_info "识别为镜像 URL，模板名：$template_name"
  else
    check_os_name "$input" || return 1
    os_name="$input"; url="${OS_IMAGES[$os_name]}"
  fi
  create_template "$vmid" "$os_name" "$url" "$storage" "$bridge" \
                  "$DEFAULT_CPU_CORES" "$DEFAULT_MEMORY" "$DEFAULT_DISK" \
                  "$DEFAULT_USER" "$DEFAULT_PASSWORD" "$sshkey"
}

# -------------------- 批量模式 --------------------
batch_mode(){
  local storage="$1" bridge="$2" vmid_start="$3" cpu="$4" mem="$5" disk="$6" user="$7" pass="$8"
  log_info "批量模式：将创建 ${#OS_IMAGES[@]} 种模板，VMID 从 $vmid_start 开始"
  read -p "是否继续？(y/n) " -n 1 -r; echo
  [[ $REPLY =~ ^[Yy]$ ]] || { log_info "操作取消"; return 0; }
  check_storage "$storage" || return 1
  download_images_parallel OS_IMAGES "$TEMP_DIR" || return 1
  local vmid=$vmid_start
  for name in "${!OS_IMAGES[@]}"; do
    local img="$TEMP_DIR/${name}.qcow2"
    check_vmid "$vmid" || { ((vmid++)); continue; }
    create_vm_base "$vmid" "Template-$name" "$cpu" "$mem"
    export CUR_VMID=$vmid
    qm importdisk "$vmid" "$img" "$storage" --format qcow2
    until qm config "$vmid" | grep -q "unused0"; do sleep 1; done
    qm set "$vmid" --scsi0 "$storage:$vmid/vm-$vmid-disk-0.qcow2"
    qm resize "$vmid" scsi0 "$disk"
    qm set "$vmid" --ide2 "$storage:cloudinit"
    qm set "$vmid" --boot order="scsi0;ide2"
    config_cloudinit "$vmid" "$user" "$pass" "$bridge" "" "$img" || true
    qm template "$vmid"
    log_success "模板创建：Template-$name (VMID:$vmid)"
    ((vmid++))
  done
}

# -------------------- 交互模式 --------------------
interactive_mode(){
  print_header
  log_info "启动交互模式"
  local storage
  storage=$(read_with_default "存储池" "$DEFAULT_STORAGE")
  check_storage "$storage" || return 1
  local bridge
  bridge=$(read_with_default "网桥" "$DEFAULT_BRIDGE")
  local cpu
  cpu=$(read_with_default "CPU 核心数" "$DEFAULT_CPU_CORES")
  local mem
  mem=$(read_with_default "内存(MB)" "$DEFAULT_MEMORY")
  local disk
  disk=$(read_with_default "磁盘大小" "$DEFAULT_DISK")
  local user
  user=$(read_with_default "用户名" "$DEFAULT_USER")
  local pass
  pass=$(read_with_default "密码" "$DEFAULT_PASSWORD")
  local sshkey=""
  read -p "是否使用 SSH 公钥登录？(y/n) " -n 1 -r; echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -rp "请输入公钥文件路径: " sshkey
    check_ssh_key "$sshkey" || return 1
  fi
  echo "可选系统："
  local os_list=("${!OS_IMAGES[@]}")
  for i in "${!os_list[@]}"; do echo "  $((i+1)). ${os_list[$i]}"; done
  local choice
  read -p "请选择 (1-${#os_list[@]}): " choice
  [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "${#os_list[@]}" ]] || {
    log_error "无效选择"; return 1; }
  local os_name="${os_list[$((choice-1))]}"
  local vmid
  vmid=$(read_with_default "VMID" "$DEFAULT_VMID")
  check_vmid "$vmid" || return 1
  create_template "$vmid" "$os_name" "${OS_IMAGES[$os_name]}" "$storage" \
                  "$bridge" "$cpu" "$mem" "$disk" "$user" "$pass" "$sshkey"
}

# -------------------- 菜单模式 --------------------
show_menu(){
  print_header
  local opts=(
    "批量模式：一键创建所有系统模板"
    "交互模式：手动配置参数创建模板"
    "精准模式：命令行直接创建模板"
    "清理缓存：删除所有缓存的镜像文件"
    "退出"
  )
  echo -e "${BLUE}请选择操作模式：${NC}"
  for i in "${!opts[@]}"; do echo "  $((i+1))). ${opts[$i]}"; done
  local choice
  read -p "请输入选择 (1-${#opts[@]}): " choice
  case "$choice" in
    1) batch_mode "$DEFAULT_STORAGE" "$DEFAULT_BRIDGE" "$DEFAULT_VMID" \
                  "$DEFAULT_CPU_CORES" "$DEFAULT_MEMORY" "$DEFAULT_DISK" \
                  "$DEFAULT_USER" "$DEFAULT_PASSWORD" ;;
    2) interactive_mode ;;
    3) log_info "精准模式请使用命令行参数运行"; print_usage ;;
    4) rm -rf "$CACHE_DIR"/*; log_success "缓存已清理" ;;
    5) log_info "感谢使用，再见！"; exit 0 ;;
    *) log_error "无效选择" ;;
  esac
}

# -------------------- 参数解析 --------------------
print_usage(){
  cat << EOF
${BLUE}用法：${NC}
  精准模式：$SCRIPT_NAME <存储> <网桥> <VMID> <系统名|镜像URL> <公钥路径>
  批量模式：$SCRIPT_NAME <存储> <网桥> <起始VMID> <CPU> <内存> <磁盘> <用户> <密码>
  无参数   ：进入菜单模式
${BLUE}示例：${NC}
  $SCRIPT_NAME local vmbr0 8001 Ubuntu2404 ~/.ssh/id_rsa.pub
  $SCRIPT_NAME local vmbr0 8000 2 2048 30G root changeme
EOF
}

parse_arguments(){
  case "${1:-}" in
    -h|--help) print_header; print_usage; exit 0 ;;
    -v|--version) echo "$VERSION"; exit 0 ;;
    -d|--debug) export DEBUG=true; shift ;;
  esac
  if [[ $# -eq 5 ]]; then
    check_root; check_dependencies; rewrite_urls OS_IMAGES; precision_mode "$@"
  elif [[ $# -eq 8 ]]; then
    check_root; check_dependencies; rewrite_urls OS_IMAGES; batch_mode "$@"
  elif [[ $# -eq 0 ]]; then
    check_root; check_dependencies; rewrite_urls OS_IMAGES
    while true; do show_menu; read -p "按回车继续菜单，q退出: " c; [[ "$c" == "q" ]] && break; done
  else
    print_header; print_usage; log_error "参数数量错误"; exit 1
  fi
}

# -------------------- 主入口 --------------------
main(){
  mkdir -p "$TEMP_DIR"
  log_info "脚本启动 - 版本: $VERSION"
  log_info "日志: $LOG_FILE"
  parse_arguments "$@"
  log_info "脚本执行完成"
}

main "$@"

#!/bin/bash

# ============================================================================
#  PVE 一体化脚本：云模板/虚拟机创建 + IP 标签同步
#  - 使用自定义镜像源: https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/
#  - 支持交互选择发行版 + VMID，创建模板或普通虚拟机
#  - 创建模板：不写入 IP
#  - 创建虚拟机：使用 DHCP 自动获取 IP，启动后写入 IP 到 tags
#  - 支持扫描所有 VM/LXC，并将局域网 IP 写入 tags
# ============================================================================

set -o pipefail

MIRROR_BASE="https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/"
TEMP_DIR="/tmp/pve-unified-$$"
CACHE_DIR="/var/cache/pve-unified-images"

NOTES_TEXT=$'#  镜像说明 (请务必阅读)\n\n- 已预安装：`wget`、`curl`、`openssh-server`、`sshpass`、`sudo`、`cron(cronie)`、`qemu-guest-agent`\n- 已安装并启用 **cloud-init**，开启 SSH 登录，预设 SSH 监听 **IPv4 / IPv6 的 22 端口**，允许密码登录\n- 所有镜像均允许 **root 用户** 通过 SSH 登录\n\n**默认账户信息：**\n\n- 用户名：`root`\n- 密码：`oneclickvirt`\n\n> ⚠️ 安全提示：如果在生产或公网环境使用，请务必在首次登录后立刻修改 root 密码，否则存在被暴力破解/入侵的高风险。'

# -------------------- 颜色 --------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info(){ echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok(){   echo -e "${GREEN}[OK]${NC}   $*"; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err(){  echo -e "${RED}[ERR]${NC}  $*" >&2; }

cleanup(){
  [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

check_root(){
  if [ "$(id -u)" -ne 0 ]; then
    log_err "请使用 root 运行此脚本"; exit 1;
  fi
}

check_cmd(){
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || { log_err "缺少命令: $c"; exit 1; }
  done
}

# -------------------- 发行版定义（使用自定义镜像源） --------------------
# 假设镜像文件名与原脚本类似，如需调整可修改此表

declare -A DISTROS
# key: 序号; value: "名称|子路径|文件名"
# 下面根据你提供的链接进行拼接：
# Debian 11:  https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/debian/debian11.qcow2
# Debian 13:  https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/debian/debian13.qcow2
# Ubuntu 18:  https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/ubuntu/ubuntu1804.qcow2
# Ubuntu 22:  https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/ubuntu/ubuntu2204.qcow2
# Ubuntu 24:  https://cdn.spiritlhl.net/github.com/oneclickvirt/pve_kvm_images/releases/download/ubuntu/ubuntu2404.qcow2

DISTROS[1]="Debian-11|debian|debian11.qcow2"
DISTROS[2]="Debian-12|debian|debian12.qcow2"
DISTROS[3]="Debian-13|debian|debian13.qcow2"
DISTROS[4]="Ubuntu-18.04|ubuntu|ubuntu1804.qcow2"
DISTROS[5]="Ubuntu-20.04|ubuntu|ubuntu2004.qcow2"
DISTROS[6]="Ubuntu-22.04|ubuntu|ubuntu2204.qcow2"
DISTROS[7]="Ubuntu-24.04|ubuntu|ubuntu2404.qcow2"
DISTROS[8]="CentOS-8|centos|centos8.qcow2"
DISTROS[9]="CentOS-9|centos|centos9.qcow2"


show_distro_menu(){
  echo "================ 发行版选择 ================"
  for i in $(seq 1 10); do
    IFS='|' read -r name subdir file <<<"${DISTROS[$i]}"
    [ -z "$name" ] && continue
    printf "%2d) %s" "$i" "$name"
    [ -n "$file" ] && printf " (%s/%s)" "$subdir" "$file"
    printf "\n"
  done
  echo "==========================================="
}

prompt_vm_params(){
  read -rp "请输入 VMID (例如 8000): " VMID
  [[ "$VMID" =~ ^[0-9]+$ ]] || { log_err "VMID 必须为数字"; exit 1; }

  read -rp "请输入网络桥接 (默认 vmbr0): " VMBR
  [ -z "$VMBR" ] && VMBR="vmbr0"

  read -rp "请输入存储名称 (默认 local): " STORAGE
  [ -z "$STORAGE" ] && STORAGE="local"
}

maybe_destroy_vm(){
  local id="$1"
  if qm status "$id" >/dev/null 2>&1; then
    read -rp "检测到 VMID $id 已存在，是否销毁? (y/N): " ans
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      qm stop "$id" 2>/dev/null || true
      qm destroy "$id" --destroy-unreferenced-disks 1 --purge 1 || {
        log_err "销毁 VMID $id 失败"; exit 1;
      }
      log_ok "已销毁 VMID $id"
    else
      log_warn "用户取消，退出"; exit 1;
    fi
  fi
}

download_image(){
  local rel_path="$1"          # 例如: debian/debian13.qcow2
  local file
  file="${rel_path##*/}"       # 例如: debian13.qcow2

  mkdir -p "$TEMP_DIR" "$CACHE_DIR"

  local cached="$CACHE_DIR/$file"
  if [ -s "$cached" ]; then
    log_info "命中缓存镜像: $cached"
    cp "$cached" "$TEMP_DIR/$file"
    return 0
  fi

  local url="$MIRROR_BASE$rel_path"
  log_info "下载镜像: $url"
  if ! wget -c -O "$TEMP_DIR/$file" "$url"; then
    log_err "下载失败: $url"; exit 1;
  fi
  log_ok "镜像已下载: $TEMP_DIR/$file，写入缓存"
  cp "$TEMP_DIR/$file" "$cached" || true
}

create_template_single(){
  check_root
  check_cmd qm wget pct ip

  show_distro_menu
  read -rp "请选择要创建的发行版 (1-10): " choice
  [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le 10 ]] || { log_err "无效选择"; exit 1; }

  IFS='|' read -r NAME SUBDIR FILE <<<"${DISTROS[$choice]}"
  [ -z "$FILE" ] && { log_err "该选项尚未配置镜像文件"; exit 1; }

  prompt_vm_params
  maybe_destroy_vm "$VMID"

  download_image "$SUBDIR/$FILE"

  log_info "创建云模板 VM $NAME (VMID: $VMID)"
  qm create "$VMID" \
    --name "$NAME" \
    --cpu host \
    --cores 2 \
    --memory 2048 \
    --scsihw virtio-scsi-pci \
    --agent 1 \
    --net0 virtio,bridge="$VMBR" || {
    log_err "创建虚拟机失败"; exit 1;
  }


  log_info "导入磁盘到存储 $STORAGE"
  qm importdisk "$VMID" "$TEMP_DIR/$FILE" "$STORAGE" --format qcow2 || {
    log_err "导入磁盘失败"; exit 1;
  }

  log_info "配置 SCSI 磁盘 (20G) 和 CloudInit 双栈 DHCP"
  qm set "$VMID" --scsi0 "$STORAGE:$VMID/vm-$VMID-disk-0.qcow2" || {
    log_err "挂载 scsi0 失败"; exit 1;
  }
  qm resize "$VMID" scsi0 20G || {
    log_err "调整磁盘大小失败"; exit 1;
  }

  # CloudInit: 挂载驱动器并设置 IPv4/IPv6 均为 DHCP
  qm set "$VMID" --ide2 "$STORAGE:cloudinit" || {
    log_err "配置 cloudinit 失败"; exit 1;
  }
  qm set "$VMID" --ipconfig0 "ip=dhcp,ip6=dhcp" || {
    log_err "配置 IP 为双栈 DHCP 失败"; exit 1;
  }

  qm set "$VMID" --boot c --bootdisk scsi0
  qm set "$VMID" --serial0 socket --vga serial0
  qm set "$VMID" --description "$NOTES_TEXT"

  log_info "转换为模板 (不启动 VM、不写入 IP)"
  qm template "$VMID" || { log_err "转换模板失败"; exit 1; }

  log_ok "云模板 $NAME (VMID: $VMID) 创建完成"
}

# -------------------- 创建普通虚拟机并写入 IP 标签 --------------------

wait_and_set_ip_tag(){
  local vmid="$1"
  local timeout="${2:-120}"
  local interval=5
  local elapsed=0

  log_info "等待虚拟机 $vmid 获取 IP (最多 ${timeout}s)"
  while [ "$elapsed" -lt "$timeout" ]; do
    IP=$(qm guest cmd "$vmid" network-get-interfaces 2>/dev/null | \
         grep -oP '"ip-address" : "\K10\.[0-9]+\.[0-9]+\.[0-9]+')
    if [ -n "$IP" ]; then
      log_ok "获取到 IP: $IP，写入 tags"
      qm set "$vmid" --tags "$IP"
      return 0
    fi
    sleep "$interval"
    elapsed=$((elapsed + interval))
  done
  log_warn "在 ${timeout}s 内未获取到虚拟机 $vmid 的 IP (请检查 qemu-guest-agent / 网络配置)"
  return 1
}

create_vm_single(){
  check_root
  check_cmd qm wget pct ip

  show_distro_menu
  read -rp "请选择要创建的发行版 (1-10): " choice
  [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le 10 ]] || { log_err "无效选择"; exit 1; }

  IFS='|' read -r NAME SUBDIR FILE <<<"${DISTROS[$choice]}"
  [ -z "$FILE" ] && { log_err "该选项尚未配置镜像文件"; exit 1; }

  prompt_vm_params
  maybe_destroy_vm "$VMID"

  download_image "$SUBDIR/$FILE"

  log_info "创建虚拟机 $NAME (VMID: $VMID)（同模板配置）"
  qm create "$VMID" \
    --name "$NAME" \
    --cpu host \
    --cores 2 \
    --memory 2048 \
    --scsihw virtio-scsi-pci \
    --agent 1 \
    --net0 virtio,bridge="$VMBR" || {
    log_err "创建虚拟机失败"; exit 1;
  }


  log_info "导入磁盘到存储 $STORAGE"
  qm importdisk "$VMID" "$TEMP_DIR/$FILE" "$STORAGE" --format qcow2 || {
    log_err "导入磁盘失败"; exit 1;
  }

  log_info "配置 SCSI 磁盘 (20G) 和 CloudInit 双栈 DHCP"
  qm set "$VMID" --scsi0 "$STORAGE:$VMID/vm-$VMID-disk-0.qcow2" || {
    log_err "挂载 scsi0 失败"; exit 1;
  }
  qm resize "$VMID" scsi0 20G || {
    log_err "调整磁盘大小失败"; exit 1;
  }

  qm set "$VMID" --ide2 "$STORAGE:cloudinit" || {
    log_err "配置 cloudinit 失败"; exit 1;
  }
  qm set "$VMID" --ipconfig0 "ip=dhcp,ip6=dhcp" || {
    log_err "配置 IP 为双栈 DHCP 失败"; exit 1;
  }

  qm set "$VMID" --boot c --bootdisk scsi0
  qm set "$VMID" --serial0 socket --vga serial0
  qm set "$VMID" --description "$NOTES_TEXT"

  log_info "启动虚拟机并等待 IP"
  qm start "$VMID" || { log_err "启动虚拟机失败"; exit 1; }

  wait_and_set_ip_tag "$VMID" 180

  log_ok "虚拟机 $NAME (VMID: $VMID) 创建完成（如成功获取到 IP 已写入 tags）"
}

# -------------------- IP 标签同步逻辑 --------------------

update_ip_tags(){
  check_root
  check_cmd qm pct ip

  echo "开始处理本地节点所有虚拟机和容器..."

  # QEMU 虚拟机
  QMIDS=$(qm list | awk 'NR>1 {print $1}')
  for VMID in $QMIDS; do
    echo "处理 QEMU 虚拟机 $VMID ..."
    IP=$(qm guest cmd "$VMID" network-get-interfaces 2>/dev/null | \
         grep -oP '"ip-address" : "\K10\.[0-9]+\.[0-9]+\.[0-9]+')
    if [ -z "$IP" ]; then
      echo "  未获取到IP (可能未安装 qemu-guest-agent 或虚拟机未运行)"; continue;
    fi
    echo "  获取到IP: $IP"
    qm set "$VMID" --tags "$IP"
    echo "  已将IP写入虚拟机tags"
  done

  # LXC 容器
  CTIDS=$(pct list | awk 'NR>1 {print $1}')
  for CTID in $CTIDS; do
    echo "处理 LXC 容器 $CTID ..."
    IP=$(pct exec "$CTID" -- ip -4 addr show | grep -oP '(?<=inet\\s)10\.[0-9]+\.[0-9]+\.[0-9]+')
    if [ -z "$IP" ]; then
      echo "  未获取到IP (容器未运行或网络未配置)"; continue;
    fi
    echo "  获取到IP: $IP"
    pct set "$CTID" --tags "$IP"
    echo "  已将IP写入容器 tags 标签"
  done

  echo "全部处理完成！"
}

# -------------------- 主菜单 --------------------

clear_cache(){
  echo "即将删除缓存目录 $CACHE_DIR 下的所有镜像文件..."
  if [ -d "$CACHE_DIR" ]; then
    rm -f "$CACHE_DIR"/* 2>/dev/null || true
    echo "缓存已清理。"
  else
    echo "缓存目录不存在，无需清理。"
  fi
}

show_main_menu(){
  echo "================ PVE 一体化脚本 ================"
  echo "1) 创建单个云模板"
  echo "2) 创建单个虚拟机"
  echo "3) 扫描并将局域网 IP 写入 VM/LXC tags"
  echo "4) 清除已缓存的镜像文件"
  echo "5) 退出"
  echo "==============================================="
}

main(){
  mkdir -p "$TEMP_DIR"
  while true; do
    show_main_menu
    read -rp "请选择操作 (1-5): " opt
    case "$opt" in
      1) create_template_single ;;
      2) create_vm_single ;;
      3) update_ip_tags ;;
      4) clear_cache ;;
      5) echo "退出"; break ;;
      *) echo "无效选择" ;;
    esac
  done
}

main "$@"
